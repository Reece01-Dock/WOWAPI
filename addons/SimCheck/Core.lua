local addonName, ns = ...

-- SimCheck: record how the real client behaves, so `wowtest compare` can
-- check the simulator against it. Results go to SavedVariables (SimCheckDB),
-- which the game writes when you log out or /reload.

local VERSION = 1
local BUDGET_MS = 8        -- time per frame spent probing
local LOGIN_WINDOW = 15    -- seconds of login events to record

------------------------------------------------------------------ login events
-- Recorded from the moment this file loads: which events fire, in order.
local login = { order = {}, counts = {}, sequence = {} }
ns.login = login
local recorder = CreateFrame("Frame")
local recording = true
local enteredAt
if not pcall(recorder.RegisterAllEvents, recorder) then login.unavailable = true end
recorder:SetScript("OnEvent", function(_, event, arg1)
  if not recording then return end
  if not login.counts[event] then
    login.counts[event] = 0
    if #login.order < 400 then login.order[#login.order + 1] = event end
  end
  login.counts[event] = login.counts[event] + 1
  if #login.sequence < 80 then
    login.sequence[#login.sequence + 1] = (event == "ADDON_LOADED" and arg1 == addonName) and (event .. ":self") or event
  end
  if event == "PLAYER_ENTERING_WORLD" and not enteredAt then enteredAt = GetTime() end
end)

------------------------------------------------------------------ runner
local runner = CreateFrame("Frame")
local state = { running = false, index = 0, co = nil, result = nil, done = false }
ns.state = state

function ns.Tick()
  if debugprofilestop() - ns.frameStart > BUDGET_MS then coroutine.yield() end
end

function ns.WaitFrame() coroutine.yield("frame") end

local function finish()
  local r = state.result
  r.login = login
  r.meta.finished = date("!%Y-%m-%d %H:%M:%S")
  r.meta.seconds = math.floor((debugprofilestop() - state.startedMs) / 10) / 100
  SimCheckDB.result = r
  state.running, state.done = false, true
  runner:SetScript("OnUpdate", nil)
  local c = r.client or {}
  print(string.format("|cff33ff99SimCheck|r done in %.1fs: interface %s, game type %s, project %s. "
    .. "|cffffd200/reload or log out to save|r, then run |cffffffffwowtest compare|r on SimCheck.lua.",
    r.meta.seconds, tostring(c.interface), table.concat(c.gameTypes or {}, "/") ~= "" and table.concat(c.gameTypes, "/") or "?",
    tostring(c.projectId)))
  if ns.OnFinished then ns.OnFinished(r) end
end

local function step()
  ns.frameStart = debugprofilestop()
  while state.running do
    if not state.co then
      state.index = state.index + 1
      local p = ns.probes[state.index]
      if not p then finish(); return end
      state.current = p.name
      state.co = coroutine.create(function() p.run(state.result) end)
      if ns.OnProgress then ns.OnProgress(state.index - 1, #ns.probes, p.name) end
    end
    local ok, what = coroutine.resume(state.co, state.result)
    if not ok then
      state.result.errors[state.current] = tostring(what)
      state.co = nil
    elseif coroutine.status(state.co) == "dead" then
      state.co = nil
    elseif what == "frame" or debugprofilestop() - ns.frameStart > BUDGET_MS then
      return -- continue next frame
    end
  end
end

function ns.Run()
  if state.running then return end
  -- let login events finish recording first
  local waitFor = enteredAt and (LOGIN_WINDOW - (GetTime() - enteredAt)) or LOGIN_WINDOW
  if recording and waitFor > 0 then
    print(string.format("|cff33ff99SimCheck|r starts in %d seconds (recording login events)...", math.ceil(waitFor)))
    C_Timer.After(waitFor, ns.Run)
    state.waiting = true
    if ns.OnProgress then ns.OnProgress(0, #ns.probes, "waiting for login to settle") end
    return
  end
  recording = false
  recorder:UnregisterAllEvents()
  state.waiting = false
  state.running, state.done, state.index, state.co = true, false, 0, nil
  state.startedMs = debugprofilestop()
  state.result = {
    meta = { format = VERSION, addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version"),
      started = date("!%Y-%m-%d %H:%M:%S") },
    errors = {},
  }
  print("|cff33ff99SimCheck|r probing the client...")
  runner:SetScript("OnUpdate", step)
end

------------------------------------------------------------------ startup
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == addonName then
    SimCheckDB = SimCheckDB or {}
  elseif event == "PLAYER_ENTERING_WORLD" then
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    -- probe automatically once per client build
    local last = SimCheckDB.result and SimCheckDB.result.client
    local build = select(2, GetBuildInfo())
    if not last or last.build ~= build then ns.Run() end
  end
end)

SLASH_SIMCHECK1 = "/simcheck"
SlashCmdList.SIMCHECK = function(msg)
  msg = strtrim(msg or ""):lower()
  if msg == "run" then
    ns.Run()
    if ns.ShowWindow then ns.ShowWindow() end
  elseif msg == "reset" then
    SimCheckDB.result = nil
    print("|cff33ff99SimCheck|r results cleared.")
  elseif ns.ToggleWindow then
    ns.ToggleWindow()
  end
end
