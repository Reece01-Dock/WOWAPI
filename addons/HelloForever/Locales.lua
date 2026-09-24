local _, ns = ...

local L = {
  GREETING = "Hello, %s! Welcome to WoW: Forever.",
  LOGIN_COUNT = "You have logged in %d time(s) on this character.",
  COMBAT_START = "Entering combat!",
  COMBAT_END = "Combat lasted %.1f seconds.",
  USAGE = "Usage: /hf [show | hide | count | greet <on|off> | remind <seconds> <text>]",
}

if GetLocale() == "deDE" then
  L.GREETING = "Hallo, %s! Willkommen in WoW: Forever."
end

ns.L = L
