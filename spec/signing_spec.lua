-- Signed releases (wowapi.signing) and the compatibility index (wowapi.index).
local signing = require("wowapi.signing")

local function sh(cmd) local r = os.execute(cmd .. " >/dev/null 2>&1"); return r == true or r == 0 end
local function write(path, text) local f = assert(io.open(path, "w")); f:write(text); f:close() end

-- A signed addon in a scratch folder; returns root, addon dir, key paths.
local function signedAddon()
  local root = os.tmpname()
  os.remove(root)
  local dir = root .. "/Signed"
  sh('mkdir -p "' .. dir .. '"')
  write(dir .. "/Signed.toc", "## Interface: 16001\n## Version: 2.0\nCore.lua\n")
  write(dir .. "/Core.lua", "SignedLoaded = true\n")
  local key = signing.keygen(root .. "/keys", "dev")
  signing.sign(dir, key)
  return root, dir, root .. "/keys/dev.key", root .. "/keys/dev.pub"
end

local function cleanup(root) sh('rm -rf "' .. root .. '"') end

describe("signed addon releases", function()
  if not signing.available() then
    it("needs openssl (skipped)", function() end)
    return
  end

  it("verifies an untouched release", function()
    local root, dir = signedAddon()
    local res = signing.verify(dir)
    expect(res.status).to_be("valid")
    expect(res.addon).to_be("Signed")
    expect(res.version).to_be("2.0")
    cleanup(root)
  end)

  it("detects a modified file", function()
    local root, dir = signedAddon()
    write(dir .. "/Core.lua", "SignedLoaded = true\nSendChatMessage('hi', 'SAY')\n")
    local res = signing.verify(dir)
    expect(res.status).to_be("invalid")
    expect(res.modified).to_equal({ "Core.lua" })
    cleanup(root)
  end)

  it("detects injected code files but tolerates other extra files", function()
    local root, dir = signedAddon()
    write(dir .. "/readme.txt", "notes")
    expect(signing.verify(dir).status).to_be("valid")
    write(dir .. "/Extra.lua", "x = 1")
    local res = signing.verify(dir)
    expect(res.status).to_be("invalid")
    expect(res.reason).to_match("Extra.lua")
    cleanup(root)
  end)

  it("rejects an edited manifest", function()
    local root, dir = signedAddon()
    local f = io.open(dir .. "/" .. signing.MANIFEST); local m = f:read("*a"); f:close()
    write(dir .. "/" .. signing.MANIFEST, m:gsub("version: 2.0", "version: 9.9"))
    expect(signing.verify(dir).status).to_be("invalid")
    cleanup(root)
  end)

  it("pins a key and flags a changed key on the keyring", function()
    local root, dir, _, pub = signedAddon()
    local f = io.open(pub); local pem = f:read("*a"); f:close()
    expect(signing.verify(dir, { pubkey = pem }).status).to_be("valid")
    local ring = root .. "/trusted-keys.txt"
    expect(signing.verifyTrusted(dir, "Signed", ring).trust).to_be("new")
    expect(signing.verifyTrusted(dir, "Signed", ring).trust).to_be("known")
    -- someone re-signs it with their own key
    local other = signing.keygen(root .. "/keys", "other")
    signing.sign(dir, other)
    expect(signing.verify(dir, { pubkey = pem }).status).to_be("invalid")
    local res = signing.verifyTrusted(dir, "Signed", ring)
    expect(res.status).to_be("invalid")
    expect(res.trust).to_be("changed")
    cleanup(root)
  end)

  it("reports unsigned folders", function()
    expect(signing.verify("spec/fixtures/XmlAddon").status).to_be("unsigned")
  end)

  it("the installer refuses a tampered signed addon", function()
    local root, dir = signedAddon()
    write(dir .. "/Core.lua", "tampered = true\n")
    local inst = require("wowapi.installer").new({ root = root .. "/wt", log = function() end })
    local ok, err = pcall(inst.install, inst, dir)
    expect(ok).to_be(false)
    expect(tostring(err)).to_match("refusing to install")
    cleanup(root)
  end)
end)

describe("compatibility index", function()
  it("classifies addons and writes JSON/HTML", function()
    local idx = require("wowapi.index")
    local clean = idx.check("spec/fixtures/XmlAddon")
    expect(clean.status).to_be("clean")
    local broken = idx.check("spec/fixtures/Broken")
    expect(broken.status == "errors" or broken.status == "missing-libs").to_be(true)
    local html = idx.html({ interface = 16001, generated = "now", addons = { clean, broken } })
    expect(html:find("Forever Addon Index", 1, true) ~= nil).to_be(true)
    expect(idx.json({ a = { 1, "x\n" } })).to_be('{"a":[1,"x\\n"]}')
  end)
end)
