-- The SimCheck addon (addons/SimCheck) and `wowtest compare`: the addon runs
-- in the real client and in the simulator; differences are reported and the
-- real values can be imported.
local cal = require("wowapi.calibrate")
local realclient = require("wowapi.realclient")

-- A "real client" result: the simulator's own, changed the way a real
-- Forever client might differ.
local function fakeReal()
  local r = cal.runInSim()
  r.client.projectId = 42
  r.client.build = "99999"
  local inv = {}
  for _, e in ipairs(r.events.invalid) do if e ~= "UNIT_HEALTH_FREQUENT" then inv[#inv + 1] = e end end
  inv[#inv + 1] = "UNIT_HEALTH"
  r.events.invalid = inv
  r.globals.AuraContainerSortMethod = "t"
  r.globals.FakeRealFunction = "f"
  r.globals.FakeRealFrame = "w:Button"
  r.constTables.AuraContainerSortMethod = { Default = 0, Expiration = 1 }
  r.enums.FakeRealEnum = { A = 1 }
  r.namespaces.FakeRealMixin = { OnSomethingOdd = "f" }
  r.behaviours.issecurevariable_addon_table = "false,SimCheck"
  r.cvars.nameplateShowOnlyNames = false
  return r
end

describe("SimCheck addon", function()
  it("runs in the simulator and records every section", function()
    local r = cal.runInSim()
    expect(r.client.interface).to_be(16001)
    expect(r.client.gameTypes).to_equal({ "camelot" })
    expect(r.client.game).to_be("Camelot")
    expect(r.events.checked > 1000).to_be(true)
    expect(next(r.globals) ~= nil).to_be(true)
    expect(next(r.errors)).to_be(nil)
    expect(r.login.sequence[1]).to_be("ADDON_LOADED:self")
    expect(r.layout.topleft_right_row).to_equal({ 0, 176, 400, 24 })
  end)

  it("shows its window", function()
    local sim = WoW.new({ quiet = true })
    sim:LoadAddon("addons/SimCheck")
    sim:Login()
    sim:Slash("/simcheck")
    expect(sim:Get("SimCheckFrame"):IsShown()).to_be(true)
  end)
end)

describe("wowtest compare", function()
  it("finds every difference and nothing else", function()
    local real = fakeReal()
    local simr, sim = cal.runInSim()
    local found = {}
    for _, s in ipairs(cal.compare(real, simr, sim)) do found[s.title:match("^(%S+)")] = s.count end
    expect(found.Client).to_be(2)
    expect(found.Behaviour).to_be(1)
    expect(found.Events).to_be(2)
    expect(found.Login).to_be(0)
    expect(found.Layout).to_be(0)
    expect(found.Probe).to_be(0)
    expect(found.CVars).to_be(1)
  end)

  it("imports the real values into the simulator", function()
    local data = cal.importData(fakeReal())
    realclient.use(data)
    local ok, err = pcall(function()
      local sim = WoW.new({ quiet = true })
      expect(sim:Get("WOW_PROJECT_ID")).to_be(42)
      expect(select(2, sim:Exec("return select(2, GetBuildInfo())"))).to_be("99999")
      expect(sim:Get("AuraContainerSortMethod").Expiration).to_be(1)
      expect(sim:Get("Enum").FakeRealEnum.A).to_be(1)
      expect(type(sim:Get("FakeRealFunction"))).to_be("function")
      expect(sim:Get("FakeRealFrame"):GetObjectType()).to_be("Button")
      expect(rawget(sim:Get("FakeRealMixin"), "OnSomethingOdd") ~= nil).to_be(true)
      local _, okOld = sim:Exec("return pcall(CreateFrame('Frame').RegisterEvent, CreateFrame('Frame'), 'UNIT_HEALTH_FREQUENT')")
      expect(okOld).to_be(true)
      local _, okNew = sim:Exec("return pcall(CreateFrame('Frame').RegisterEvent, CreateFrame('Frame'), 'UNIT_HEALTH')")
      expect(okNew).to_be(false)
      expect(select(2, sim:Exec("return C_CVar.GetCVar('nameplateShowOnlyNames')"))).to_be(nil)
    end)
    realclient.use(nil)
    if not ok then error(err, 0) end
    -- back to the simulator's own values
    expect(WoW.new({ quiet = true }):Get("WOW_PROJECT_ID")).to_be(1)
  end)

  it("reads SimCheck's SavedVariables file", function()
    local path = os.tmpname()
    local f = io.open(path, "w")
    f:write("SimCheckDB = " .. require("wowapi.serialize").serialize({ result = { client = { build = "1" } } }))
    f:close()
    local r = cal.loadSaved(path)
    expect(r.client.build).to_be("1")
    f = io.open(path, "w"); f:write("SimCheckDB = {}"); f:close()
    local none, err = cal.loadSaved(path)
    expect(none).to_be(nil)
    expect(err).to_match("no SimCheck results")
    os.remove(path)
  end)
end)
