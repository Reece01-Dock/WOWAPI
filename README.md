# WOWAPI: a WoW: Forever client simulator for addon development

Write, test and debug **World of Warcraft: Forever** addons without launching the game.

`wowapi` is a WoW client emulator written in plain Lua 5.1, the same Lua the game runs. It loads your addon from its
`.toc` exactly like the client and runs it against a simulated game. The simulation covers:

- the whole documented API
- frames with real layout, drawn to screenshots
- XML UI
- events, timers and animations
- mouse, keyboard and key bindings
- combat lockdown and secure frames
- SavedVariables and `/reload`

Use it to:

- **Unit-test your addon** (`./wowtest test`): click buttons, type slash commands, enter combat, advance time,
  reload the UI, and assert on the result.
- **Smoke-test any addon** (`./wowtest check`): get a report of Lua errors, blocked actions, leaked globals and
  API calls that aren't emulated, plus an optional screenshot.
- **Play with it interactively** (`./wowtest run`): a terminal "client" where you type `/commands`, press keys,
  click, drag, fire events and take screenshots.

## Target client

| | |
|---|---|
| Client | WoW: Forever, **Interface `16001`**, mainline (12.x) UI and API |
| Game type | **`camelot`**: `.toc` lines with `[AllowLoadGameType camelot]` load, `[ExcludeLoadGameType …]` is honoured, retail-only `standard` lines don't load |
| API data | Generated from Blizzard's own API documentation (`wow-ui-source` 12.1.0) and [BlizzardInterfaceResources](https://github.com/Ketho/BlizzardInterfaceResources) |
| Removed legacy globals | `GetAddOnMetadata`, `GetSpellInfo`, `GetItemInfo`, `UnitAura` and similar are **absent**, like on the live 12.x client. Pass `--legacy` / `{ legacyGlobals = true }` to add them back |

## Requirements

Lua 5.1 or LuaJIT. Nothing else.

```sh
sudo apt install lua5.1      # Debian/Ubuntu
brew install lua@5.1         # macOS (or: brew install luajit)
```

## Quick start

```sh
./wowtest test                                 # run every *_spec.lua under addons/ and spec/
./wowtest new MyAddon                          # scaffold addons/MyAddon with a .toc, code and a test
./wowtest test addons/MyAddon                  # run one addon's tests
./wowtest check path/to/AddOns/SomeAddon --screenshot ui.svg
./wowtest run addons/HelloForever --name Thrall --class SHAMAN
```

`addons/HelloForever` is a complete example addon with tests: events, SavedVariables, slash commands, a UI window,
`OnUpdate`, `C_Timer`, tooltips and combat. `spec/fixtures/XmlAddon` shows an XML-based UI with mixins, templates,
animations and `Bindings.xml`.

## Writing tests

Put `*_spec.lua` files anywhere inside your addon folder. The runner walks up from each spec file to find the addon's
`.toc`.

```lua
describe("MyAddon", function()
  local sim
  before_each(function()
    sim = Boot({ player = { name = "Jaina", class = "MAGE", level = 60 } })  -- load addon + log in
  end)

  it("greets on login", function()
    expect(sim:ChatContains("Hello, Jaina", true)).to_be(true)
  end)

  it("saves settings across /reload", function()
    sim:Slash("/myaddon toggle")
    sim:Reload()
    expect(sim:Get("MyAddonDB").enabled).to_be(false)
  end)

  it("has a working window", function()
    local win = sim:Get("MyAddonFrame")
    sim:Drag(win, 100, 0)                 -- real drag: OnDragStart, StartMoving, re-anchoring
    sim:ClickAt(win.CloseButton)          -- real click at the button's position
    expect(win:IsShown()).to_be(false)
    sim:Screenshot("window.svg")          -- look at it in a browser
  end)

  it("doesn't touch protected frames in combat", function()
    sim:EnterCombat()
    sim:Slash("/myaddon move")
    expect(#sim:BlockedActions()).to_be(0)
  end)
end)
```

**If your addon raises a Lua error at any point during a test, that test fails**, even when the error happened inside
an event handler (in game it would only show up in the error frame). If a test expects an error, call
`sim:ClearErrors()` before the test ends.

**Spec globals**
- `describe`, `it`, `pending`, `before_each`, `after_each`
- `expect(v)` with `.to_be`, `.to_equal` (deep), `.to_be_truthy`, `.to_be_falsy`, `.to_be_nil`, `.to_be_type`,
  `.to_contain`, `.to_match`, `.to_have_length`, `.to_be_greater_than`, `.to_be_less_than`, `.to_be_close_to` and
  `.to_error`. Put `.never` before any of them to negate it.
- `Boot(opts)`: a new client with this addon loaded and logged in.
- `NewSim(opts)`: a new client with nothing loaded. It can still find this addon and its sibling folders, which
  is how dependencies get resolved.
- `WoW`: the module itself.
- `ADDON_DIR` and `SPEC_DIR`: paths.

## The simulated client (`sim`)

`WoW.new(opts)` accepts these options:

- `player = { name, realm, class, race, faction, level, health, healthMax, power, powerMax, money, guild, zone, spec, auras = {...}, ... }`
- `locale` (default `"enUS"`)
- `items = { [id] = {...} }` and `spells = { [id] = {...} }`
- `seed`, for `math.random`
- `savedVariablesDir`: read and write real WTF files
- `frameTime` (default 1/32 s)
- `legacyGlobals`
- `strictArgs` (default true): API argument checking
- `secretValues`
- `projectId`: the value of `WOW_PROJECT_ID`
- `extraEvents`
- `quiet`

| Area | Methods |
|---|---|
| Addons & session | `LoadAddon(dirOrName)` → `ok, ns` · `LoadAllAddons(dir)` · `Login()` · `Logout()` · `Reload()` · `NS(name)` |
| Events & time | `FireEvent(event, ...)` · `EventCount(event)` · `Advance(seconds)` (runs `OnUpdate`, timers, animations) |
| Chat & commands | `Slash("/cmd args")` (plus built-in `/reload`, `/run`, `/dump`) · `ChatContains(pattern, plain)` · `LastChat()` · `ChatText()` · `ClearChat()` |
| Mouse | `MoveMouse(x, y)` (fires OnEnter/OnLeave) · `ClickAt(x, y or frame, button)` (hits whatever is on top and respects `RegisterForClicks`) · `Click(frame)` · `Hover(frame)` · `Leave(frame)` · `Drag(frame, dx, dy)` · `Scroll(frame, delta)` · `FrameAt(x, y)` |
| Keyboard | `PressKey("CTRL-SHIFT-F")`: the full client input chain (focused EditBox, keyboard-enabled frames, ESC closing `UISpecialFrames`, override and normal bindings) · `TypeText(text)` · `SetModifier("shift", true)` · `SetBinding(key, action)` · `Type(editBox, text)` · `PressEnter(eb)` |
| Combat & security | `EnterCombat()` / `LeaveCombat()` (lockdown starts after `PLAYER_REGEN_DISABLED`, like the client) · `BlockedActions()` · `secureActions` (what secure buttons cast or used) · `SetSecretRestrictions(on)` |
| World | `SetTarget(data)` · `SetUnit("party1", data)` · `AddItem(id, info)` · `AddSpell(id, info)` · `bags[bag][slot] = {...}` · `CombatLog("SPELL_DAMAGE", { source = "player", dest = "target", spellId = 133, amount = 1200 })` |
| Menus | `MenuItems()` · `ChooseMenuItem(text)`, for MenuUtil context menus and `WowStyle1DropdownTemplate` dropdowns |
| API | `Mock("C_Map.GetBestMapForUnit", 2112)` · `Mock("UnitHealth", fn)` · `Unmock(key)` · `Calls(key)` · `CallCount(key)` · `Doc("Frame:SetPoint")` (the documented signature) |
| Inspection | `Get(name)` · `Exec(lua)` · `Screenshot(path, { outlines = true })` · `LeakedGlobals(addon)` · `Report()` · `errors` · `ClearErrors()` · `AssertNoErrors()` · `sentChat` · `addonMessages` · `sounds` · `popups` · `uiErrors` |

Screen coordinates are UIParent's 1920×1080, with the origin at the bottom-left, as in the client.

## What's simulated

**The API**

- All **4,871 documented functions** in 12.1, and every **event, enum, structure and widget method** (79 widget
  API tables). Calls are argument-checked against the documentation, like the client. Registering an event
  that doesn't exist errors, and a typo in a method name is `nil`.
- Commonly used functions have real behaviour: units, auras, items, spells, bags, map, addons, CVars, chat, timers,
  colors, `Settings`, `EventRegistry`/`EventUtil`, popups and more.
- Everything else returns typed "empty game" defaults (`0`, `""`, `false`, `{}`, or a filled-in structure) and can
  be mocked.
- All **6,682 global functions** and **4,888 FrameXML functions** the live client defines exist. The ones that aren't
  emulated are recorded no-ops, listed by `check` under "stubbed".
- Also included: the full `Enum` and `Constants` tables, `LE_*` constants, CVar defaults, **all 24,665 GlobalStrings**
  (`TANK`, `ERR_*` and so on), every Blizzard template and font object, and placeholders for Blizzard's named
  frames, including action buttons.
- FrameXML utilities: `Mixin`, `CreateFramePool` and the other pools, `CallbackRegistryMixin`, `Item`/`Spell`
  mixins, `MenuUtil`, `PixelUtil`, `SecondsToTime` and similar, `BackdropTemplateMixin` (as in retail,
  `SetBackdrop` needs `BackdropTemplate`), and the combat log.

**Frames and rendering**

- Real layout: anchors, `SetAllPoints`, sizes, scale, and FontString and tooltip auto-sizing. `GetLeft`/`GetRect`
  and the rest are correct, and anchor loops error.
- Strata and frame levels for hit-testing and draw order.
- `sim:Screenshot()` renders the visible UI to SVG: backdrops, color textures, status bars, sliders, edit boxes,
  buttons, checkboxes, tooltips, text with `|c` colors, and optional frame outlines. Game art files can't ship
  here, so file textures render as labelled placeholders.

**XML**

- Every frame type: `<Layers>`, `<Frames>`, `<Anchors>` (`relativeTo`, `relativeKey`), `<Size>`, `<Scripts>` (inline,
  `function=`, `method=`, `inherit=prepend/append`), `<KeyValues>`, `<Attributes>`, `<Animations>`, and button,
  slider, status bar and edit box specifics.
- Virtual templates, intrinsics, `mixin`/`secureMixin`, `parentKey`/`parentArray`, `$parent` names and `<Font>`
  objects.
- `OnLoad` runs children first, like the client. XML templates also work with `CreateFrame`.
- `Bindings.xml` is loaded.

**Animations**: `AnimationGroup` with Alpha, Translation, Scale, Rotation, VertexColor and FlipBook. Supports order,
delays, smoothing, looping (`REPEAT`/`BOUNCE`), `SetToFinalAlpha`, and the OnPlay/OnFinished/OnLoop scripts.

**Security**

- Addon calls to protected functions (`CastSpellByName`, `TargetUnit` and so on) are forbidden, and
  `ADDON_ACTION_FORBIDDEN` fires.
- Protected frames (secure templates) can't be shown, moved or re-attributed by addon code in combat, and
  `ADDON_ACTION_BLOCKED` fires. The report says which addon did it.
- `SecureActionButtonTemplate` performs its spell, item, macro, target, click or attribute actions on real clicks and
  key bindings, even in combat, but not from `button:Click()` in addon code.
- Macro conditionals (`SecureCmdOptionParse`), `RegisterStateDriver`/`RegisterAttributeDriver`/`RegisterUnitWatch`,
  and SecureHandler snippets (`_onstate-*`, `_onclick`, `_onshow`, `SetFrameRef`, `WrapScript`) run in a restricted
  environment.
- **Secret values** (opt-in, `secretValues = true`): in combat, API returns flagged secret by the documentation
  become opaque values. Widgets can display them, but arithmetic, comparison and concatenation error.

**SavedVariables**: account and per-character, written like the client's WTF files. They survive `/reload` and can
be read and written on disk.

## Limits

- **Game data**: there's no server. Units, items, spells, auras and bags are what your test sets up. Functions that
  aren't emulated return empty defaults (or mock them).
- **Art**: file textures and models aren't drawn, only their placement and tint. Text metrics are an approximation of
  the game font.
- **Unconfirmed Forever details**: WoW: Forever's `WOW_PROJECT_ID` isn't published, so it defaults to
  `WOW_PROJECT_MAINLINE` (override with `projectId`). Whether Forever enables 12.x secret-value restrictions is also
  unknown, so they're opt-in.
- **Blizzard UI**: Blizzard's own UI (action bars, unit frames and so on) exists as placeholders, not as working
  Blizzard code.

## Tested against real addons

- The **Ace3** library suite loads with no errors.
- **BugSack** (which ships a `[AllowLoadGameType camelot]` Forever file) loads apart from libraries its git repo
  doesn't contain.
- **OmniCC** initialises and loads its on-demand config addon.
- **Details!**, around 1,700 frames, loads and reports only genuine Forever incompatibilities in its own code.

Addons installed from git usually lack their embedded libraries. `check` points this out, so test the packaged
release.

## Layout

```
wowtest               CLI: test / check / run / new
wowapi/
  init.lua            WoW.new(opts)
  sim.lua             the simulated client: addons, events, time, input, SavedVariables, reports
  api.lua             hand-written game API (units, chat, timers, colors, settings, ...)
  docs.lua            documented API: auto functions, arg checks, mocks, widget method sets
  resources.lua       GlobalStrings, constants, CVars, stubs, templates, fonts, named frames
  widgets.lua         CreateFrame and the widget hierarchy
  layout.lua          anchor/size resolution, hit-testing
  render.lua          SVG screenshots
  xml.lua             FrameXML parser/loader, Bindings.xml
  templates.lua       built-in Blizzard templates
  animation.lua       AnimationGroups
  secure.lua          combat lockdown, protected calls, secure buttons, state drivers, snippets
  secrets.lua         12.x secret values
  input.lua           keyboard and key bindings
  framexml.lua        pools, callback registry, menus, mixins, combat log, ...
  toc.lua             .toc parsing, game-type conditions
  serialize.lua       SavedVariables writer
  testing.lua         describe/it/expect runner
  data/               generated API data (see tools/)
tools/
  update-apidocs.sh   regenerate data/apidocs.lua from Blizzard's API docs
  update-resources.sh regenerate data/resources.lua + GlobalStrings (add locales: deDE frFR ...)
addons/HelloForever   example addon + tests
spec/                 tests for the simulator itself
```

When a new client build ships, run `tools/update-apidocs.sh` and `tools/update-resources.sh` to pick up the new API.

CI (`.github/workflows/test.yml`) runs every spec under Lua 5.1 and LuaJIT, smoke-tests each addon in `addons/`,
and uploads their screenshots.
