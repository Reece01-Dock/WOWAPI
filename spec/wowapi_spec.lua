-- Self-tests for the emulator. Run: ./wowtest test spec
local FIX = SPEC_DIR .. "/fixtures"

local function newSim(opts)
  opts = opts or {}
  opts.quiet = true
  opts.addonPaths = { FIX }
  return WoW.new(opts)
end

describe("Lua environment", function()
  it("exposes WoW string helpers with WoW semantics", function()
    local sim = newSim()
    local ok, a, b, c = sim:Exec('return strsplit(",;", "a,b;c")')
    expect({ a, b, c }).to_equal({ "a", "b", "c" })
    local _, x, y = sim:Exec('return strsplit(" ", "one two three", 2)')
    expect({ x, y }).to_equal({ "one", "two three" })
    local _, t = sim:Exec('return strtrim("  hi \\n")')
    expect(t).to_be("hi")
    local _, j = sim:Exec('return strjoin("-", "a", 1, true)')
    expect(j).to_be("a-1-true")
    local _, m = sim:Exec('return ("  x "):trim()')
    expect(m).to_be("x")
  end)

  it("uses degrees for global trig functions", function()
    local sim = newSim()
    local _, v = sim:Exec("return sin(90)")
    expect(v).to_be_close_to(1)
  end)

  it("hides io, os and require from addons", function()
    local sim = newSim()
    local _, io_, os_, req = sim:Exec("return io, os, require")
    expect(io_).to_be_nil()
    expect(os_).to_be_nil()
    expect(req).to_be_nil()
  end)

  it("provides a working bit library", function()
    local sim = newSim()
    local _, a, o, x, l, r = sim:Exec("return bit.band(12, 10), bit.bor(12, 10), bit.bxor(12, 10), bit.lshift(1, 4), bit.rshift(256, 4)")
    expect({ a, o, x, l, r }).to_equal({ 8, 14, 6, 16, 16 })
  end)

  it("reports the WoW: Forever build", function()
    local sim = newSim()
    local _, v, _, _, iface = sim:Exec("return GetBuildInfo()")
    expect(iface).to_be(16001)
    expect(v).to_be("1.60.1")
  end)

  it("does not define removed legacy globals unless asked", function()
    expect(newSim():Get("GetAddOnMetadata")).to_be_nil()
    expect(newSim({ legacyGlobals = true }):Get("GetAddOnMetadata")).to_be_type("function")
  end)

  it("makes math.random deterministic per seed", function()
    local a, b = newSim({ seed = 7 }), newSim({ seed = 7 })
    local _, x = a:Exec("return math.random(1, 1000)")
    local _, y = b:Exec("return math.random(1, 1000)")
    expect(x).to_be(y)
  end)
end)

describe("events", function()
  it("dispatches in registration order and supports unregistering", function()
    local sim = newSim()
    sim:Exec([[
      log = {}
      a = CreateFrame("Frame"); b = CreateFrame("Frame")
      a:SetScript("OnEvent", function(_, e, x) tinsert(log, "a" .. x) end)
      b:SetScript("OnEvent", function(_, e, x) tinsert(log, "b" .. x) end)
      a:RegisterEvent("BAG_UPDATE"); b:RegisterEvent("BAG_UPDATE")
    ]])
    sim:FireEvent("BAG_UPDATE", 1)
    sim:Get("a"):UnregisterEvent("BAG_UPDATE")
    sim:FireEvent("BAG_UPDATE", 2)
    expect(sim:Get("log")).to_equal({ "a1", "b1", "b2" })
    expect(sim:EventCount("BAG_UPDATE")).to_be(2)
  end)

  it("rejects events that don't exist, like the client", function()
    local sim = newSim()
    local ok, err = sim:Exec('CreateFrame("Frame"):RegisterEvent("PLAYER_LOGGIN")')
    expect(ok).to_be(false)
    expect(err).to_match('Attempt to register unknown event "PLAYER_LOGGIN"')
    sim:ClearErrors()
  end)

  it("keeps running other handlers when one errors", function()
    local sim = newSim()
    sim:Exec([[
      ran = false
      local a = CreateFrame("Frame"); a:RegisterEvent("BAG_UPDATE"); a:SetScript("OnEvent", function() error("boom") end)
      local b = CreateFrame("Frame"); b:RegisterEvent("BAG_UPDATE"); b:SetScript("OnEvent", function() ran = true end)
    ]])
    sim:FireEvent("BAG_UPDATE")
    expect(sim:Get("ran")).to_be(true)
    expect(#sim.errors).to_be(1)
    expect(sim.errors[1].message).to_match("boom")
    sim:ClearErrors()
  end)

  it("fires the login sequence in client order", function()
    local sim = newSim()
    sim:Login()
    local names = {}
    for _, e in ipairs(sim.firedEvents) do names[#names + 1] = e.event end
    expect(names).to_equal({ "SPELLS_CHANGED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "VARIABLES_LOADED" })
    expect(sim.firedEvents[3].args[1]).to_be(true) -- isInitialLogin
  end)

  it("supports EventUtil.ContinueOnAddOnLoaded", function()
    local sim = newSim()
    sim:Exec('EventUtil.ContinueOnAddOnLoaded("LibThing", function() libReady = LibThing.version end)')
    sim:LoadAddon("LibThing")
    expect(sim:Get("libReady")).to_be(3)
  end)
end)

describe("timers", function()
  it("runs C_Timer.After, NewTicker and respects Cancel", function()
    local sim = newSim()
    sim:Exec([[
      n, after = 0, false
      ticker = C_Timer.NewTicker(1, function() n = n + 1 end)
      C_Timer.After(2.5, function() after = true end)
      local t = C_Timer.NewTimer(1, function() cancelledRan = true end)
      t:Cancel()
    ]])
    sim:Advance(3)
    expect(sim:Get("n")).to_be(3)
    expect(sim:Get("after")).to_be(true)
    expect(sim:Get("cancelledRan")).to_be_nil()
    sim:Get("ticker"):Cancel()
    sim:Advance(5)
    expect(sim:Get("n")).to_be(3)
  end)

  it("stops a ticker after its iteration count", function()
    local sim = newSim()
    sim:Exec("k = 0; C_Timer.NewTicker(0.5, function() k = k + 1 end, 2)")
    sim:Advance(10)
    expect(sim:Get("k")).to_be(2)
  end)

  it("only runs OnUpdate for visible frames", function()
    local sim = newSim()
    sim:Exec([[
      ticks = 0
      parent = CreateFrame("Frame")
      child = CreateFrame("Frame", nil, parent)
      child:SetScript("OnUpdate", function(_, dt) ticks = ticks + 1 end)
    ]])
    sim:Advance(1)
    expect(sim:Get("ticks")).to_be(32)
    sim:Get("parent"):Hide()
    sim:Advance(1)
    expect(sim:Get("ticks")).to_be(32)
  end)
end)

describe("widgets", function()
  it("creates named frames as globals and resolves $parent", function()
    local sim = newSim()
    sim:Exec('local p = CreateFrame("Frame", "MyParent"); CreateFrame("Button", "$parentButton", p)')
    expect(sim:Get("MyParentButton"):GetObjectType()).to_be("Button")
    expect(sim:Get("MyParentButton"):IsObjectType("Frame")).to_be(true)
    expect(sim:Get("MyParentButton"):GetParent()).to_be(sim:Get("MyParent"))
  end)

  it("fires OnShow/OnHide only on real visibility changes", function()
    local sim = newSim()
    sim:Exec([[
      log = {}
      f = CreateFrame("Frame")
      f:SetScript("OnShow", function() tinsert(log, "show") end)
      f:SetScript("OnHide", function() tinsert(log, "hide") end)
      f:Show(); f:Hide(); f:Hide(); f:Show()
    ]])
    expect(sim:Get("log")).to_equal({ "hide", "show" })
  end)

  it("clamps StatusBar values and fires OnValueChanged", function()
    local sim = newSim()
    sim:Exec([[
      changes = 0
      bar = CreateFrame("StatusBar")
      bar:SetScript("OnValueChanged", function() changes = changes + 1 end)
      bar:SetMinMaxValues(0, 100)
      bar:SetValue(150)
    ]])
    expect(sim:Get("bar"):GetValue()).to_be(100)
    expect(sim:Get("changes")).to_be(1)
  end)

  it("toggles CheckButtons on click and chains HookScript", function()
    local sim = newSim()
    sim:Exec([[
      order = {}
      cb = CreateFrame("CheckButton", "MyCheck", UIParent, "UICheckButtonTemplate")
      cb:SetScript("OnClick", function(self) tinsert(order, "click:" .. tostring(self:GetChecked())) end)
      cb:HookScript("OnClick", function() tinsert(order, "hook") end)
      cb.Text:SetText("Enable")
    ]])
    sim:Click("MyCheck")
    expect(sim:Get("order")).to_equal({ "click:true", "hook" })
    expect(sim:Get("MyCheck").Text:GetText()).to_be("Enable")
  end)

  it("lets EditBoxes be typed into", function()
    local sim = newSim()
    sim:Exec([[
      eb = CreateFrame("EditBox")
      eb:SetScript("OnEnterPressed", function(self) submitted = self:GetText() end)
    ]])
    sim:Type(sim:Get("eb"), "hello")
    sim:PressEnter(sim:Get("eb"))
    expect(sim:Get("submitted")).to_be("hello")
  end)

  it("errors on methods that don't exist", function()
    local sim = newSim()
    local ok = sim:Exec('local f = CreateFrame("Frame"); f:NotARealMethod()')
    expect(ok).to_be(false)
    expect(sim.errors[1].message).to_match("NotARealMethod")
    sim:ClearErrors()
  end)

  it("has every documented widget method, with state for Set/Get pairs", function()
    local sim = newSim()
    local _, clamped, kb, l, r, t, b = sim:Exec([[
      local f = CreateFrame("Frame")
      f:SetClampedToScreen(true)
      f:SetClampRectInsets(1, 2, 3, 4)
      f:EnableKeyboard(true)
      return f:IsClampedToScreen(), f:IsKeyboardEnabled(), f:GetClampRectInsets()
    ]])
    expect({ clamped, kb, l, r, t, b }).to_equal({ true, true, 1, 2, 3, 4 })
  end)

  it("checks widget method argument types", function()
    local sim = newSim()
    local ok, err = sim:Exec('CreateFrame("Frame"):SetAlpha("very")')
    expect(ok).to_be(false)
    expect(err).to_match("bad argument #1 to 'Frame:SetAlpha'")
    sim:ClearErrors()
  end)

  it("rejects unknown frame types", function()
    local sim = newSim()
    expect(sim:Exec('CreateFrame("Framee")')).to_be(false)
    sim:ClearErrors()
  end)
end)

describe("documented API", function()
  it("defines every documented function with typed defaults", function()
    local sim = newSim()
    local _, info, n, name = sim:Exec([[
      return C_PvP.GetZonePVPInfo and "has" or "missing", C_CurrencyInfo.GetCurrencyListSize(), C_BattleNet.GetAccountInfoByID and "has"
    ]])
    expect(info).to_be("has")
    expect(n).to_be(0)
    expect(name).to_be("has")
  end)

  it("fills in documented structures", function()
    local sim = newSim()
    local _, info = sim:Exec("return C_Map.GetMapInfo(1)")
    expect(info.mapID).to_be(1)
    local _, q = sim:Exec("return C_QuestLog.GetInfo(1)")
    expect(q).to_be_nil() -- nilable return stays nil
  end)

  it("ships the full Enum and Constants tables", function()
    local sim = newSim()
    local _, a, b = sim:Exec("return Enum.ItemQuality.Epic, Enum.AddOnEnableState.All")
    expect({ a, b }).to_equal({ 4, 2 })
    expect(sim:Get("Constants")).to_be_type("table")
  end)

  it("validates arguments to C_ functions", function()
    local sim = newSim()
    local ok, err = sim:Exec("C_Timer.After(nil, function() end)")
    expect(ok).to_be(false)
    expect(err).to_match("bad argument #1 to 'C_Timer.After'")
    sim:ClearErrors()
  end)

  it("can mock any function and records calls", function()
    local sim = newSim()
    sim:Mock("C_Map.GetBestMapForUnit", 2112)
    sim:Mock("UnitHealth", function(unit) return unit == "target" and 5 or 10 end)
    local _, map, h1, h2 = sim:Exec('return C_Map.GetBestMapForUnit("player"), UnitHealth("target"), UnitHealth("player")')
    expect({ map, h1, h2 }).to_equal({ 2112, 5, 10 })
    expect(sim:CallCount("UnitHealth")).to_be(2)
    expect(sim:Calls("UnitHealth")[1][1]).to_be("target")
    sim:Unmock("UnitHealth")
    local _, h = sim:Exec('return UnitHealth("player")')
    expect(h).to_be(5000)
  end)

  it("describes signatures", function()
    local sim = newSim()
    expect(sim:Doc("C_Timer.After")).to_match("seconds: number")
    expect(sim:Doc("Frame:SetAlpha")).to_match("alpha: SingleColorValue")
  end)
end)

describe("API helpers", function()
  it("hooksecurefunc runs after the original and keeps return values", function()
    local sim = newSim()
    sim:Exec([[
      function Add(a, b) return a + b end
      hooksecurefunc("Add", function(a, b) hooked = a .. "+" .. b end)
      result = Add(2, 3)
    ]])
    expect(sim:Get("result")).to_be(5)
    expect(sim:Get("hooked")).to_be("2+3")
  end)

  it("formats money and big numbers", function()
    local sim = newSim()
    local _, a, b = sim:Exec("return GetCoinText(1234567), BreakUpLargeNumbers(1234567)")
    expect(a).to_be("123 Gold, 45 Silver, 67 Copper")
    expect(b).to_be("1,234,567")
  end)

  it("answers unit queries from the simulated player", function()
    local sim = newSim({ player = { name = "Jaina", class = "MAGE", race = "Human", level = 42 } })
    local _, name, cls, file, lvl = sim:Exec('local n = UnitName("player"); local c, f = UnitClass("player"); return n, c, f, UnitLevel("player")')
    expect({ name, cls, file, lvl }).to_equal({ "Jaina", "Mage", "MAGE", 42 })
    sim:SetTarget({ name = "Hogger", hostile = true, level = 11 })
    local _, tname, attack = sim:Exec('return UnitName("target"), UnitCanAttack("player", "target")')
    expect({ tname, attack }).to_equal({ "Hogger", true })
  end)

  it("serves items, spells and auras you register", function()
    local sim = newSim({ items = { [6948] = { name = "Hearthstone", quality = 1 } },
      spells = { [8936] = { name = "Regrowth" } } })
    sim.player.auras = { { name = "Regrowth", spellId = 8936, duration = 12 } }
    local _, item, spell, aura = sim:Exec([[
      return C_Item.GetItemInfo(6948), C_Spell.GetSpellInfo(8936).name,
        C_UnitAuras.GetPlayerAuraBySpellID(8936).duration
    ]])
    expect({ item, spell, aura }).to_equal({ "Hearthstone", "Regrowth", 12 })
  end)

  it("runs StaticPopup callbacks", function()
    local sim = newSim()
    sim:Exec([[
      StaticPopupDialogs.CONFIRM = { text = "Delete %s?", button1 = YES, OnAccept = function(self, data) deleted = data end }
      StaticPopup_Show("CONFIRM", "stuff", nil, 42)
    ]])
    local popup = sim.popups[1]
    expect(popup.text:GetText()).to_be("Delete stuff?")
    sim:Get("StaticPopupDialogs").CONFIRM.OnAccept(popup, popup.data)
    expect(sim:Get("deleted")).to_be(42)
  end)

  it("unknown slash commands print the client's help hint", function()
    local sim = newSim()
    expect(sim:Slash("/nope")).to_be(false)
    expect(sim:LastChat()).to_match("/help")
  end)
end)

describe("addon loading", function()
  it("loads required dependencies first and passes name + namespace", function()
    local sim = newSim()
    local ok, ns = sim:LoadAddon("NeedsLib")
    expect(ok).to_be(true)
    expect(ns.answer).to_be(42)
    expect(ns.loadedName).to_be("NeedsLib")
    expect(sim.addonOrder).to_equal({ "NeedsLib", "LibThing" })
    local _, loaded = sim:Exec('return C_AddOns.IsAddOnLoaded("LibThing")')
    expect(loaded).to_be(true)
    local _, site = sim:Exec('return C_AddOns.GetAddOnMetadata("NeedsLib", "X-Website")')
    expect(site).to_be("https://example.com")
  end)

  it("keeps loading after syntax errors, missing files and runtime errors", function()
    local sim = newSim()
    sim:LoadAddon("Broken")
    expect(sim:Get("BrokenGoodRan")).to_be(true)
    local all = {}
    for _, e in ipairs(sim.errors) do all[#all + 1] = e.message end
    all = table.concat(all, "\n")
    expect(all).to_match("Syntax.lua")
    expect(all).to_match("Missing.lua")
    expect(all).to_match("SetSizee")
    expect(sim.warnings[1]).to_match("Interface: 11507")
    sim:ClearErrors()
  end)

  it("reports a missing addon", function()
    local ok, why = newSim():LoadAddon("DoesNotExist")
    expect(ok).to_be(false)
    expect(why).to_be("MISSING")
  end)
end)

describe("toc parsing", function()
  it("reads metadata, lists and file lines", function()
    local t = WoW.toc.parse([[
## Interface: 16001, 110200
## Title: |cff00ff00Thing|r
## SavedVariables: A, B
## SavedVariablesPerCharacter: C
# a comment
Core.lua
Sub\File.lua
Classic.lua [AllowLoadGameType classic]
Retail.lua [AllowLoadGameType standard]
Forever.lua [ExcludeLoadGameType standard, classic][AllowLoadGameType camelot]
]], "Thing")
    expect(t.interface).to_equal({ "16001", "110200" })
    expect(t.savedVariables).to_equal({ "A", "B" })
    expect(t.savedVariablesPerCharacter).to_equal({ "C" })
    expect(t.files).to_equal({ "Core.lua", "Sub/File.lua", "Forever.lua" })
  end)
end)

describe("SavedVariables", function()
  it("serializes to loadable Lua", function()
    local src = WoW.serialize.file({ DB = { a = 1, list = { "x", "y" }, nested = { ok = true }, fn = print } })
    local env = {}
    local chunk = (loadstring or load)(src)
    if setfenv then setfenv(chunk, env) else chunk = load(src, "sv", "t", env) end
    chunk()
    expect(env.DB).to_equal({ a = 1, list = { "x", "y" }, nested = { ok = true } })
  end)

  it("writes and reads WTF files on disk", function()
    local dir = os.tmpname()
    os.remove(dir)
    local sim = WoW.new({ quiet = true, savedVariablesDir = dir, addonPaths = { FIX } })
    sim:Exec("LibThing = nil")
    -- use a throwaway addon with SavedVariables
    local root = dir .. "_addons/SVAddon"
    os.execute('mkdir -p "' .. root .. '"')
    local f = io.open(root .. "/SVAddon.toc", "w"); f:write("## SavedVariables: SVAddonDB\nMain.lua\n"); f:close()
    f = io.open(root .. "/Main.lua", "w"); f:write("SVAddonDB = SVAddonDB or { runs = 0 }\n"); f:close()
    sim:LoadAddon(root)
    sim:Get("SVAddonDB").runs = 5
    sim:Logout()
    local fresh = WoW.new({ quiet = true, savedVariablesDir = dir })
    fresh:LoadAddon(root)
    expect(fresh:Get("SVAddonDB").runs).to_be(5)
    os.execute('rm -rf "' .. dir .. '" "' .. dir .. '_addons"')
  end)
end)
