local addonName, ns = ...

-- A small window: progress while probing, then a summary and what to do next.

local frame

local function line(parent, anchor, font, gap)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
  fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or 6))
  fs:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
  fs:SetJustifyH("LEFT")
  return fs
end

local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

local function summary(r)
  local c = r.client or {}
  local rows = {
    string.format("Client: %s (build %s), interface |cffffffff%s|r", tostring(c.version), tostring(c.build), tostring(c.interface)),
    string.format("Game type: |cffffffff%s|r   [Game]: |cffffffff%s|r   [Family]: |cffffffff%s|r",
      #(c.gameTypes or {}) > 0 and table.concat(c.gameTypes, ", ") or "unknown", tostring(c.game or "?"), tostring(c.family or "?")),
    string.format("WOW_PROJECT_ID: |cffffffff%s|r   expansion: %s", tostring(c.projectId), tostring(c.expansion)),
    string.format("Blizzard globals: %d   namespaces: %d   enums: %d", count(r.globals), count(r.namespaces), count(r.enums)),
  }
  if r.events then
    rows[#rows + 1] = string.format("Events: %d of %d the simulator knows are valid here", r.events.valid, r.events.checked)
  end
  local errs = count(r.errors)
  if errs > 0 then rows[#rows + 1] = string.format("|cffff6060%d probe(s) failed|r (recorded for the report)", errs) end
  return table.concat(rows, "\n")
end

local function build()
  frame = CreateFrame("Frame", "SimCheckFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(460, 300)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetFrameStrata("DIALOG")
  frame.TitleText:SetText("SimCheck - simulator calibration")
  tinsert(UISpecialFrames, "SimCheckFrame")

  local intro = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  intro:SetPoint("TOPLEFT", 16, -34)
  intro:SetPoint("RIGHT", -16, 0)
  intro:SetJustifyH("LEFT")
  intro:SetText("Records how this client behaves (API, events, layout, text) so the wowtest simulator "
    .. "can be compared with the real game. Nothing about your character or settings is recorded.")

  frame.status = line(frame, intro, "GameFontNormal", 12)

  local bar = CreateFrame("StatusBar", nil, frame)
  bar:SetPoint("TOPLEFT", frame.status, "BOTTOMLEFT", 0, -8)
  bar:SetPoint("RIGHT", -16, 0)
  bar:SetHeight(14)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(0.2, 0.7, 1)
  bar:SetMinMaxValues(0, 1)
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.5)
  frame.bar = bar

  frame.summary = line(frame, bar, "GameFontHighlightSmall", 10)
  frame.next = line(frame, frame.summary, "GameFontDisableSmall", 10)

  local run = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  run:SetSize(120, 22)
  run:SetPoint("BOTTOMRIGHT", -12, 12)
  run:SetText("Run again")
  run:SetScript("OnClick", function() ns.Run() end)
  frame.runButton = run

  local reload = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  reload:SetSize(140, 22)
  reload:SetPoint("RIGHT", run, "LEFT", -8, 0)
  reload:SetText("Save (/reload)")
  reload:SetScript("OnClick", function() ReloadUI() end)
  frame.reloadButton = reload
end

local function refresh()
  if not frame then return end
  local st = ns.state
  local r = SimCheckDB and SimCheckDB.result
  if st.running then
    frame.status:SetText("Probing: " .. tostring(st.current or "..."))
    frame.bar:SetValue((st.index - 1) / #ns.probes)
    frame.summary:SetText("")
    frame.next:SetText("")
  elseif st.waiting then
    frame.status:SetText("Waiting for login to settle, then probing...")
    frame.bar:SetValue(0)
  elseif r then
    frame.status:SetText(st.done and "Done. |cffffd200Click Save (or log out) to write the results.|r"
      or "Last results (" .. tostring(r.meta and r.meta.finished) .. " UTC)")
    frame.bar:SetValue(1)
    frame.summary:SetText(summary(r))
    frame.next:SetText("Then on your computer:\n  wowtest compare <WoW folder>/.../WTF/Account/<ACCOUNT>/SavedVariables/SimCheck.lua")
  else
    frame.status:SetText("Not run yet.")
    frame.bar:SetValue(0)
  end
end

function ns.OnProgress() refresh() end
function ns.OnFinished() if frame and frame:IsShown() then refresh() end end

function ns.ShowWindow()
  if not frame then build() end
  frame:Show()
  refresh()
end

function ns.ToggleWindow()
  if frame and frame:IsShown() then frame:Hide() else ns.ShowWindow() end
end
