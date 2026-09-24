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
- **See it**: screenshots are drawn with **the real game art**, downloaded on demand, in a **fake but believable
  world** of generated items, spells, NPCs, party members, gear and bags.

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
./wowtest check path/to/AddOns/SomeAddon --screenshot ui.png   # with real game textures
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

## Game art

Screenshots use the real WoW textures: icons, borders, buttons, checkboxes, sliders, status bars, tooltips, atlases,
the cursor and, where available, the game font. They're downloaded the first time they're needed into
`.wowtest/cache/` (git-ignored). **No game files are stored in this repository.**

```sh
./wowtest check addons/HelloForever --screenshot ui.png     # PNG needs Chrome/Chromium (or WOWAPI_BROWSER)
./wowtest check addons/HelloForever --screenshot ui.svg     # SVG opens in any browser
```

```lua
local sim = WoW.new({ art = true })        -- or pass { art = true } to one screenshot
sim:Screenshot("ui.png", { outlines = true, background = "Interface\\Glues\\LoadingScreens\\LoadScreen_KulTiras-Tiragarde_wide" })
```

Where the art comes from, in order:

1. **Your own folder** (`--art-dir <dir>`, `artDir = ...` or `$WOWAPI_ART`): extracted UI textures as PNG, matched
   case-insensitively. For example, a checkout of Gethe/wow-ui-textures or your own BLP export.
2. **[Gethe/wow-ui-textures](https://github.com/Gethe/wow-ui-textures)**: the game's UI textures as PNG. It's indexed
   with a metadata-only git clone, and files are fetched one at a time.
3. **[wago.tools](https://wago.tools)**: the game's own `.blp` file by fileDataID, for anything else, including the
   newest atlases. `wowapi/blp.lua` (a pure-Lua BLP2 decoder: DXT1/3/5, palettized, BGRA) and `wowapi/png.lua`
   convert it to PNG locally.
4. **Wowhead's icon CDN**: a last fallback for icons.

Textures given by fileDataID are resolved with the shipped icon index (`wowapi/data/icons.txt`, 33,819 icons) and,
for other textures, the [community listfile](https://github.com/wowdev/wow-listfile), downloaded once. Atlases
(`SetAtlas`, `C_Texture.GetAtlasInfo`, `useAtlasSize`) use the shipped `wowapi/data/atlases.txt` (17,471 atlases).

The renderer handles:

- texture coordinates, including flipped and 8-value coordinates
- `SetVertexColor` tint, desaturation, `ADD` blending and rotation
- horizontal and vertical tiling
- classic 9-slice backdrops (`BackdropTemplate`)
- button states, including highlight on hover
- status-bar fill with the bar texture

Other switches:

- `--offline` / `offline = true`: only cached or local art is used.
- `--no-art`: placeholders, with no downloads. This is the default inside tests.

## Fake game data

There's no server, so the simulator makes up a consistent world. Anything the server would send is generated from a
seed, so the same item ID is always the same item, on every machine and every run.

- **Items**: any item ID becomes a complete item: a name like "Stormforged Saber of the Boar", quality, item
  level, class, subclass and equip slot, stack size, sell price, a quality-colored link, and a matching real icon.
  Real classics are built in, like Hearthstone (6948) and Thunderfury (19019).
- **Spells**: real class spells are built in (Fireball 133, Frostbolt 116, Flash Heal 2061, Charge 100 and more).
  Any other ID becomes a named spell with a school-appropriate real icon, cast time, range and cooldown.
- **Your character**:
  - Real class data: power type, specs with real spec IDs and roles, and `IsPlayerSpell` for your class.
  - A guild, a zone and bags (a Hearthstone, food, drink and loot).
  - Equipped gear, with `GetInventoryItemLink` and `GetAverageItemLevel`.
  - Stats, crit, haste, mastery and armor.
  - Action bars filled with your class's spells.
- **Documented functions nobody hand-wrote** return plausible values picked from each field's name and type (names,
  IDs, icons, counts, percentages, timestamps, valid enum values, filled-in structures and lists) instead of empty
  ones.

World helpers:

| | |
|---|---|
| `sim:SpawnParty(4)` / `sim:SpawnRaid(20)` | Generated group members with classes, roles and names (`GetRaidRosterInfo` works) |
| `sim:SpawnEnemy({ boss = true })` | A hostile NPC as your target (and `boss1`) |
| `sim:AddAura("player", 774, { duration = 12 })` / `RemoveAura` | Auras with `UNIT_AURA` update info |
| `sim:Cast(133)` / `sim:Cast("Blink")` | `UNIT_SPELLCAST_*` events over the cast time, the combat log, cooldowns, `UnitCastingInfo` |
| `sim:SetHealth("target", 0)` | `UNIT_HEALTH` (and `UNIT_DIED` in the combat log) |
| `sim:SetAction(1, "spell", 133)` · `sim:AddMacro(name, body)` · `sim:Equipment()` | Action bars, macros, gear |

`sim:AddItem`, `sim:AddSpell`, `player = {...}` and `sim:Mock(...)` always win over generated data.
`fakeData = false` (or `--no-fake`) goes back to empty "no server" values.

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

## Notes

- **Forever details that aren't published**: WoW: Forever's `WOW_PROJECT_ID` defaults to `WOW_PROJECT_MAINLINE`
  (override with `projectId`), and 12.x secret-value restrictions are opt-in (`secretValues = true`).
- **Game data is invented**, apart from the real facts built in: classes, specs, races, zones, and a set of real
  spells and items. For exact values, register real data with `sim:AddItem`, `sim:AddSpell` or `sim:Mock`.
- **Blizzard's own UI** exists as placeholder frames, not as working Blizzard code. The main action bar, micro
  menu and Settings window (with addon categories and vertical-layout controls) are drawn.
- **Art downloads** need `git` and `curl`, and use POSIX shell tools. On Windows, use WSL or Git Bash.

## Tested against real addons

`wowtest install` fetches addons from GitHub and packages them the way the CurseForge/Wago packager does:
`.pkgmeta` externals, `move-folders`, git submodules, and `@debug@` / `do-not-package` stripping. Then `check` or a
script can drive them:

```sh
./wowtest install BigWigsMods/BigWigs tullamods/OmniCC Jaliborc/Bagnon Jaliborc/BagBrother
./wowtest check .wowtest/AddOns/OmniCC --screenshot omnicc.png
```

Results from a run of 13 popular addons (a scripted scenario for each, then a screenshot):

| Addon | Result |
|---|---|
| OmniCC | Runs cleanly: cooldown text on the action bar. |
| AdvancedInterfaceOptions | Runs cleanly: its AceConfig pages open in the Settings window. |
| BigWigs | Core, plugins and options load on demand; `/bw` opens the full options window. |
| Bagnon (+ BagBrother) | Loads its whole library stack (Poncho, Sushi, WildAddon, C_Everywhere); 2 errors left. |
| Details!, DBM, Hekili, Bartender4 | Load. Remaining errors are mostly libraries only on wowace/CurseForge, which this sandbox couldn't reach (`install` fetches them over svn/http elsewhere), plus missing CurseForge-injected translations. |
| Kui Nameplates | **Genuinely incompatible with Forever**: it checks `select(4, GetBuildInfo()) >= 90000`, which is false at interface 16001, so it registers the removed `UNIT_HEALTH_FREQUENT` event and its login handler fails. |
| Dominos | Its `.toc` has no 16001 interface and no `[Game]` = Camelot bar-state file, so on Forever you get the default bar. |
| WeakAuras | Only ships Classic-flavor `.toc` files, so it isn't loaded (`INCOMPATIBLE`). |

## Signed releases and the compatibility index

**Signed releases** protect players from tampered downloads (fake mirrors, re-uploads with injected code). They are
not DRM: the addon stays plain, readable Lua, as Blizzard's add-on policy requires, and anyone can still read and
fork it. Signing uses Ed25519 through the `openssl` command-line tool.

```sh
./wowtest keygen                        # once: ~/.config/wowtest/keys/author.key (secret) + author.pub (publish it)
./wowtest sign path/to/MyAddon          # writes wowtest.manifest + wowtest.sig; commit them with the release
./wowtest verify path/to/MyAddon        # anyone: do the files match what the author signed?
```

- **What's signed:** `sign` signs every committed file (in a git checkout; otherwise every file) with its SHA-256. It
  warns about uncommitted files, because a player's fresh clone won't have them.
- **What fails verification:** a changed or missing file, an edited manifest, or an added `.lua`/`.xml`/`.toc` file.
  Extra non-code files are reported but allowed.
- **Checks on install:** `wowtest install` verifies the source before it fetches libraries or packages anything. It
  refuses a bad signature.
- **Remembered keys:** the first valid key for an addon name goes into `.wowtest/trusted-keys.txt`. After that,
  installing that addon signed with a different key fails with `KEY CHANGED`. Delete its line to accept a new key.
- **Pinning:** `--pubkey author.pub` pins an exact key, and `--require-signed` rejects unsigned addons.
- **Not covered:** libraries fetched while packaging (`.pkgmeta` externals) come from their own sources, so the
  author's signature doesn't cover them.

The **compatibility index** runs every installed addon through the simulator: load, log in, and play for a few
seconds. It then writes `.wowtest/index/index.json` and a searchable `index.html` with a badge per addon:

```sh
./wowtest install BigWigsMods/BigWigs tullamods/OmniCC ...
./wowtest index                         # or: ./wowtest index path/to/AddOns --out site/
```

Each addon gets one of: *Runs cleanly*, *Runs with errors*, *Missing libraries*, *Incompatible* (with the reason,
e.g. its `.toc` only allows another game type), or *Hangs*. Errors raised in other addons it loads are listed
separately, and Forever-specific hints point out things like a `.toc` without interface 16001 or a removed event.
Each addon is checked in its own process with a timeout (`--timeout 120`).

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
  render.lua          screenshots (SVG/PNG) with real game art
  assets.lua          game-art resolution + on-demand download cache
  blp.lua / png.lua   BLP2 texture decoder, PNG encoder
  faker.lua           generated items, spells, characters, NPCs, API values
  fakeapi.lua         gear, stats, action bars, instances... from the fake world
  xml.lua             FrameXML parser/loader, Bindings.xml
  templates.lua       built-in Blizzard templates
  animation.lua       AnimationGroups
  secure.lua          combat lockdown, protected calls, secure buttons, state drivers, snippets
  secrets.lua         12.x secret values
  input.lua           keyboard and key bindings
  framexml.lua        pools, callback registry, menus, mixins, combat log, ...
  installer.lua       `wowtest install`: GitHub fetch + CurseForge-style packaging
  signing.lua         signed releases: manifests, Ed25519 signatures, trusted keys
  index.lua           compatibility index (JSON + HTML)
  settingspanel.lua   the Settings window (Settings.OpenToCategory)
  toc.lua             .toc parsing, game-type conditions
  serialize.lua       SavedVariables writer
  testing.lua         describe/it/expect runner
  data/               generated API data (see tools/)
tools/
  update-apidocs.sh   regenerate data/apidocs.lua from Blizzard's API docs
  update-resources.sh regenerate data/resources.lua + GlobalStrings (add locales: deDE frFR ...)
  update-art-data.sh  regenerate data/icons.txt + data/atlases.txt
addons/HelloForever   example addon + tests
spec/                 tests for the simulator itself
```

When a new client build ships, run the three `tools/update-*.sh` scripts to pick up the new API and art indexes.

CI (`.github/workflows/test.yml`) runs every spec under Lua 5.1 and LuaJIT, smoke-tests each addon in `addons/`,
and uploads their screenshots.
