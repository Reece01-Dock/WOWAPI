local addonName, ns = ...
XmlAddonLoadOrder = {}

XmlPanelMixin = {}
function XmlPanelMixin:OnLoad()
  table.insert(XmlAddonLoadOrder, self:GetName())
  self.Title:SetText(self.titleText)
  self:RegisterEvent("PLAYER_LOGIN")
end
function XmlPanelMixin:OnEvent(event)
  self.gotLogin = (event == "PLAYER_LOGIN")
end

XmlRowMixin = {}
function XmlRowMixin:OnLoad()
  table.insert(XmlAddonLoadOrder, self:GetDebugName())
end
function XmlRowMixin:OnClick(button)
  XmlAddonClicked = self:GetID()
end
