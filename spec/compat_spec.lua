-- Behaviours found by running real addons (Plater, DBM, BigWigs, Bartender4,
-- Dominos, Details...) through the simulator, plus the addon installer.
local function newSim(opts)
  opts = opts or {}
  opts.quiet = true
  return WoW.new(opts)
end

describe("client quirks addons rely on", function()
  it("xpcall passes extra arguments (WoW's Lua does)", function()
    local sim = newSim()
    local _, ok, v = sim:Exec("return xpcall(function(a, b) return a * b end, geterrorhandler(), 6, 7)")
    expect({ ok, v }).to_equal({ true, 42 })
  end)

  it("errors caught with xpcall(f, geterrorhandler()) still count", function()
    local sim = newSim()
    sim:Exec('xpcall(function() error("hidden init failure") end, geterrorhandler())')
    expect(#sim.errors).to_be(1)
    expect(sim.errors[1].message).to_match("hidden init failure")
    sim:ClearErrors()
  end)

  it("debugprofilestop advances within a frame", function()
    local sim = newSim()
    local _, done = sim:Exec([[
      local stop = debugprofilestop() + 2
      local n = 0
      while debugprofilestop() < stop do n = n + 1 end
      return n > 0
    ]])
    expect(done).to_be(true)
  end)

  it("accepts SetPoint(point, relativeTo, x, y)", function()
    local sim = newSim()
    local _, l = sim:Exec([[
      local a = CreateFrame("Frame", nil, UIParent); a:SetSize(10, 10); a:SetPoint("BOTTOMLEFT", 100, 100)
      local b = CreateFrame("Frame", nil, UIParent); b:SetSize(10, 10); b:SetPoint("BOTTOMLEFT", a, 5, 0)
      return b:GetLeft()
    ]])
    expect(l).to_be(105)
  end)

  it("gives Blizzard frames and mixins their unknown methods as no-ops", function()
    local sim = newSim()
    local ok = sim:Exec([[
      hooksecurefunc(NamePlateDriverFrame, "ShowPreviewNamePlateCastBar", function() end)
      hooksecurefunc(ActionBarActionButtonMixin, "UpdateUsable", function() end)
      ActionBarButtonEventsFrame:ForEachFrame(function() end)
      return MicroMenu:GetObjectType()
    ]])
    expect(ok).to_be(true)
  end)

  it("defines Enum meta tables and newproxy", function()
    local sim = newSim()
    local _, meta, proxy = sim:Exec("return Enum.ItemQualityMeta, newproxy(true)")
    expect(meta.NumValues).to_be_greater_than(5)
    expect(proxy).never.to_be_nil()
  end)

  it("ends index-based lookups like the client", function()
    local sim = newSim({ player = { class = "MAGE" } })
    local _, n = sim:Exec([[
      local i = 1
      while C_SpellBook.GetSpellBookItemInfo(i, 0) do i = i + 1 end
      return i - 1
    ]])
    expect(n).to_be_greater_than(2)
    expect(n).to_be_less_than(20)
  end)

  it("curves evaluate", function()
    local sim = newSim()
    local _, v = sim:Exec("local c = C_CurveUtil.CreateCurve(); c:AddPoint(0, 0); c:AddPoint(10, 100); return c:Evaluate(2.5)")
    expect(v).to_be(25)
  end)
end)

describe("nameplates", function()
  it("spawns plates with the client's event flow", function()
    local sim = newSim()
    sim:Exec([[
      added = {}
      local f = CreateFrame("Frame")
      f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
      f:SetScript("OnEvent", function(_, _, unit) tinsert(added, unit) end)
    ]])
    sim:SpawnNameplates(3)
    expect(sim:Get("added")).to_equal({ "nameplate1", "nameplate2", "nameplate3" })
    local _, count, name = sim:Exec('return #C_NamePlate.GetNamePlates(), UnitName("nameplate2")')
    expect(count).to_be(3)
    expect(name).to_be_type("string")
    local _, plate = sim:Exec('return C_NamePlate.GetNamePlateForUnit("nameplate1")')
    expect(plate.UnitFrame.healthBar:GetValue()).to_be_greater_than(0)
    sim:RemoveNameplate(1)
    local _, left = sim:Exec("return #C_NamePlate.GetNamePlates()")
    expect(left).to_be(2)
  end)
end)

describe("rendering details", function()
  it("draws SetGradient textures as gradients", function()
    local sim = newSim()
    sim:Exec([[
      local t = UIParent:CreateTexture(nil, "overlay"); t:SetSize(100, 100); t:SetPoint("CENTER")
      t:SetColorTexture(1, 1, 1, 1)
      t:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.2), CreateColor(0, 0, 0, 0))
    ]])
    local svg = sim:Screenshot()
    expect(svg).to_contain("linearGradient")
    expect(svg).never.to_contain('fill="#ffffff"')
  end)

  it("decodes TGA textures", function()
    local tga = string.char(0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 32, 32) .. string.char(129, 0, 0, 255, 255)
    local w, h, rgba = require("wowapi.tga").decode(tga)
    expect({ w, h, rgba:byte(1, 4) }).to_equal({ 2, 1, 255, 0, 0, 255 })
  end)
end)

describe("addon installer (packager)", function()
  local inst = require("wowapi.installer")

  it("parses .pkgmeta", function()
    local m = inst.parsePkgmeta([[
package-as: MyAddon
externals:
  Libs/LibStub: https://repos.wowace.com/wow/libstub/tags/1.0
  Libs/LibFoo-1.0:
    url: https://github.com/someone/LibFoo.git
    tag: v1
move-folders:
  MyAddon/Options: MyAddon_Options
ignore:
  - README.md
]])
    expect(m["package-as"]).to_be("MyAddon")
    expect(m.externals["Libs/LibStub"]).to_match("libstub")
    expect(m.externals["Libs/LibFoo-1.0"].tag).to_be("v1")
    expect(m["move-folders"]["MyAddon/Options"]).to_be("MyAddon_Options")
    expect(m.ignore[1]).to_be("README.md")
  end)

  it("packages a repo: libraries, move-folders merge, directives", function()
    local root = os.tmpname() .. "_pkg"
    local repo = root .. "/repo"
    local libs = root .. "/libs/LibFoo-1.0"
    local function write(path, text)
      os.execute('mkdir -p "' .. path:match("^(.*)/[^/]+$") .. '"')
      local f = io.open(path, "w"); f:write(text); f:close()
    end
    write(libs .. "/LibFoo-1.0.lua", "local MINOR = tonumber(('$Revision$'):match('(%d+)'))\nLibFooMinor = MINOR\n")
    write(repo .. "/.pkgmeta", "package-as: Multi\nexternals:\n  Multi/Libs/LibFoo-1.0: none://offline\nmove-folders:\n  Multi/Multi: Multi\n  Multi/Multi_Options: Multi_Options\n")
    write(repo .. "/Multi/Multi.toc", "## Interface: 16001\n#@do-not-package@\nDev.lua\n#@end-do-not-package@\n#@version-classic@\nClassic.lua\n#@end-version-classic@\nLibs/LibFoo-1.0/LibFoo-1.0.lua\nCore.lua\n")
    write(repo .. "/Multi/Core.lua", "MultiLoaded = true\n--@debug@\nerror('debug code must be disabled')\n--@end-debug@\n")
    write(repo .. "/Multi_Options/Multi_Options.toc", "## Interface: 16001\n## Dependencies: Multi\nOptions.lua\n")
    write(repo .. "/Multi_Options/Options.lua", "MultiOptions = true\n")
    local i = inst.new({ root = root .. "/out", libPaths = { root .. "/libs" }, log = function() end })
    local installed = i:install(repo)
    expect(installed).to_equal({ "Multi", "Multi_Options" })
    expect(i.report.missing).to_equal({})
    local sim = newSim({ addonPaths = { root .. "/out/AddOns" } })
    expect(sim:LoadAddon("Multi_Options")).to_be(true)
    expect(sim:Get("MultiLoaded")).to_be(true)
    expect(sim:Get("MultiOptions")).to_be(true)
    expect(sim:Get("LibFooMinor")).to_be(1000)
    os.execute('rm -rf "' .. root .. '"')
  end)
end)

describe("more behaviours from real addons", function()
  it("a TOPLEFT + RIGHT anchored row keeps its own height (AceGUI)", function()
    local sim = newSim()
    local _, h = sim:Exec([[
      local p = CreateFrame("Frame", nil, UIParent); p:SetPoint("TOPLEFT", 0, 0); p:SetSize(400, 300)
      local row = CreateFrame("Frame", nil, p); row:SetHeight(24)
      row:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -100); row:SetPoint("RIGHT", p)
      return row:GetHeight(), select(4, row:GetRect())
    ]])
    expect(h).to_be(24)
  end)

  it("font strings with a width wrap and report their real height", function()
    local sim = newSim()
    local _, one, many, lines = sim:Exec([[
      local fs = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      fs:SetPoint("TOPLEFT"); fs:SetWidth(120); fs:SetText("short")
      local one = fs:GetStringHeight()
      fs:SetText(("word "):rep(40))
      return one, fs:GetStringHeight(), fs:GetNumLines()
    ]])
    expect(lines > 1).to_be(true)
    expect(many > one).to_be(true)
  end)

  it("secure snippets can use ...", function()
    local sim = newSim()
    local _, frame = sim:Exec([[return CreateFrame("Frame", "SnipFrame", UIParent)]])
    local r = require("wowapi.secure").runSnippet(sim, frame, "local x, y = ...; return x + y", "self, ...", 2, 3)
    expect(r).to_be(5)
    expect(#sim.errors).to_be(0)
  end)

  it("hooks Blizzard mixin methods the simulator only knows by name", function()
    local sim = newSim()
    sim:Exec('hooksecurefunc(ActionBarActionButtonMixin, "UpdateUsable", function() end)')
    expect(#sim.errors).to_be(0)
  end)

  it("lists installed addons that aren't loaded yet and loads them by index", function()
    local sim = newSim({ addonPaths = { "spec/fixtures" } })
    local _, n, name, loaded = sim:Exec([[
      local n = C_AddOns.GetNumAddOns()
      for i = 1, n do
        local name = C_AddOns.GetAddOnInfo(i)
        if name == "LibThing" then return n, name, (C_AddOns.LoadAddOn(i)) end
      end
      return n
    ]])
    expect(n >= 4).to_be(true)
    expect(name).to_be("LibThing")
    expect(loaded).to_be(true)
  end)

  it("resolves addon file paths case-insensitively", function()
    local toc = require("wowapi.toc")
    expect(toc.resolve("spec/FIXTURES/xmladdon/XmlAddon.toc")).to_be("spec/fixtures/XmlAddon/XmlAddon.toc")
  end)

  it("Settings.OpenToCategory shows the Settings window with the category", function()
    local sim = newSim()
    sim:Exec([[
      SVTestDB = { flag = true }
      local cat = Settings.RegisterVerticalLayoutCategory("TestAddon")
      local s = Settings.RegisterAddOnSetting(cat, "TestAddon_Flag", "flag", SVTestDB, "boolean", "A flag", false)
      Settings.CreateCheckbox(cat, s, "tooltip")
      Settings.RegisterAddOnCategory(cat)
      Settings.OpenToCategory(cat:GetID())
    ]])
    expect(sim.settingsPanel:IsShown()).to_be(true)
    local svg = sim:Screenshot()
    expect(svg:find("A flag", 1, true) ~= nil).to_be(true)
  end)

  it("GetCVar and friends are globals, and unknown CVars return nil", function()
    local sim = newSim()
    local _, n = sim:Exec("return select('#', GetCVar('noSuchCVar'))")
    expect(n).to_be(1)
  end)
end)
