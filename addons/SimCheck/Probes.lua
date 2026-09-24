local _, ns = ...

-- Probes: each records one area of client behaviour into the result table.
-- They run as coroutines and call ns.Tick() in long loops, which yields
-- when this frame's time budget is spent (so the game never freezes).
-- Only Blizzard's own (secure) globals are recorded, never other addons'
-- data, and nothing identifies the player.

ns.probes = {}
local function probe(name, fn) table.insert(ns.probes, { name = name, run = fn }) end

-- (reading fields of a forbidden frame can itself raise an error)
local function tableCode(v)
  if type(rawget(v, 0)) == "userdata" and type(v.GetObjectType) == "function" then
    if v.IsForbidden and v:IsForbidden() then return "w:forbidden" end
    return "w:" .. tostring(v:GetObjectType())
  end
  return "t"
end

local function typeCode(v)
  local t = type(v)
  if t == "function" then return "f" elseif t == "string" then return "s" elseif t == "number" then return "n"
  elseif t == "boolean" then return "b" elseif t == "userdata" then return "u" end
  if t == "table" then
    local ok, code = pcall(tableCode, v)
    return ok and code or "w:forbidden"
  end
  return t
end

local function isBlizzard(k)
  local ok, secure = pcall(issecurevariable, _G, k)
  return ok and secure
end

local function round(n) return n and math.floor(n * 100 + 0.5) / 100 or nil end

------------------------------------------------------------------ client
probe("client", function(r)
  local c = {}
  c.version, c.build, c.date, c.interface, c.localizedVersion, c.buildType = GetBuildInfo()
  c.locale = GetLocale()
  c.gameTypes = ns.gameTypes or {}
  c.game = ns.game
  c.family = ns.family
  c.projectId = WOW_PROJECT_ID
  c.projects = {}
  for k, v in pairs(_G) do
    if type(k) == "string" and k:match("^WOW_PROJECT_") and type(v) == "number" then c.projects[k] = v end
  end
  c.expansion = GetExpansionLevel and GetExpansionLevel()
  c.serverExpansion = GetServerExpansionLevel and GetServerExpansionLevel()
  c.expansionCurrent = LE_EXPANSION_LEVEL_CURRENT
  c.maxLevel = GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion()
  c.isTestBuild = IsTestBuild and IsTestBuild() or nil
  c.region = GetCurrentRegion and GetCurrentRegion()
  r.client = c
end)

------------------------------------------------------------------ screen
probe("screen", function(r)
  r.screen = {
    width = round(GetScreenWidth()), height = round(GetScreenHeight()),
    uiScale = round(UIParent:GetEffectiveScale()),
    uiWidth = round(UIParent:GetWidth()), uiHeight = round(UIParent:GetHeight()),
  }
end)

------------------------------------------------------------------ globals
-- Every Blizzard global: its type; C_* namespaces and mixins with their
-- members; Enum; numeric constants; small constant tables (enum-like).
probe("globals", function(r)
  local globals, namespaces, constants, constTables = {}, {}, {}, {}
  local counts = {}
  -- snapshot the names first: other code may add or remove globals while
  -- this probe is paused between frames
  local keys = {}
  for key in pairs(_G) do if type(key) == "string" then keys[#keys + 1] = key end end
  for _, k in ipairs(keys) do
    local v = rawget(_G, k)
    if type(k) == "string" and isBlizzard(k) and k ~= "_G" then
      local code = typeCode(v)
      globals[k] = code
      counts[code:sub(1, 1)] = (counts[code:sub(1, 1)] or 0) + 1
      if code == "n" or code == "b" then
        constants[k] = v
      elseif code == "t" and k ~= "Enum" then
        local isNs = k:match("^C_") ~= nil
        local isMixin = k:match("Mixin$") ~= nil
        if isNs or isMixin then
          local members = {}
          for mk, mv in pairs(v) do
            if type(mk) == "string" and (isNs or type(mv) == "function") then members[mk] = typeCode(mv) end
          end
          namespaces[k] = members
        else
          -- enum-like: flat, only numbers/strings/booleans, not too big
          local copy, n, flat = {}, 0, true
          for tk, tv in pairs(v) do
            n = n + 1
            local vt, kt = type(tv), type(tk)
            if n > 300 or (kt ~= "string" and kt ~= "number") or (vt ~= "number" and vt ~= "string" and vt ~= "boolean") then
              flat = false
              break
            end
            copy[tk] = tv
          end
          if flat and n > 0 then constTables[k] = copy end
        end
      end
    end
    ns.Tick()
  end
  r.globals, r.namespaces, r.constants, r.constTables = globals, namespaces, constants, constTables
  r.globalCounts = counts
end)

probe("enums", function(r)
  local enums = {}
  for name, t in pairs(Enum or {}) do
    if type(t) == "table" then
      local copy = {}
      for k, v in pairs(t) do if type(v) == "number" or type(v) == "string" then copy[k] = v end end
      enums[name] = copy
    end
    ns.Tick()
  end
  r.enums = enums
end)

------------------------------------------------------------------ events
-- Which of the simulator's known events this client accepts.
probe("events", function(r)
  local invalid, valid = {}, 0
  local f = CreateFrame("Frame")
  local check = C_EventUtils and C_EventUtils.IsEventValid
  for _, ev in ipairs(ns.EVENTS) do
    local ok
    if check then ok = check(ev)
    else
      ok = pcall(f.RegisterEvent, f, ev)
      if ok then f:UnregisterEvent(ev) end
    end
    if ok then valid = valid + 1 else invalid[#invalid + 1] = ev end
    ns.Tick()
  end
  r.events = { checked = #ns.EVENTS, valid = valid, invalid = invalid, method = check and "IsEventValid" or "RegisterEvent" }
end)

------------------------------------------------------------------ cvars
-- Default values only (never the player's own settings).
probe("cvars", function(r)
  local out, missing = {}, 0
  local info = C_CVar and C_CVar.GetCVarInfo
  for _, name in ipairs(ns.CVARS) do
    local ok, value, default = pcall(info, name)
    if ok and value ~= nil then out[name] = default ~= nil and tostring(default) or "" else out[name] = false; missing = missing + 1 end
    ns.Tick()
  end
  r.cvars = out
  r.cvarsMissing = missing
end)

------------------------------------------------------------------ text
local FONTS = { "GameFontNormal", "GameFontHighlightSmall", "GameFontNormalLarge", "GameFontNormalHuge",
  "ChatFontNormal", "NumberFontNormal", "SystemFont_Shadow_Med1" }
local STRINGS = { "Hello", "The quick brown fox jumps over the lazy dog", "WWWWWWWWWW", "iiiiiiiiii",
  "1234567890", "|cffff0000Red|r text" }

probe("text", function(r)
  local holder = CreateFrame("Frame", nil, UIParent)
  holder:SetSize(10, 10)
  holder:SetPoint("BOTTOMLEFT")
  holder:SetAlpha(0)
  local out = {}
  for _, fontName in ipairs(FONTS) do
    local fo = _G[fontName]
    if fo then
      local fs = holder:CreateFontString(nil, "OVERLAY")
      fs:SetFontObject(fo)
      local _, size = fs:GetFont()
      local rec = { size = round(size), widths = {}, height = nil }
      for i, s in ipairs(STRINGS) do
        fs:SetText(s)
        rec.widths[i] = round(fs:GetStringWidth())
        if i == 1 then rec.height = round(fs:GetStringHeight()) end
      end
      -- wrapping at 120 px
      local wrap = holder:CreateFontString(nil, "OVERLAY")
      wrap:SetFontObject(fo)
      wrap:SetWidth(120)
      wrap:SetText(STRINGS[2] .. " " .. STRINGS[2])
      rec.wrapLines = wrap:GetNumLines()
      rec.wrapHeight = round(wrap:GetStringHeight())
      out[fontName] = rec
    end
    ns.Tick()
  end
  r.text = { strings = STRINGS, fonts = out }
  holder:Hide()
end)

------------------------------------------------------------------ layout
-- Anchor cases, as rects relative to a holder frame (UI scale doesn't matter).
probe("layout", function(r)
  local holder = CreateFrame("Frame", nil, UIParent)
  holder:SetSize(400, 300)
  holder:SetPoint("BOTTOMLEFT", 100, 100)
  holder:SetAlpha(0)
  local cases = {}
  local function add(name, build) cases[#cases + 1] = { name = name, frame = build() } end
  local function child(w, h) local f = CreateFrame("Frame", nil, holder); if w then f:SetSize(w, h) end; return f end
  add("topleft_right_row", function()
    local f = child(); f:SetHeight(24)
    f:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -100); f:SetPoint("RIGHT", holder); return f end)
  add("center", function() local f = child(50, 20); f:SetPoint("CENTER"); return f end)
  add("two_point_inset", function()
    local f = child(); f:SetPoint("TOPLEFT", 10, -10); f:SetPoint("BOTTOMRIGHT", -10, 10); return f end)
  add("left_center_nowidth", function()
    local f = child(); f:SetHeight(10); f:SetPoint("LEFT"); f:SetPoint("CENTER"); return f end)
  add("left_center_width", function()
    local f = child(30, 10); f:SetPoint("LEFT"); f:SetPoint("CENTER"); return f end)
  add("shorthand_rel_xy", function()
    local a = child(10, 10); a:SetPoint("BOTTOMLEFT", 20, 20)
    local f = child(10, 10); f:SetPoint("BOTTOMLEFT", a, 5, 0); return f end)
  add("scaled_half", function() local f = child(100, 100); f:SetScale(0.5); f:SetPoint("BOTTOMLEFT", 40, 40); return f end)
  add("fontstring_lr_wrap", function()
    local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 0, -200); fs:SetPoint("RIGHT", holder, "LEFT", 150, 0)
    fs:SetText("The quick brown fox jumps over the lazy dog, twice over.")
    return fs end)
  ns.WaitFrame() -- let the client resolve layout
  local hl, hb = holder:GetLeft(), holder:GetBottom()
  local out = {}
  for _, c in ipairs(cases) do
    local l, b, w, h = c.frame:GetRect()
    out[c.name] = l and { round(l - hl), round(b - hb), round(w), round(h) } or false
  end
  r.layout = out
  holder:Hide()
end)

------------------------------------------------------------------ behaviours
-- Small facts about how the client's Lua and API behave.
local B = {}
local function behaviour(name, fn) B[#B + 1] = { name, fn } end

behaviour("xpcall_passes_args", function()
  return select(2, xpcall(function(a, b) return a + b end, geterrorhandler(), 2, 3))
end)
behaviour("GetCVar_unknown_returns", function() return select("#", C_CVar.GetCVar("simcheck_no_such_cvar")) end)
behaviour("GetCVar_is_global", function() return type(GetCVar) end)
behaviour("GetAddOnMetadata_is_global", function() return type(GetAddOnMetadata) end)
behaviour("UnitFullName_realm", function()
  local _, realm = UnitFullName("player")
  if realm == nil then return "nil" end
  return realm:find("[%s%-]") and "unnormalized" or "normalized"
end)
behaviour("RegisterEvent_unknown", function()
  local ok, err = pcall(CreateFrame("Frame").RegisterEvent, CreateFrame("Frame"), "SIMCHECK_NO_SUCH_EVENT")
  return ok and "ok" or tostring(err):gsub("^.-: ", "")
end)
behaviour("hooksecurefunc_missing", function()
  local ok, err = pcall(hooksecurefunc, {}, "NoSuchMethod", function() end)
  return ok and "ok" or tostring(err):gsub("^.-: ", "")
end)
behaviour("tostring_frame", function() return (tostring(CreateFrame("Frame")):gsub("%x%x%x%x+", "<addr>")) end)
behaviour("tostring_named_frame", function() return tostring(UIParent) end)
behaviour("metatable_index_type", function() return type(getmetatable(UIParent).__index) end)
behaviour("frame_slot0_type", function() return type(rawget(UIParent, 0)) end)
behaviour("CreateFrame_ItemButton", function() return (pcall(CreateFrame, "ItemButton")) end)
behaviour("CreateFrame_AuraContainer", function() return (pcall(CreateFrame, "AuraContainer")) end)
behaviour("Line_SetStartPoint_shorthand", function()
  local l = CreateFrame("Frame"):CreateLine()
  return (pcall(l.SetStartPoint, l, "LEFT", 0, 0))
end)
behaviour("SetPoint_bad_point", function()
  local ok, err = pcall(CreateFrame("Frame").SetPoint, CreateFrame("Frame"), "NOWHERE")
  return ok and "ok" or tostring(err):gsub("^.-: ", "")
end)
behaviour("issecurevariable_addon_table", function()
  local t = {}; t.x = 1
  local secure, taint = issecurevariable(t, "x")
  return tostring(secure) .. "," .. tostring(taint)
end)
behaviour("GetNumAddOns_includes_unloaded", function()
  local n, loaded = C_AddOns.GetNumAddOns(), 0
  for i = 1, n do if C_AddOns.IsAddOnLoaded(i) then loaded = loaded + 1 end end
  return n > loaded
end)
behaviour("GetAddOnInfo_lod_reason", function()
  for i = 1, C_AddOns.GetNumAddOns() do
    if not C_AddOns.IsAddOnLoaded(i) and C_AddOns.IsAddOnLoadOnDemand(i) then
      return tostring(select(5, C_AddOns.GetAddOnInfo(i)))
    end
  end
  return "none"
end)
behaviour("strsplit_trailing", function() return select("#", strsplit(",", "a,b,")) end)
behaviour("format_nil_s", function() return (pcall(string.format, "%s", nil)) end)
behaviour("secret_values", function() return type(issecretvalue) end)
behaviour("GetTime_type", function() return math.type and math.type(GetTime()) or type(GetTime()) end)
behaviour("C_Timer_After_zero", function() return (pcall(C_Timer.After, 0, function() end)) end)
behaviour("UIParent_scale", function() return round(UIParent:GetScale()) end)

probe("behaviours", function(r)
  local out, errs = {}, {}
  for _, b in ipairs(B) do
    local ok, v = pcall(b[2])
    if ok then
      local t = type(v)
      out[b[1]] = (t == "string" or t == "number" or t == "boolean") and v or tostring(v)
    else
      errs[b[1]] = tostring(v):gsub("^.-: ", "")
    end
    ns.Tick()
  end
  r.behaviours, r.behaviourErrors = out, errs
end)
