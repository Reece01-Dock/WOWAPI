local addonName, ns = ...

-- A small movable window showing health, with a button and a session timer.
function ns.CreateUI()
  if ns.frame then return end

  local f = CreateFrame("Frame", "HelloForeverFrame", UIParent, "BackdropTemplate")
  f:SetSize(220, 90)
  f:SetPoint("CENTER")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOP", 0, -8)
  f.title:SetText(C_AddOns.GetAddOnMetadata(addonName, "Title"))

  f.health = CreateFrame("StatusBar", nil, f)
  f.health:SetSize(200, 14)
  f.health:SetPoint("TOP", 0, -28)
  f.health:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.health:SetStatusBarColor(0, 1, 0)

  f.timer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.timer:SetPoint("BOTTOMLEFT", 10, 10)

  f.button = CreateFrame("Button", "HelloForeverWaveButton", f, "UIPanelButtonTemplate")
  f.button:SetSize(80, 22)
  f.button:SetPoint("BOTTOMRIGHT", -8, 6)
  f.button:SetText("Wave")
  f.button:SetScript("OnClick", function()
    SendChatMessage("waves hello from WoW: Forever!", "EMOTE")
  end)
  f.button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Wave")
    GameTooltip:AddLine("Sends a friendly emote.", 1, 1, 1)
    GameTooltip:Show()
  end)
  f.button:SetScript("OnLeave", GameTooltip_Hide)

  function ns.UpdateHealth()
    local hp, max = UnitHealth("player"), UnitHealthMax("player")
    f.health:SetMinMaxValues(0, max)
    f.health:SetValue(hp)
  end

  f:RegisterUnitEvent("UNIT_HEALTH", "player")
  f:SetScript("OnEvent", ns.UpdateHealth)

  local elapsedTotal, throttle = 0, 0
  f:SetScript("OnUpdate", function(self, elapsed)
    elapsedTotal = elapsedTotal + elapsed
    throttle = throttle + elapsed
    if throttle >= 1 then
      throttle = 0
      self.timer:SetFormattedText("Session: %ds", elapsedTotal)
    end
  end)

  ns.frame = f
  ns.UpdateHealth()
  f:SetShown(ns.db.showFrame)
end
