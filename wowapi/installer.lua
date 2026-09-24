-- `wowtest install`: fetch an addon from GitHub (or a git URL / local
-- folder) and package it the way the CurseForge/BigWigs packager does:
-- resolve .pkgmeta externals (embedded libraries), apply move-folders,
-- and install the result into an AddOns folder.
--
-- Externals are resolved in this order:
--   1. git URLs: cloned (tag/branch honoured)
--   2. svn URLs (repos.wowace.com / repos.curseforge.com): `svn export`,
--      or a plain HTTP download of the directory tree
--   3. the Ace3 GitHub mirror, for Ace3 / LibStub / CallbackHandler
--   4. a library with the same folder name already present in another
--      installed addon (libraries are identical wherever they're embedded)
local M = {}

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function sh(cmd, quiet)
  local r = os.execute(cmd .. (quiet ~= false and " >/dev/null 2>&1" or ""))
  return r == 0 or r == true
end
local function exists(p) return sh("test -e " .. q(p)) end
local function isDir(p) return sh("test -d " .. q(p)) end
local function have(tool) return sh("command -v " .. tool) end
local function lines(cmd)
  local out = {}
  local p = io.popen(cmd .. " 2>/dev/null")
  if p then for l in p:lines() do out[#out + 1] = l end; p:close() end
  return out
end
local function basename(p) return (p:gsub("[/\\]+$", ""):match("([^/\\]+)$")) end

------------------------------------------------------------------ .pkgmeta

-- Minimal YAML for .pkgmeta: nested maps by indentation, "key: value",
-- quoted strings, lists ("- item"). Enough for externals / move-folders.
function M.parsePkgmeta(text)
  local root = {}
  local stack = { { indent = -1, tbl = root } }
  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    local line = raw:gsub("%s+#.*$", "")
    if not line:match("^%s*#") and line:match("%S") then
      local indent = #line:match("^(%s*)")
      local body = line:sub(indent + 1)
      while #stack > 1 and indent <= stack[#stack].indent do table.remove(stack) end
      local parent = stack[#stack].tbl
      local item = body:match("^%-%s*(.*)$")
      if item then
        parent[#parent + 1] = (item:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1"))
      else
        local key, value = body:match("^([^:]+):%s*(.-)%s*$")
        if key then
          key = key:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1"):gsub("%s+$", "")
          if value == "" then
            local t = {}
            parent[key] = t
            stack[#stack + 1] = { indent = indent, tbl = t }
          else
            parent[key] = (value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1"))
          end
        end
      end
    end
  end
  return root
end

------------------------------------------------------------------ fetching

local function isGit(url)
  return url:match("%.git$") or url:match("^https?://github%.com/") or url:match("^https?://gitlab%.com/")
    or url:match("^git@") or url:match("^git://")
end

local function gitClone(url, dest, ref)
  local cmd = "git clone --quiet --depth 1 --recurse-submodules --shallow-submodules "
    .. (ref and ("--branch " .. q(ref) .. " ") or "") .. q(url) .. " " .. q(dest)
  if sh(cmd) then return true end
  if ref then return sh("git clone --quiet --depth 1 " .. q(url) .. " " .. q(dest)) end
  return false
end

-- Download a directory tree served over HTTP (how svn repos present themselves).
local function httpTree(url, dest, depth)
  depth = depth or 0
  if depth > 6 or not have("curl") then return false end
  url = url:gsub("/*$", "/")
  local p = io.popen("curl -sfL --max-time 60 " .. q(url) .. " 2>/dev/null")
  local html = p and p:read("*a") or ""
  if p then p:close() end
  if html == "" then return false end
  sh("mkdir -p " .. q(dest))
  local any = false
  for href in html:gmatch('href="([^"]+)"') do
    if not href:match("^%.%.") and not href:match("^/") and not href:match("^%a+:") and not href:match("^%?") then
      if href:match("/$") then
        any = httpTree(url .. href, dest .. "/" .. href:gsub("/$", ""), depth + 1) or any
      else
        any = sh("curl -sfL --max-time 60 -o " .. q(dest .. "/" .. href) .. " " .. q(url .. href)) or any
      end
    end
  end
  return any
end

M.MIRRORS = {
  ["LibDualSpec-1.0"] = "AdiAddons/LibDualSpec-1.0",
  ["LibDataBroker-1.1"] = "tekkub/libdatabroker-1-1",
  ["LibActionButton-1.0"] = "Nevcairiel/LibActionButton-1.0",
  ["LibKeyBound-1.0"] = "Tuller/LibKeyBound-1.0",
}

local ACE3 = { ["LibStub"] = true, ["CallbackHandler-1.0"] = true }
local function isAce(name)
  return ACE3[name] or name:match("^Ace[%w]+%-3%.0$") ~= nil
end

------------------------------------------------------------------ packager keywords

-- Apply the packager's file directives: drop @do-not-package@ blocks,
-- disable @debug@ blocks, enable @non-debug@ blocks, fill @project-*@.
function M.processKeywords(dir, name)
  -- svn keywords, as `svn export` would expand them (libraries fetched from
  -- git mirrors still contain the raw keywords)
  for _, file in ipairs(lines("grep -rlE '[$](Revision|Rev|Date|Id|LastChangedRevision)[$]' " .. q(dir) .. " --include='*.lua'")) do
    local f = io.open(file, "rb")
    local text = f and f:read("*a")
    if f then f:close() end
    if text then
      text = text:gsub("%$Revision%$", "$Revision: 1000 $"):gsub("%$Rev%$", "$Rev: 1000 $")
        :gsub("%$LastChangedRevision%$", "$LastChangedRevision: 1000 $")
        :gsub("%$Date%$", "$Date: " .. os.date("!%Y-%m-%d %H:%M:%S") .. " $"):gsub("%$Id%$", "$Id: 1000 $")
      local out = io.open(file, "wb")
      if out then out:write(text); out:close() end
    end
  end
  for _, file in ipairs(lines("grep -rlE '@(do-not-package|end-do-not-package|debug|non-debug|project-version|project-date-iso|version-[a-z]+|non-version-[a-z]+)@' "
    .. q(dir) .. " --include='*.toc' --include='*.lua' --include='*.xml'")) do
    local f = io.open(file, "rb")
    local text = f and f:read("*a")
    if f then f:close() end
    if text then
      local ext = file:match("%.(%a+)$"):lower()
      -- WoW: Forever runs the mainline API: package as the retail flavor
      for _, flavor in ipairs({ "classic", "bcc", "wrath", "cata", "mists", "vanilla", "tbc" }) do
        if ext == "toc" then
          text = text:gsub("#@version%-" .. flavor .. "@.-#@end%-version%-" .. flavor .. "@[^\n]*\n?", "")
        elseif ext == "lua" then
          text = text:gsub("%-%-@version%-" .. flavor .. "@", "--[===[@version-" .. flavor .. "@")
            :gsub("%-%-@end%-version%-" .. flavor .. "@", "--@end-version-" .. flavor .. "@]===]")
        end
      end
      if ext == "toc" then
        text = text:gsub("#@non%-version%-retail@.-#@end%-non%-version%-retail@[^\n]*\n?", "")
      elseif ext == "lua" then
        text = text:gsub("%-%-@non%-version%-retail@", "--[===[@non-version-retail@")
          :gsub("%-%-@end%-non%-version%-retail@", "--@end-non-version-retail@]===]")
      end
      if ext == "toc" then
        text = text:gsub("#@do%-not%-package@.-#@end%-do%-not%-package@[^\n]*\n?", "")
        text = text:gsub("#@debug@.-#@end%-debug@[^\n]*\n?", "")
        text = text:gsub("(#@non%-debug@[^\n]*\n)(.-)(#@end%-non%-debug@)", function(a, body, c)
          return a .. body:gsub("\n# ?", "\n"):gsub("^# ?", "") .. c
        end)
      elseif ext == "lua" then
        text = text:gsub("%-%-@do%-not%-package@.-%-%-@end%-do%-not%-package@", "")
        text = text:gsub("%-%-@debug@", "--[===[@debug@"):gsub("%-%-@end%-debug@", "--@end-debug@]===]")
        text = text:gsub("%-%-%[=*%[@non%-debug@", "--@non-debug@"):gsub("%-%-@end%-non%-debug@%]=*%]", "--@end-non-debug@")
      elseif ext == "xml" then
        text = text:gsub("<!%-%-@do%-not%-package@%-%->.-<!%-%-@end%-do%-not%-package@%-%->", "")
        text = text:gsub("<!%-%-@debug@%-%->", "<!--@debug@"):gsub("<!%-%-@end%-debug@%-%->", "@end-debug@-->")
        text = text:gsub("<!%-%-@non%-debug@", "<!--@non-debug@-->"):gsub("@end%-non%-debug@%-%->", "<!--@end-non-debug@-->")
      end
      text = text:gsub("@project%-version@", "wowtest-" .. os.date("%Y%m%d")):gsub("@project%-date%-iso@", os.date("!%Y-%m-%dT%H:%M:%SZ"))
      local out = io.open(file, "wb")
      if out then out:write(text); out:close() end
    end
  end
end

function M.new(opts)
  opts = opts or {}
  local self = {
    root = opts.root or ".wowtest",
    addonsDir = opts.addonsDir or ((opts.root or ".wowtest") .. "/AddOns"),
    libPaths = opts.libPaths or {},
    log = opts.log or print,
    report = { resolved = {}, missing = {} },
  }
  self.srcDir = self.root .. "/src"
  sh("mkdir -p " .. q(self.srcDir) .. " " .. q(self.addonsDir))
  return setmetatable(self, { __index = M })
end

function M:ace3()
  local dir = self.srcDir .. "/_Ace3"
  if not isDir(dir) then gitClone("https://github.com/WoWUIDev/Ace3.git", dir) end
  return isDir(dir) and dir or nil
end

-- Folders named `name` in installed addons / sources / extra lib paths.
function M:findLibrary(name, exclude)
  local roots = { self.addonsDir, self.srcDir }
  for _, p in ipairs(self.libPaths) do roots[#roots + 1] = p end
  for _, r in ipairs(roots) do
    for _, found in ipairs(lines("find " .. q(r) .. " -maxdepth 6 -type d -iname " .. q(name))) do
      if (not exclude or found:sub(1, #exclude) ~= exclude) then
        -- must contain some Lua or XML
        if #lines("find " .. q(found) .. " -maxdepth 2 \\( -name '*.lua' -o -name '*.xml' \\) | head -1") > 0 then
          return found
        end
      end
    end
  end
end

function M:resolveExternal(target, spec, workDir)
  local url, ref = spec, nil
  if type(spec) == "table" then url, ref = spec.url, spec.tag or spec.branch or spec.commit end
  local dest = workDir .. "/" .. target
  local name = basename(target)
  if isDir(dest) and #lines("ls -A " .. q(dest)) > 0 then return "present" end
  sh("mkdir -p " .. q(dest:match("^(.*)/[^/]+$")))
  local tmp = self.srcDir .. "/_ext/" .. name .. "-" .. os.time() .. math.random(1000)
  sh("rm -rf " .. q(tmp))
  -- 1. git ("repo.git/Sub/Folder" means a folder inside the repo)
  local gitUrl, sub = url, nil
  if url then
    local base, rest = url:match("^(.-%.git)/(.+)$")
    if base then gitUrl, sub = base, rest end
  end
  if gitUrl and isGit(gitUrl) and gitClone(gitUrl, tmp, ref) then
    sh("rm -rf " .. q(tmp .. "/.git"))
    local from = sub and (tmp .. "/" .. sub) or tmp
    -- a repo holding the library in a folder of the same name
    if not sub and isDir(tmp .. "/" .. name) and not exists(tmp .. "/" .. name .. ".toc") then from = tmp .. "/" .. name end
    if isDir(from) then
      sh("mkdir -p " .. q(dest) .. " && cp -R " .. q(from) .. "/. " .. q(dest))
      return "git"
    end
  end
  -- known GitHub mirrors for libraries hosted elsewhere
  local mirror = M.MIRRORS[name]
  if mirror and gitClone("https://github.com/" .. mirror .. ".git", tmp .. "_m") then
    sh("rm -rf " .. q(tmp .. "_m/.git"))
    local from = isDir(tmp .. "_m/" .. name) and (tmp .. "_m/" .. name) or (tmp .. "_m")
    sh("mkdir -p " .. q(dest) .. " && cp -R " .. q(from) .. "/. " .. q(dest))
    return "mirror " .. mirror
  end
  -- 2. svn / http
  if url and url:match("^https?://") and not isGit(url) then
    if have("svn") and sh("svn export --quiet --force " .. q(url) .. " " .. q(dest)) then return "svn" end
    if httpTree(url, dest) then return "http" end
  end
  -- 3. Ace3 mirror
  if isAce(name) then
    local ace = self:ace3()
    if ace and isDir(ace .. "/" .. name) then
      sh("mkdir -p " .. q(dest) .. " && cp -R " .. q(ace .. "/" .. name) .. "/. " .. q(dest))
      return "Ace3 mirror"
    end
  end
  -- 4. same library embedded elsewhere
  local found = self:findLibrary(name, workDir)
  if found then
    sh("mkdir -p " .. q(dest) .. " && cp -R " .. q(found) .. "/. " .. q(dest))
    return "copied from " .. found
  end
  sh("rmdir " .. q(dest))
  return nil
end

-- Install one addon repository. `src` is "owner/repo", a git URL or a
-- local folder. Returns the list of installed addon folder names.
function M:install(src)
  local repoName = basename(src):gsub("%.git$", "")
  local work = self.srcDir .. "/" .. repoName
  if isDir(src) then
    work = src
  elseif not isDir(work) then
    local url = src:match("^[%w%-_%.]+/[%w%-_%.]+$") and ("https://github.com/" .. src .. ".git") or src
    self.log("Cloning " .. url)
    if not gitClone(url, work) then error("could not clone " .. url, 0) end
  end

  local meta = {}
  local f = io.open(work .. "/.pkgmeta", "r") or io.open(work .. "/pkgmeta.yaml", "r")
  if f then meta = M.parsePkgmeta(f:read("*a")); f:close() end

  -- externals
  local externals = meta.externals or {}
  local names = {}
  for k in pairs(externals) do names[#names + 1] = k end
  table.sort(names)
  for _, target in ipairs(names) do
    local how = self:resolveExternal(target, externals[target], work)
    if how then
      table.insert(self.report.resolved, { addon = repoName, lib = target, how = how })
    else
      table.insert(self.report.missing, { addon = repoName, lib = target, url = type(externals[target]) == "table" and externals[target].url or externals[target] })
    end
  end

  -- Package like the packager: the repo becomes <package-as>/, move-folders
  -- are applied inside the staging area, and every top-level folder with a
  -- .toc is an addon.
  local pkg = meta["package-as"]
  if not pkg then
    local tocs = lines("ls " .. q(work) .. "/*.toc")
    pkg = tocs[1] and basename(tocs[1]):gsub("%.toc$", ""):gsub("[_%-](%a+)$", function(suf)
      local l = suf:lower()
      if l == "mainline" or l == "classic" or l == "vanilla" or l == "tbc" or l == "wrath" or l == "cata"
        or l == "mists" or l == "camelot" or l == "forever" or l == "standard" then return "" end
    end) or repoName
  end
  local stage = self.srcDir .. "/_stage/" .. repoName
  sh("rm -rf " .. q(stage) .. " && mkdir -p " .. q(stage .. "/" .. pkg))
  sh("cp -R " .. q(work) .. "/. " .. q(stage .. "/" .. pkg) .. " && rm -rf " .. q(stage .. "/" .. pkg .. "/.git"))
  -- move-folders, with the packager's semantics (BigWigsMods/packager
  -- release.sh): the destination is replaced unless the source lives inside
  -- it, in which case the source's contents are merged into it.
  local moves = meta["move-folders"]
  if type(moves) == "table" then
    local froms = {}
    for from in pairs(moves) do froms[#froms + 1] = from end
    table.sort(froms, function(x, y) return #x > #y end) -- deepest first
    for _, from in ipairs(froms) do
      local src, dst = stage .. "/" .. from, stage .. "/" .. moves[from]
      if isDir(src) then
        local inside = src:sub(1, #dst + 1) == dst .. "/"
        local tmp = stage .. "/.move-tmp"
        sh("rm -rf " .. q(tmp) .. " && mv " .. q(src) .. " " .. q(tmp))
        if not inside then sh("rm -rf " .. q(dst)) end
        sh("mkdir -p " .. q(dst) .. " && cp -R " .. q(tmp) .. "/. " .. q(dst) .. " && rm -rf " .. q(tmp))
      end
    end
  end
  M.processKeywords(stage, meta["package-as"] or pkg)
  -- a package folder without a .toc holds several addons side by side
  if #lines("ls " .. q(stage .. "/" .. pkg) .. "/*.toc") == 0 then
    for _, toc in ipairs(lines("ls " .. q(stage .. "/" .. pkg) .. "/*/*.toc")) do
      local dir = toc:match("^(.*)/[^/]+$")
      if not isDir(stage .. "/" .. basename(dir)) then sh("mv " .. q(dir) .. " " .. q(stage .. "/" .. basename(dir))) end
    end
  end
  local installed = {}
  for _, dir in ipairs(lines("ls -d " .. q(stage) .. "/*/")) do
    dir = dir:gsub("/$", "")
    if #lines("ls " .. q(dir) .. "/*.toc") > 0 then
      local name = basename(dir)
      local dest = self.addonsDir .. "/" .. name
      sh("rm -rf " .. q(dest) .. " && mv " .. q(dir) .. " " .. q(dest))
      installed[#installed + 1] = name
    end
  end
  table.sort(installed)
  return installed
end

return M
