-- The simulated game client. One Sim = one WoW client session with its
-- own global environment, frames, events, clock and SavedVariables.
local compat = require("wowapi.compat")
local toc = require("wowapi.toc")
local serialize = require("wowapi.serialize")
local widgets = require("wowapi.widgets")
local api = require("wowapi.api")
local docs = require("wowapi.docs")
local layout = require("wowapi.layout")
local render = require("wowapi.render")
local unpack = compat.unpack

local Sim = {}
Sim.__index = Sim

local DEFAULT_PLAYER = {
  name = "Tester", realm = "Forever", class = "WARRIOR", race = "Human", faction = "Alliance",
  sex = 2, level = 60, health = 5000, healthMax = 5000, power = 100, powerMax = 100,
  powerType = 1, money = 1234567, guild = nil, zone = "Elwynn Forest", subZone = "Goldshire",
  guid = "Player-1-00000001", mapID = 1429,
}

local DEFAULT_BUILD = { version = "1.60.1", build = "60101", date = "Sep 1 2026", interface = 16001 }

local listeners = {}
-- Called with every new Sim (the test runner uses this to police errors).
function Sim.onNew(fn) table.insert(listeners, fn) end

function Sim.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Sim)
  self.opts = opts
  self.build = setmetatable(opts.build or {}, { __index = DEFAULT_BUILD })
  self.locale = opts.locale or "enUS"
  self.addonPaths = {}
  for _, p in ipairs(opts.addonPaths or {}) do self.addonPaths[#self.addonPaths + 1] = p end
  self.savedVariablesDir = opts.savedVariablesDir
  -- Survives /reload: { account = { [addon] = { var = value } }, character = {...} }
  self.store = { account = {}, character = {} }
  self.quiet = opts.quiet
  self:_reset()
  for _, fn in ipairs(listeners) do fn(self) end
  return self
end

-- (Re)build all client state except SavedVariables. Used by new and /reload.
function Sim:_reset()
  local opts = self.opts
  self.time = opts.startTime or 100.0
  self.epoch = opts.now or 1790000000 -- deterministic server time()
  self.loggedIn = false
  self.inCombat = false
  self.lockdown = false
  self.hardwareEvent = false
  self.menus = {}
  self.menuModifiers = {}
  self.eventFrames = {}
  self.allEventFrames = setmetatable({}, { __mode = "k" })
  self.onUpdateFrames = {}
  self.timers = {}
  self.timerSeq = 0
  self.chat = {}
  self.sentChat = {}
  self.addonMessages = {}
  self.firedEvents = {}
  self.errors = {}
  self.warnings = {}
  self.stubbedCalls = {}
  self.undefinedGlobals = {}
  self.createdGlobals = {}
  self.sounds = {}
  self.frameCount = 0
  self.addons = {}
  self.addonOrder = {}
  self.eventCallbacks = {}
  self.units = {}
  local p = {}
  for k, v in pairs(DEFAULT_PLAYER) do p[k] = v end
  for k, v in pairs(opts.player or {}) do p[k] = v end
  self.units.player = p
  self.player = p
  self.items = {}
  self.spells = {}
  for id, v in pairs(opts.items or {}) do self:AddItem(id, v) end
  for id, v in pairs(opts.spells or {}) do self:AddSpell(id, v) end
  self.cvars = {}
  self.popups = {}
  self.chatFilters = {}
  self.bags = {}
  self.modifiers = {}
  self.uiErrors = {}
  self.settingsCategories = {}
  self.addonMessagePrefixes = {}
  self.errorHandler = nil
  self.reloadRequested = false

  local env = {}
  self.env = env
  local sim = self
  setmetatable(env, {
    __index = function(_, k)
      if sim._lazyGlobal then
        local v, found = sim._lazyGlobal(k)
        if found then return v end
      end
      if type(k) == "string" then sim.undefinedGlobals[k] = (sim.undefinedGlobals[k] or 0) + 1 end
      return nil
    end,
    __newindex = function(t, k, v)
      if sim.currentAddon and type(k) == "string" then
        sim.createdGlobals[k] = sim.currentAddon
      end
      rawset(t, k, v)
    end,
  })
  require("wowapi.templates").install(self, env)
  widgets.install(self, env)
  api.install(self, env)
  docs.install(self, env)
  require("wowapi.input").install(self, env)
  require("wowapi.framexml").install(self, env)
  require("wowapi.secure").install(self, env)
  require("wowapi.xml").install(self)
  require("wowapi.resources").install(self, env)
  require("wowapi.secrets").install(self, env)
end

-------------------------------------------------------------------- utils

local function traceback(err)
  local tb = debug.traceback(tostring(err), 2)
  return { message = tostring(err), traceback = tb }
end

-- Run fn protected, capture errors the way the client's error frame would.
function Sim:_pcall(fn, ...)
  local args, n = { ... }, select("#", ...)
  local function pack(...) return { n = select("#", ...), ... } end
  local res = pack(xpcall(function() return fn(unpack(args, 1, n)) end, traceback))
  if not res[1] then
    local e = res[2]
    table.insert(self.errors, e)
    if self.errorHandler then pcall(self.errorHandler, e.message) end
    if not self.quiet then io.stderr:write("|cffff0000Lua error|r: " .. e.message .. "\n") end
    return false, e.message
  end
  return true, unpack(res, 2, res.n)
end

function Sim:_warn(msg)
  table.insert(self.warnings, msg)
end

function Sim:_runScript(obj, script, ...)
  local s = self.widgetState[obj]
  if not s then return end
  local fn = s.scripts[script]
  if not fn then return end
  self:_pcall(fn, obj, ...)
  local hooks = s.hooks[script]
  if hooks then
    for _, h in ipairs(hooks) do self:_pcall(h, obj, ...) end
  end
end

-------------------------------------------------------------------- events

function Sim:_registerEvent(frame, event, units)
  local s = self.widgetState[frame]
  if s.events[event] == nil then
    self.eventFrames[event] = self.eventFrames[event] or {}
    table.insert(self.eventFrames[event], frame)
  end
  s.events[event] = units or true
end

function Sim:_unregisterEvent(frame, event)
  local s = self.widgetState[frame]
  if s.events[event] == nil then return end
  s.events[event] = nil
  local list = self.eventFrames[event]
  for i = #list, 1, -1 do if list[i] == frame then table.remove(list, i) end end
end

-- Fire a game event at every frame registered for it.
function Sim:FireEvent(event, ...)
  if self.knownEvents and not self.knownEvents[event] and not (self.warnedEvents or {})[event] then
    self.warnedEvents = self.warnedEvents or {}
    self.warnedEvents[event] = true
    self:_warn("FireEvent: '" .. tostring(event) .. "' is not a documented game event")
  end
  table.insert(self.firedEvents, { event = event, args = { n = select("#", ...), ... } })
  local list = self.eventFrames[event]
  if list then
    local snapshot = { unpack(list) }
    local unit = ...
    for _, frame in ipairs(snapshot) do
      local reg = self.widgetState[frame].events[event]
      if reg == true then
        self:_runScript(frame, "OnEvent", event, ...)
      elseif type(reg) == "table" then
        for _, u in ipairs(reg) do
          if u == unit then self:_runScript(frame, "OnEvent", event, ...); break end
        end
      end
    end
  end
  for frame in pairs(self.allEventFrames) do
    if self.widgetState[frame].allEvents and self.widgetState[frame].events[event] == nil then
      self:_runScript(frame, "OnEvent", event, ...)
    end
  end
  local cbs = self.eventCallbacks[event]
  if cbs then
    for _, cb in ipairs({ unpack(cbs) }) do self:_pcall(cb.fn, cb.owner, ...) end
  end
  if self.stateDrivers and next(self.stateDrivers) and event ~= "ADDON_ACTION_BLOCKED" and event ~= "ADDON_ACTION_FORBIDDEN" then
    require("wowapi.secure").evaluateDrivers(self)
  end
end

-- Was `event` fired (optionally: how many times)?
function Sim:EventCount(event)
  local n = 0
  for _, e in ipairs(self.firedEvents) do if e.event == event then n = n + 1 end end
  return n
end

function Sim:IsEventRegistered(event)
  return self.eventFrames[event] ~= nil and #self.eventFrames[event] > 0
end

-------------------------------------------------------------------- time

function Sim:_trackOnUpdate(frame, on)
  for i, f in ipairs(self.onUpdateFrames) do
    if f == frame then
      if not on then table.remove(self.onUpdateFrames, i) end
      return
    end
  end
  if on then table.insert(self.onUpdateFrames, frame) end
end

function Sim:_addTimer(delay, fn, interval, iterations)
  self.timerSeq = self.timerSeq + 1
  local t = { at = self.time + math.max(delay or 0, 0), seq = self.timerSeq, fn = fn,
    interval = interval, remaining = iterations }
  table.insert(self.timers, t)
  return t
end

-- Advance the game clock, running OnUpdate scripts and timers as frames tick.
-- The default frame time is 1/32s: exactly representable in binary, so
-- elapsed times add up without float drift and tests stay deterministic.
function Sim:Advance(seconds, step)
  step = step or self.opts.frameTime or (1 / 32)
  local target = self.time + (seconds or 0)
  local ticked = false
  repeat
    local dt = math.min(step, target - self.time)
    if target - (self.time + dt) < 1e-9 then dt = target - self.time end
    self.time = (dt == target - self.time) and target or (self.time + dt)
    for _, frame in ipairs({ unpack(self.onUpdateFrames) }) do
      if self._isVisible(frame) then self:_runScript(frame, "OnUpdate", dt) end
    end
    require("wowapi.animation").tick(self, dt)
    local due = {}
    for _, t in ipairs(self.timers) do
      if not t.cancelled and t.at <= self.time + 1e-9 then due[#due + 1] = t end
    end
    table.sort(due, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.seq < b.seq end)
    for _, t in ipairs(due) do
      if not t.cancelled then
        if t.interval then
          if t.remaining then t.remaining = t.remaining - 1 end
          if t.remaining and t.remaining <= 0 then t.cancelled = true else t.at = t.at + t.interval end
        else
          t.cancelled = true
        end
        self:_pcall(t.fn, t.handle)
      end
    end
    for i = #self.timers, 1, -1 do if self.timers[i].cancelled then table.remove(self.timers, i) end end
    ticked = true
  until self.time >= target - 1e-12 and ticked
end

function Sim:Now() return self.time end

-------------------------------------------------------------------- addons

function Sim:AddAddonPath(dir) table.insert(self.addonPaths, dir) end

function Sim:_resolveAddon(spec, hintDir)
  if toc.findToc(spec) then return spec end
  local dirs = {}
  if hintDir then dirs[#dirs + 1] = hintDir end
  for _, d in ipairs(self.addonPaths) do dirs[#dirs + 1] = d end
  for _, d in ipairs(dirs) do
    local cand = toc.join(d, spec)
    if toc.findToc(cand) then return cand end
  end
end

function Sim:_runFile(addon, path, ns)
  if path:lower():match("%.xml$") then
    require("wowapi.xml").loadFile(self, path, addon, function(p)
      if not toc.exists(p) then
        self:_error(string.format("%s: file referenced in %s not found: %s", addon.name, path, p))
      else
        self:_runFile(addon, p, ns)
      end
    end)
    return
  end
  local chunk, err = compat.loadfile(path, self.env)
  if not chunk then
    self:_error(err)
    return
  end
  self:_pcall(chunk, addon.name, ns)
end

function Sim:_error(msg)
  table.insert(self.errors, { message = msg, traceback = msg })
  if not self.quiet then io.stderr:write("|cffff0000Lua error|r: " .. msg .. "\n") end
end

local function charKey(p) return p.name .. " - " .. p.realm end

function Sim:_loadSavedFromDisk(addon)
  if not self.savedVariablesDir then return end
  local function read(path, into)
    local chunk = compat.loadfile(path, into)
    if chunk then pcall(chunk) end
  end
  if not self.store.account[addon.name] then
    local vars = {}
    read(toc.join(self.savedVariablesDir, addon.name .. ".lua"), vars)
    self.store.account[addon.name] = vars
  end
  local ck = charKey(self.player)
  self.store.character[ck] = self.store.character[ck] or {}
  if not self.store.character[ck][addon.name] then
    local vars = {}
    read(toc.join(toc.join(self.savedVariablesDir, ck), addon.name .. ".lua"), vars)
    self.store.character[ck][addon.name] = vars
  end
end

-- Load an addon by directory or by name (searched in addon paths).
-- Returns true, addonNamespace or false, reason.
function Sim:LoadAddon(spec, _hintDir)
  local dir = self:_resolveAddon(spec, _hintDir)
  if not dir then return false, "MISSING" end
  local t, err = toc.load(dir)
  if not t then return false, err end
  local existing = self.addons[t.name]
  if existing then return existing.loaded, existing.ns end
  if not t.gameTypeOk then
    self:_warn(string.format("%s: not loaded, its .toc excludes the '%s' game type", t.name, toc.GAME_TYPE))
    return false, "INCOMPATIBLE"
  end
  local addon = { name = t.name, toc = t, dir = dir, ns = {}, loaded = false, loading = true }
  self.addons[t.name] = addon
  table.insert(self.addonOrder, t.name)

  local parent = toc.dirname(dir)
  for _, dep in ipairs(t.deps) do
    local ok = self.addons[dep] and self.addons[dep].loaded or self:LoadAddon(dep, parent)
    if not ok then
      addon.loading = false
      addon.reason = "DEP_MISSING"
      self:_error(string.format("%s: required dependency '%s' is missing or failed to load", t.name, dep))
      return false, "DEP_MISSING"
    end
  end
  for _, dep in ipairs(t.optionalDeps) do
    if not self.addons[dep] and self:_resolveAddon(dep, parent) then self:LoadAddon(dep, parent) end
  end

  local iface = tonumber(t.interface[1] or "")
  if iface and iface ~= self.build.interface then
    local match = false
    for _, i in ipairs(t.interface) do if tonumber(i) == self.build.interface then match = true end end
    if not match then
      self:_warn(string.format("%s: ## Interface: %s does not include %d (would load as out of date)",
        t.name, table.concat(t.interface, ", "), self.build.interface))
    end
  end

  local prev = self.currentAddon
  self.currentAddon = t.name
  for _, f in ipairs(t.files) do
    local path = toc.join(dir, f)
    if not toc.exists(path) then
      self:_error(string.format("%s: file listed in .toc not found: %s", t.name, f))
    else
      self:_runFile(addon, path, addon.ns)
    end
  end
  local bindings = toc.join(dir, "Bindings.xml")
  if toc.exists(bindings) then require("wowapi.xml").loadBindings(self, bindings, addon) end
  self.currentAddon = prev

  -- SavedVariables are applied after the addon's files ran, before ADDON_LOADED.
  self:_loadSavedFromDisk(addon)
  local acct = self.store.account[t.name] or {}
  for _, var in ipairs(t.savedVariables) do
    if acct[var] ~= nil then rawset(self.env, var, serialize.copy(acct[var])) end
  end
  local ck = charKey(self.player)
  local chr = (self.store.character[ck] or {})[t.name] or {}
  for _, var in ipairs(t.savedVariablesPerCharacter) do
    if chr[var] ~= nil then rawset(self.env, var, serialize.copy(chr[var])) end
  end

  addon.loading = false
  addon.loaded = true
  self:FireEvent("ADDON_LOADED", t.name, false)
  return true, addon.ns
end

-- Every addon directory inside `dir`.
function Sim:LoadAllAddons(dir)
  self:AddAddonPath(dir)
  local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
  local names = {}
  if p then for n in p:lines() do names[#names + 1] = n end; p:close() end
  table.sort(names)
  for _, n in ipairs(names) do
    local d = toc.join(dir, n)
    if toc.findToc(d) and not self.addons[n] then
      local t = toc.load(d)
      if t and not t.loadOnDemand then self:LoadAddon(d) end
    end
  end
end

function Sim:GetAddon(name) return self.addons[name] end
function Sim:NS(name) return self.addons[name] and self.addons[name].ns end

-------------------------------------------------------------------- session

function Sim:Login(isReload)
  if self.loggedIn then return end
  self.loggedIn = true
  self:FireEvent("SPELLS_CHANGED")
  self:FireEvent("PLAYER_LOGIN")
  self:FireEvent("PLAYER_ENTERING_WORLD", not isReload, isReload and true or false)
  self:FireEvent("VARIABLES_LOADED")
  self:Advance(0)
end

function Sim:_persist()
  local ck = charKey(self.player)
  self.store.character[ck] = self.store.character[ck] or {}
  for _, name in ipairs(self.addonOrder) do
    local addon = self.addons[name]
    if addon.loaded then
      local acct, chr = {}, {}
      for _, var in ipairs(addon.toc.savedVariables) do
        local ok, v = pcall(serialize.copy, rawget(self.env, var))
        if ok then acct[var] = v else self:_error(name .. ": SavedVariable " .. var .. ": " .. v) end
      end
      for _, var in ipairs(addon.toc.savedVariablesPerCharacter) do
        local ok, v = pcall(serialize.copy, rawget(self.env, var))
        if ok then chr[var] = v else self:_error(name .. ": SavedVariable " .. var .. ": " .. v) end
      end
      self.store.account[name] = acct
      self.store.character[ck][name] = chr
      if self.savedVariablesDir then
        os.execute('mkdir -p "' .. toc.join(self.savedVariablesDir, ck) .. '"')
        if #addon.toc.savedVariables > 0 then
          local f = io.open(toc.join(self.savedVariablesDir, name .. ".lua"), "w")
          if f then f:write(serialize.file(acct)); f:close() end
        end
        if #addon.toc.savedVariablesPerCharacter > 0 then
          local f = io.open(toc.join(toc.join(self.savedVariablesDir, ck), name .. ".lua"), "w")
          if f then f:write(serialize.file(chr)); f:close() end
        end
      end
    end
  end
end

-- Log out: fires the logout events and writes SavedVariables.
function Sim:Logout()
  self:FireEvent("PLAYER_LEAVING_WORLD")
  self:FireEvent("PLAYER_LOGOUT")
  self:_persist()
  self.loggedIn = false
end

-- /reload: save variables, wipe the Lua state, load every addon again, log in.
function Sim:Reload()
  local order = {}
  for _, name in ipairs(self.addonOrder) do
    local a = self.addons[name]
    if a.loaded then order[#order + 1] = a.dir end
  end
  local errors = self.errors
  self:Logout()
  self:_reset()
  self.errors = errors -- errors from before the reload still count
  for _, dir in ipairs(order) do self:LoadAddon(dir) end
  self:Login(true)
end

-------------------------------------------------------------------- input

-- Run a slash command exactly as if typed in the chat box.
function Sim:Slash(text)
  local cmd, msg = text:match("^(/%S+)%s*(.-)%s*$")
  if not cmd then error("Slash: expected a command like '/foo args', got " .. tostring(text), 2) end
  local lower = cmd:lower()
  if lower == "/reload" or lower == "/rl" and not self:_findSlash("/rl") then self:Reload(); return true end
  local handler = self:_findSlash(lower)
  if not handler then
    if lower == "/run" or lower == "/script" then self:Exec(msg); return true end
    if lower == "/dump" then
      local ok, v = self:Exec("return " .. msg)
      if ok then self:_chat("Dump: " .. msg); self:_chat("[1]=" .. tostring(v)) end
      return true
    end
    self:_chat("Type '/help' for a listing of a few commands.", "SYSTEM")
    return false
  end
  self:_pcall(handler, msg, rawget(self.env, "DEFAULT_CHAT_FRAME"))
  self:_afterInput()
  return true
end

-- ReloadUI() called from addon code takes effect once the handler returns.
function Sim:_afterInput()
  if self.reloadRequested then
    self.reloadRequested = false
    self:Reload()
  end
end

function Sim:_findSlash(cmd)
  local list = rawget(self.env, "SlashCmdList")
  if not list then return end
  for key, fn in pairs(list) do
    local i = 1
    while true do
      local alias = rawget(self.env, "SLASH_" .. key .. i)
      if not alias then break end
      if alias:lower() == cmd then return fn end
      i = i + 1
    end
  end
end

-- Run Lua in the game environment (like /run). Returns ok, results...
function Sim:Exec(code)
  local fn, err = compat.loadstring(code, "=(exec)", self.env)
  if not fn then self:_error(err); return false, err end
  return self:_pcall(fn)
end

-- Read a global from the game environment (without counting it as an
-- undefined-global read).
function Sim:Get(name)
  local v = rawget(self.env, name)
  if v == nil and self._lazyGlobal then v = self._lazyGlobal(name) end
  return v
end

local function frameArg(self, frame)
  if type(frame) == "string" then
    local f = self:Get(frame)
    if not f then error("no frame named " .. frame, 3) end
    return f
  end
  return frame
end

-- Click a frame directly (like frame:Click(), ignores what's on top of it).
function Sim:Click(frame, button)
  frame = frameArg(self, frame)
  self.hardwareEvent = true
  if frame.Click then frame:Click(button) else self:_runScript(frame, "OnClick", button or "LeftButton", false) end
  self.hardwareEvent = false
  self:_afterInput()
end

-- Move the cursor to screen coordinates (origin bottom-left, 1920x1080),
-- firing OnLeave/OnEnter as the frame under the mouse changes.
function Sim:MoveMouse(x, y)
  self.cursorX, self.cursorY = x, y
  local top = layout.framesAt(self, x, y)[1]
  if top ~= self.mouseFocus then
    local old = self.mouseFocus
    self.mouseFocus = top
    if old then self:_runScript(old, "OnLeave", true) end
    if top then self:_runScript(top, "OnEnter", true) end
  end
  return top
end

-- Frame under the cursor (or under x, y).
function Sim:FrameAt(x, y)
  return layout.framesAt(self, x or self.cursorX or 0, y or self.cursorY or 0)[1]
end

local function center(self, frame)
  local l, b, w, h = layout.rect(self, frame)
  if not l then error("frame has no position (no SetPoint?)", 3) end
  return l + w / 2, b + h / 2
end

-- Move the mouse over a frame (to its center) - fires OnEnter.
function Sim:Hover(frame)
  frame = frameArg(self, frame)
  local l = layout.rect(self, frame)
  if l and frame:IsVisible() then
    self:MoveMouse(center(self, frame))
    if self.mouseFocus ~= frame then
      -- covered by another frame or not mouse-enabled: deliver anyway like a direct call
      self.mouseFocus = frame
      self:_runScript(frame, "OnEnter", true)
    end
  else
    self.mouseFocus = frame
    self:_runScript(frame, "OnEnter", true)
  end
end

function Sim:Leave(frame)
  frame = frameArg(self, frame)
  if self.mouseFocus == frame then self.mouseFocus = nil end
  self:_runScript(frame, "OnLeave", true)
end

local function clickRegistered(self, frame, button, up)
  local s = self.widgetState[frame]
  local list = s.clicks or { "LeftButtonUp" }
  local want = button .. (up and "Up" or "Down")
  for _, c in ipairs(list) do
    if c == want or c == "AnyUp" and up or c == "AnyDown" and not up then return true end
  end
  return false
end

-- A real mouse click at screen coordinates (or on a frame's center): goes to
-- whatever frame is on top there, with OnMouseDown/OnMouseUp/OnClick in order.
function Sim:ClickAt(x, y, button)
  if type(x) == "table" or type(x) == "string" then
    button = y
    x, y = center(self, frameArg(self, x))
  end
  button = button or "LeftButton"
  local target = self:MoveMouse(x, y)
  if not target then return nil end
  self:_runScript(target, "OnMouseDown", button)
  local s = self.widgetState[target]
  if target:IsObjectType("EditBox") then target:SetFocus() end
  if target:IsObjectType("Button") and s.enabled ~= false and clickRegistered(self, target, button, true) then
    self.hardwareEvent = true
    target:Click(button, false)
    self.hardwareEvent = false
  end
  if self.widgetState[target] then self:_runScript(target, "OnMouseUp", button, true) end
  self:_afterInput()
  return target
end

-- Drag a frame by (dx, dy) with the mouse: OnMouseDown, OnDragStart (if
-- registered), movement while StartMoving/StartSizing is active,
-- OnDragStop, OnMouseUp.
function Sim:Drag(frame, dx, dy, button)
  frame = frameArg(self, frame)
  button = button or "LeftButton"
  local s = self.widgetState[frame]
  local x, y = center(self, frame)
  self:MoveMouse(x, y)
  self:_runScript(frame, "OnMouseDown", button)
  local canDrag = false
  for _, b in ipairs(s.dragButtons or {}) do if b == button or b == "Any" then canDrag = true end end
  if canDrag then self:_runScript(frame, "OnDragStart", button) end
  if s.moving or s.sizing then
    local l, b, w, h = layout.rect(self, frame)
    local es = layout.effectiveScale(self.widgetState, frame)
    if s.moving then
      s.points = { { "TOPLEFT", self.env.UIParent, "BOTTOMLEFT", (l + dx) / es, (b + h + dy) / es } }
    else
      local nw, nh = math.max(0, w + dx) / es, math.max(0, h - dy) / es
      local bounds = s.resizeBounds
      if bounds then
        nw = math.max(bounds[1] or 0, bounds[3] and bounds[3] > 0 and math.min(bounds[3], nw) or nw)
        nh = math.max(bounds[2] or 0, bounds[4] and bounds[4] > 0 and math.min(bounds[4], nh) or nh)
      end
      s.points = { { "TOPLEFT", self.env.UIParent, "BOTTOMLEFT", l / es, (b + h) / es } }
      s.width, s.height = nw, nh
      self:_runScript(frame, "OnSizeChanged", nw, nh)
    end
  end
  self.cursorX, self.cursorY = x + dx, y + dy
  if canDrag then self:_runScript(frame, "OnDragStop", button) end
  self:_runScript(frame, "OnMouseUp", button, true)
  self:_afterInput()
end

-- Mouse wheel over a frame (delta 1 = up, -1 = down).
function Sim:Scroll(frame, delta)
  frame = frameArg(self, frame)
  local s = self.widgetState[frame]
  if not (s.mouseWheel or (s.props and s.props.MouseWheelEnabled and s.props.MouseWheelEnabled[1])) then return false end
  self:_runScript(frame, "OnMouseWheel", delta or 1)
  return true
end

-------------------------------------------------------------------- screenshot

-- Render what's on screen to SVG. With a path, writes the file.
--   sim:Screenshot("ui.svg", { outlines = true })
function Sim:Screenshot(path, opts)
  local svg = render.svg(self, opts)
  if path then
    local f = assert(io.open(path, "w"))
    f:write(svg)
    f:close()
  end
  return svg
end

function Sim:Type(editBox, text)
  local s = self.widgetState[editBox]
  s.text = s.text .. text
  self:_runScript(editBox, "OnTextChanged", true)
end

function Sim:PressEnter(editBox) self:_runScript(editBox, "OnEnterPressed") end
function Sim:PressEscape(editBox) self:_runScript(editBox, "OnEscapePressed") end

-------------------------------------------------------------------- mocks & call log

local function resolvePath(env, key)
  local ns, fname = key:match("^([^.]+)%.(.+)$")
  if ns then return rawget(env, ns), fname end
  return env, key
end

-- Replace what a game API function returns. `impl` is a function, or the
-- value(s) to return. Works for documented and hand-written functions.
--   sim:Mock("C_Map.GetBestMapForUnit", 2112)
--   sim:Mock("UnitHealth", function(unit) return unit == "target" and 50 or 100 end)
function Sim:Mock(key, impl, ...)
  local fn = impl
  if type(impl) ~= "function" then
    local vals = { n = select("#", ...) + 1, impl, ... }
    fn = function() return unpack(vals, 1, vals.n) end
  end
  if self.apiDocs and self.apiDocs.functions[key] then
    self.mocks[key] = fn
  else
    local holder, name = resolvePath(self.env, key)
    if not holder then holder = {}; rawset(self.env, key:match("^([^.]+)"), holder) end
    self.unmock = self.unmock or {}
    if self.unmock[key] == nil then self.unmock[key] = { holder, name, rawget(holder, name) } end
    rawset(holder, name, fn)
  end
end

function Sim:Unmock(key)
  self.mocks[key] = nil
  local u = self.unmock and self.unmock[key]
  if u then rawset(u[1], u[2], u[3]); self.unmock[key] = nil end
end

-- Calls made to a documented API function: list of argument tables.
function Sim:Calls(key)
  local c = self.apiCalls[key]
  return c and c.log or {}
end

function Sim:CallCount(key)
  local c = self.apiCalls[key]
  return c and c.n or 0
end

-- Signature of a documented function or widget method, for reference:
--   sim:Doc("C_Timer.After") / sim:Doc("Frame:SetPoint")
function Sim:Doc(key)
  local d = self.apiDocs
  local typ, method = key:match("^(%w+):(%w+)$")
  local doc
  if typ then doc = docs.methodsFor(typ)[method] else doc = d.functions[key] end
  if not doc then return nil end
  local function list(t)
    local o = {}
    for _, a in ipairs(t) do o[#o + 1] = a[1] .. ": " .. a[2] .. (a[3] and "?" or "") end
    return table.concat(o, ", ")
  end
  local s = key .. "(" .. list(doc.a) .. ")"
  if #doc.r > 0 then s = s .. " -> " .. list(doc.r) end
  return s, doc
end

-------------------------------------------------------------------- world state

function Sim:SetUnit(unit, data)
  if data == nil then self.units[unit] = nil; return end
  local u = {}
  for k, v in pairs(DEFAULT_PLAYER) do u[k] = v end
  u.guid = "Creature-0-0-0-0-" .. unit
  for k, v in pairs(data) do u[k] = v end
  self.units[unit] = u
  return u
end

function Sim:SetTarget(data)
  self:SetUnit("target", data)
  self:FireEvent("PLAYER_TARGET_CHANGED")
end

-- Enter combat. PLAYER_REGEN_DISABLED fires while InCombatLockdown() is
-- still false (the last chance to touch protected frames); lockdown starts
-- right after, like in game.
function Sim:EnterCombat()
  if self.inCombat then return end
  self.inCombat = true
  self:FireEvent("PLAYER_REGEN_DISABLED")
  self.lockdown = true
  require("wowapi.secrets").update(self)
  require("wowapi.secure").evaluateDrivers(self)
end

function Sim:LeaveCombat()
  if not self.inCombat then return end
  self.lockdown = false
  self.inCombat = false
  require("wowapi.secrets").update(self)
  self:FireEvent("PLAYER_REGEN_ENABLED")
  require("wowapi.secure").evaluateDrivers(self)
end

-- Force secret-value restrictions on/off (nil = follow combat). Needs
-- WoW.new({ secretValues = true }).
function Sim:SetSecretRestrictions(on)
  self.forcedSecretRestrictions = on
  require("wowapi.secrets").update(self)
end

-- Actions addons were stopped from doing (ADDON_ACTION_BLOCKED/FORBIDDEN).
function Sim:BlockedActions() return self.blockedActions end

function Sim:AddItem(id, info)
  info.id = id
  info.name = info.name or ("Item " .. id)
  info.quality = info.quality or 1
  info.link = info.link or string.format("|cffffffff|Hitem:%d::::::::60:::::|h[%s]|h|r", id, info.name)
  self.items[id] = info
  self.items[info.name] = info
end

function Sim:AddSpell(id, info)
  info.id = id
  info.name = info.name or ("Spell " .. id)
  self.spells[id] = info
  self.spells[info.name] = info
end

-------------------------------------------------------------------- chat

local function stripCodes(s)
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  s = s:gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("||", "|")
  return s
end
Sim.StripCodes = stripCodes

function Sim:_chat(msg, channel)
  table.insert(self.chat, { raw = msg, text = stripCodes(msg), channel = channel or "SYSTEM" })
  if self.onChat then self.onChat(msg, channel) end
end

-- All chat-frame output, color codes stripped, joined with newlines.
function Sim:ChatText()
  local out = {}
  for _, c in ipairs(self.chat) do out[#out + 1] = c.text end
  return table.concat(out, "\n")
end

-- Does any chat line match `pattern`? plain=true for substring match.
function Sim:ChatContains(pattern, plain)
  for _, c in ipairs(self.chat) do
    if c.text:find(pattern, 1, plain) then return true end
  end
  return false
end

function Sim:LastChat() local c = self.chat[#self.chat]; return c and c.text end
function Sim:ClearChat() self.chat = {} end

-------------------------------------------------------------------- reports

function Sim:ClearErrors() self.errors = {} end

function Sim:AssertNoErrors()
  if #self.errors > 0 then
    local lines = {}
    for _, e in ipairs(self.errors) do lines[#lines + 1] = e.traceback end
    error(#self.errors .. " Lua error(s) in addon code:\n" .. table.concat(lines, "\n\n"), 2)
  end
end

-- Globals written while an addon's files were loading (excludes
-- SavedVariables, slash command aliases and named frames).
function Sim:LeakedGlobals(addonName)
  local out = {}
  local addon = self.addons[addonName]
  local allowed = {}
  if addon then
    for _, v in ipairs(addon.toc.savedVariables) do allowed[v] = true end
    for _, v in ipairs(addon.toc.savedVariablesPerCharacter) do allowed[v] = true end
  end
  for k, owner in pairs(self.createdGlobals) do
    if owner == addonName and not allowed[k] and not k:match("^SLASH_") and not k:match("^BINDING_")
      and not self.widgetState[rawget(self.env, k)] and k ~= addonName then
      out[#out + 1] = k
    end
  end
  table.sort(out)
  return out
end

function Sim:Report()
  local out = {}
  local function add(s) out[#out + 1] = s end
  for _, name in ipairs(self.addonOrder) do
    local a = self.addons[name]
    add(string.format("Addon %-24s %s", name, a.loaded and "loaded" or ("NOT LOADED (" .. tostring(a.reason) .. ")")))
    local leaks = self:LeakedGlobals(name)
    if #leaks > 0 then add("  leaked globals: " .. table.concat(leaks, ", ")) end
  end
  add(string.format("Frames created: %d, events fired: %d", self.frameCount, #self.firedEvents))
  if #self.warnings > 0 then
    add("Warnings:")
    for _, w in ipairs(self.warnings) do add("  - " .. w) end
  end
  local stubs = {}
  for k, n in pairs(self.stubbedCalls) do stubs[#stubs + 1] = string.format("%s (x%d)", k, n) end
  table.sort(stubs)
  if #stubs > 0 then add("Called but only stubbed (no visual effect here): " .. table.concat(stubs, ", ")) end
  local undef = {}
  local saved = {}
  for _, a in pairs(self.addons) do
    for _, v in ipairs(a.toc.savedVariables) do saved[v] = true end
    for _, v in ipairs(a.toc.savedVariablesPerCharacter) do saved[v] = true end
  end
  for k in pairs(self.undefinedGlobals) do
    -- ignore names that are defined by now (read-before-write) and SavedVariables
    if not k:match("^__") and rawget(self.env, k) == nil and not saved[k] then undef[#undef + 1] = k end
  end
  table.sort(undef)
  if #undef > 0 then
    add("Globals read but not defined (not emulated, or a typo?): " .. table.concat(undef, ", "))
  end
  if #(self.blockedActions or {}) > 0 then
    add("Blocked by the client's security (ADDON_ACTION_BLOCKED/FORBIDDEN):")
    for _, b in ipairs(self.blockedActions) do add(string.format("  - [%s] %s: %s", b.kind, b.addon, b.action)) end
  end
  -- missing embedded libraries usually means the addon wasn't packaged
  for _, name in ipairs(self.addonOrder) do
    local a = self.addons[name]
    local missingLib = false
    for _, e in ipairs(self.errors) do
      if e.message:find(a.dir, 1, true) and e.message:lower():find("/libs?/") and
        (e.message:find("cannot open") or e.message:find("not found")) then missingLib = true end
    end
    if missingLib then
      local pkg = toc.exists(toc.join(a.dir, ".pkgmeta"))
      add(string.format("Hint: %s is missing embedded libraries%s. Test the packaged addon (the zip from CurseForge/Wago/GitHub releases) or install them into its Libs folder.",
        name, pkg and " (its .pkgmeta lists them as externals fetched at packaging time)" or ""))
    end
  end
  if #self.errors == 0 then
    add("Lua errors: none")
  else
    add(string.format("Lua errors: %d", #self.errors))
    for i, e in ipairs(self.errors) do add(string.format("  [%d] %s", i, e.traceback)) end
  end
  return table.concat(out, "\n")
end

for k, v in pairs(require("wowapi.input").SimMethods) do Sim[k] = v end
for k, v in pairs(require("wowapi.framexml").SimMethods) do Sim[k] = v end

return Sim
