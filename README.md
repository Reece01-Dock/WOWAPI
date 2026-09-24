# WOWAPI: test harness for WoW: Forever addons

Write and test **World of Warcraft: Forever** addons without launching the game.

`wowapi` is a small WoW client emulator written in plain Lua 5.1, the same Lua version the game uses. It loads
your addon from its `.toc` file and runs your Lua against a fake copy of the game API: frames, events, timers, slash
commands, SavedVariables, units and chat. That lets you:

- **Write unit tests** for your addon (`./wowtest test`)
- **Smoke-test** any addon folder and get a report of Lua errors, missing API calls and leaked globals (`./wowtest check`)
- **Try your addon interactively**: type `/commands`, fire events, click buttons and `/reload` in a terminal (`./wowtest run`)

It targets WoW: Forever's client: **Interface `16001`** on the mainline (12.x) API. That means `C_AddOns`,
`C_Timer`, `C_Spell`, `C_Item`, `C_UnitAuras`, `Settings`, `EventUtil` and similar. Legacy globals removed from the
mainline client (`GetAddOnMetadata`, `GetSpellInfo` and others) are deliberately **left out**, so an addon that uses
them fails here the same way it would in game. Pass `--legacy` or `{ legacyGlobals = true }` if you still want them.

## Requirements

Lua 5.1 or LuaJIT. Nothing else.

```sh
sudo apt install lua5.1      # Debian/Ubuntu
brew install lua@5.1         # macOS (or: brew install luajit)
```

## Quick start

```sh
./wowtest test                          # run every *_spec.lua under addons/ and spec/
./wowtest new MyAddon                   # scaffold addons/MyAddon with a .toc, code and a test
./wowtest test addons/MyAddon           # run that addon's tests
./wowtest check addons/MyAddon          # load + login + try every slash command, then report
./wowtest run addons/HelloForever --name Thrall --class SHAMAN   # interactive session
```

`addons/HelloForever` is a complete example. It has events, SavedVariables, slash commands, a UI window, `OnUpdate`,
`C_Timer`, tooltips and combat detection, and its spec in `addons/HelloForever/tests/` tests all of it.

## Writing tests

Put `*_spec.lua` files anywhere inside your addon folder (for example `MyAddon/tests/MyAddon_spec.lua`). The runner
finds the addon's `.toc` by walking up from the spec file.

```lua
describe("MyAddon", function()
  local sim

  before_each(function()
    sim = Boot({ player = { name = "Jaina", class = "MAGE", level = 60 } })
    -- Boot() = new simulated client + load this addon (and its deps) + log in
  end)

  it("greets on login", function()
    expect(sim:ChatContains("Hello, Jaina", true)).to_be(true)
  end)

  it("saves settings across /reload", function()
    sim:Slash("/myaddon toggle")
    sim:Reload()
    expect(sim:Get("MyAddonDB").enabled).to_be(false)
  end)

  it("reminds after 10 seconds", function()
    sim:Slash("/myaddon remind 10 drink")
    sim:Advance(10)                      -- runs OnUpdate + C_Timer
    expect(sim:LastChat()).to_be("Reminder: drink")
  end)
end)
```

**If your addon raises a Lua error at any point during a test, that test fails**, even when the error happened inside
an event handler (in game it would only show up in the error frame). If a test expects an error, call
`sim:ClearErrors()` before the test ends.

### Spec globals

| Name | What it is |
|---|---|
| `describe`, `it`, `pending`, `before_each`, `after_each` | Test structure |
| `expect(v)` | `.to_be`, `.to_equal` (deep), `.to_be_truthy`, `.to_be_falsy`, `.to_be_nil`, `.to_be_type`, `.to_contain`, `.to_match`, `.to_have_length`, `.to_be_greater_than`, `.to_be_less_than`, `.to_be_close_to`, `.to_error`. Put `.never` before any of these to negate it. |
| `Boot(opts)` | New client with this addon loaded and logged in |
| `NewSim(opts)` | New client, nothing loaded yet (can find this addon and its sibling folders) |
| `WoW` | The `wowapi` module (`WoW.new(opts)`, `WoW.toc`, `WoW.serialize`) |
| `ADDON_DIR`, `SPEC_DIR` | Paths |

### The simulated client (`sim`)

**Setup**: `WoW.new(opts)` accepts these options:
`player = { name, realm, class, race, faction, level, health, healthMax, power, powerMax, money, guild, zone, spec, auras = {...} }`,
`locale = "enUS"`, `items = { [id] = {name=, quality=, ...} }`, `spells = { [id] = {name=, ...} }`, `seed` (for
`math.random`), `legacyGlobals`, `savedVariablesDir` (read/write real WTF files), `frameTime` (default 1/32s), `quiet`.

| Method | Does |
|---|---|
| `sim:LoadAddon(dirOrName)` | Load an addon: dependencies, files, XML `<Script>`s, SavedVariables, then `ADDON_LOADED`. Returns `ok, ns`, where `ns` is the addon's private table (`local _, ns = ...`) |
| `sim:Login()` / `sim:Logout()` / `sim:Reload()` | Login events, logout (writes SavedVariables), full `/reload` with a fresh Lua state |
| `sim:FireEvent(event, ...)` | Fire a game event (`RegisterUnitEvent` filters are respected) |
| `sim:Advance(seconds)` | Move game time forward. `OnUpdate` scripts run on visible frames and timers fire |
| `sim:Slash("/cmd args")` | Type a slash command (`/reload`, `/run`, `/dump` are built in) |
| `sim:Click(frameOrName, button)`, `sim:Hover(f)`, `sim:Leave(f)` | Mouse input |
| `sim:Type(editBox, text)`, `sim:PressEnter(eb)`, `sim:PressEscape(eb)` | Keyboard input |
| `sim:EnterCombat()` / `sim:LeaveCombat()` | Combat events + `InCombatLockdown()` |
| `sim:SetTarget(data)`, `sim:SetUnit("party1", data)` | Other units |
| `sim:AddItem(id, info)`, `sim:AddSpell(id, info)`; `sim.bags[bag][slot] = { itemID=, stackCount= }` | Game data |
| `sim:Get(name)` | Read a global from the game environment |
| `sim:Exec(luaCode)` | Run Lua inside the game. Returns `ok, results...` |
| `sim:NS(addonName)` | An addon's private namespace table |
| `sim:ChatContains(pattern, plain)`, `sim:LastChat()`, `sim:ChatText()`, `sim:ClearChat()` | What the addon printed (color codes stripped) |
| `sim.sentChat`, `sim.addonMessages`, `sim.sounds`, `sim.popups`, `sim.uiErrors` | Things the addon sent or showed |
| `sim.errors`, `sim:ClearErrors()`, `sim:AssertNoErrors()` | Captured Lua errors |
| `sim:LeakedGlobals(addon)` | Globals your addon created by accident (forgot `local`) |
| `sim:Report()` | Summary of errors, warnings, stubbed calls and undefined globals |

## What's emulated

- **Lua**: WoW's Lua 5.1 sandbox without `io`, `os` or `require`. It adds `strsplit`/`strjoin`/`strtrim` with WoW's
  semantics, `tinsert`, `wipe`, `tContains`, `CopyTable`, `bit`, and degree-based `sin`/`cos`, plus `date`, `time`,
  `GetTime` and `debugprofilestop` on a deterministic clock.
- **Frames**: `CreateFrame` for Frame, Button, CheckButton, StatusBar, Slider, EditBox, ScrollFrame, Cooldown,
  GameTooltip and (Scrolling)MessageFrame, plus FontStrings, Textures and `CreateFont`. Behaviour covered: show/hide
  with `OnShow`/`OnHide`, parent visibility, points and sizes, `SetScript`/`HookScript`, events, values, text and
  checked state. Common templates add their child regions (`UICheckButtonTemplate.Text`, `UIPanelButtonTemplate`,
  `OptionsSliderTemplate`, `BasicFrameTemplate`, ...).
- **Events**: ordered dispatch, `RegisterUnitEvent`, `RegisterAllEvents`, `EventRegistry`, `EventUtil`.
  - Login order: `ADDON_LOADED` (per addon), then `SPELLS_CHANGED`, `PLAYER_LOGIN`,
    `PLAYER_ENTERING_WORLD(isInitialLogin, isReload)` and `VARIABLES_LOADED`.
  - Logout order: `PLAYER_LEAVING_WORLD`, then `PLAYER_LOGOUT`.
- **Time**: `C_Timer.After`, `NewTimer` and `NewTicker` (all cancellable), and `OnUpdate`.
- **Addons**: `.toc` metadata, `Dependencies`/`OptionalDeps`, `[AllowLoadGameType]`, `Name_Forever.toc`/`_Mainline`
  flavor files, `C_AddOns.*`, and SavedVariables (account and per-character) that survive `/reload` and can be
  written to disk.
- **Game state**: units, class colors, money, items, spells, auras, bags, map position, combat, group, CVars,
  `StaticPopup`, chat filters, addon messages, the `Settings` panel API and `AddonCompartmentFrame`.

**Not emulated**: rendering and layout math, XML frame definitions (the `<Script file>` and `<Include file>` tags
inside XML are followed, and XML frames produce a warning), secure/protected action restrictions, and real game data.
A real WoW widget method that has no behaviour here is a recorded no-op. `check` lists these calls under "stubbed" so
you know which parts still need an in-game check. A method name that doesn't exist in WoW is `nil`, so typos fail here
the same way they fail in game.

If your addon needs an API that isn't here, `./wowtest check` lists it under *"Globals read but not defined"*. Add it in
`wowapi/api.lua`.

## Layout

```
wowtest              CLI (test / check / run / new)
wowapi/
  init.lua           module entry: WoW.new(opts)
  sim.lua            the simulated client: addons, events, time, input, SavedVariables, reports
  api.lua            global game API (units, C_* namespaces, chat, timers, colors, settings, ...)
  widgets.lua        CreateFrame and the widget hierarchy
  toc.lua            .toc / XML parsing
  serialize.lua      SavedVariables (WTF) writer
  testing.lua        describe/it/expect runner
  compat.lua         Lua 5.1 / LuaJIT / 5.2+ shims, pure-Lua `bit`
addons/HelloForever  example addon + tests
spec/                tests for the emulator itself
```

CI (`.github/workflows/test.yml`) runs every spec and smoke-tests every addon under Lua 5.1 and LuaJIT on each push.
