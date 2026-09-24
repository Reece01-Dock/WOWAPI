local addonName, ns = ...
local L = ns.L

local defaults = { greet = true, showFrame = true }

local events = CreateFrame("Frame")
ns.events = events

local handlers = {}

function handlers.ADDON_LOADED(name)
  if name ~= addonName then return end
  HelloForeverDB = HelloForeverDB or {}
  for k, v in pairs(defaults) do
    if HelloForeverDB[k] == nil then HelloForeverDB[k] = v end
  end
  HelloForeverCharDB = HelloForeverCharDB or { logins = 0 }
  ns.db, ns.char = HelloForeverDB, HelloForeverCharDB
  events:UnregisterEvent("ADDON_LOADED")
end

function handlers.PLAYER_LOGIN()
  ns.char.logins = ns.char.logins + 1
  if ns.db.greet then
    local name = UnitName("player")
    local _, class = UnitClass("player")
    local color = RAID_CLASS_COLORS[class]
    print(L.GREETING:format(color:WrapTextInColorCode(name)))
    print(L.LOGIN_COUNT:format(ns.char.logins))
  end
  if ns.CreateUI then ns.CreateUI() end
end

function handlers.PLAYER_REGEN_DISABLED()
  ns.combatStart = GetTime()
  print(L.COMBAT_START)
end

function handlers.PLAYER_REGEN_ENABLED()
  if ns.combatStart then
    print(L.COMBAT_END:format(GetTime() - ns.combatStart))
    ns.combatStart = nil
  end
end

events:SetScript("OnEvent", function(self, event, ...)
  handlers[event](...)
end)
for event in pairs(handlers) do events:RegisterEvent(event) end

-- /hf remind <seconds> <text>
function ns.Remind(seconds, text)
  C_Timer.After(seconds, function()
    print("Reminder: " .. text)
    PlaySound(SOUNDKIT.RAID_WARNING)
  end)
end

SLASH_HELLOFOREVER1 = "/hf"
SLASH_HELLOFOREVER2 = "/helloforever"
SlashCmdList.HELLOFOREVER = function(msg)
  local cmd, rest = strsplit(" ", strtrim(msg or ""), 2)
  cmd = (cmd or ""):lower()
  if cmd == "show" then
    ns.frame:Show()
    ns.db.showFrame = true
  elseif cmd == "hide" then
    ns.frame:Hide()
    ns.db.showFrame = false
  elseif cmd == "count" then
    print(L.LOGIN_COUNT:format(ns.char.logins))
  elseif cmd == "greet" then
    ns.db.greet = (rest == "on")
    print("Greeting " .. (ns.db.greet and "enabled" or "disabled"))
  elseif cmd == "remind" then
    local seconds, text = strsplit(" ", rest or "", 2)
    seconds = tonumber(seconds)
    if not seconds or not text then print(L.USAGE) return end
    ns.Remind(seconds, text)
    print(("I'll remind you in %d seconds."):format(seconds))
  else
    print(L.USAGE)
  end
end
