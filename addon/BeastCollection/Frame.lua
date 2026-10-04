-- The Beast Collection window: chrome, tabs along the bottom and a status line. Each tab file
-- adds its panel with BC.AddTab. Drag it by the title bar; it remembers where it was put
-- (/beasts reset puts it back).

local BC = BeastCollection

local WIDTH, HEIGHT = 820, 520

local frame = CreateFrame("Frame", "BeastCollectionFrame", UIParent)
frame:SetSize(WIDTH, HEIGHT)
frame:EnableMouse(true)
frame:SetToplevel(true)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:SetFrameStrata("HIGH")
frame:Hide()
BC.frame = frame
-- Escape closes it, like any panel.
table.insert(UISpecialFrames, "BeastCollectionFrame")

local function placeFrame()
	frame:ClearAllPoints()
	local p = BeastCollectionDB and BeastCollectionDB.position
	if p then
		frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	end
end

local dragon = BC.DressWindow(frame)

local title = frame.chrome:CreateFontString(nil, "OVERLAY", "GameFontNormal")
if frame.headerPlate then
	title:SetPoint("TOP", frame.headerPlate, "TOP", 0, -14)
else
	title:SetPoint("TOP", frame, "TOP", 0, -5)
end
title:SetText("Beast Collection")

-- The title bar is the drag handle.
local dragBar = CreateFrame("Frame", nil, frame)
dragBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, dragon and 0 or 12)
dragBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, 0)
dragBar:SetHeight(dragon and 24 or 36)
dragBar:EnableMouse(true)
dragBar:RegisterForDrag("LeftButton")
dragBar:SetScript("OnDragStart", function () frame:StartMoving() end)
dragBar:SetScript("OnDragStop", function ()
	frame:StopMovingOrSizing()
	local point, _, relativePoint, x, y = frame:GetPoint(1)
	BeastCollectionDB.position = { point, relativePoint, x, y }
end)

local close = CreateFrame("Button", "BeastCollectionFrameCloseButton", frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", dragon and 2 or -4, dragon and 2 or -4)
do
	local _, CP = BC.Dragon()
	if CP and CP.ModernizeCloseButton then
		CP.ModernizeCloseButton(close, frame.chrome, 1, 0)
		close:SetFrameLevel(frame.chrome:GetFrameLevel() + 5)
	end
end

-- Content area shared by every tab.
local content = CreateFrame("Frame", nil, frame)
content:SetPoint("TOPLEFT", frame, "TOPLEFT", dragon and 12 or 16, dragon and -28 or -32)
content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", dragon and -12 or -16, 34)
BC.content = content

-----------------------------------------
-- bottom bar: dex progress on the left, status on the right

local progress = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
progress:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, dragon and 13 or 17)

local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, dragon and 13 or 17)
status:SetWidth(420)
status:SetJustifyH("RIGHT")

local statusToken = 0
-- A line of feedback at the bottom of the window; errors in red.
function BC.Status(text, isError)
	statusToken = statusToken + 1
	local mine = statusToken
	status:SetText(text or "")
	if isError then status:SetTextColor(1, 0.25, 0.25) else status:SetTextColor(1, 0.82, 0) end
	BC.After(8, function () if mine == statusToken then status:SetText("") end end)
end

local function updateProgress()
	if not BC.catalogReady or not BC.server then
		progress:SetText("")
		return
	end
	local normal, shiny = BC.Counts()
	local text = string.format("Beast-dex: |cffffffff%d|r / %d", normal, BC.server.normalTotal)
	if BC.server.shinyTotal > 0 then
		text = text .. string.format("   %s Shiny: |cffffffff%d|r / %d", BC.SHINY_STAR, shiny, BC.server.shinyTotal)
	end
	progress:SetText(text)
end
BC.On("DEX", updateProgress)
BC.On("CATALOG", updateProgress)

BC.On("ERR", function (command, reason)
	BC.Status(BC.ErrorText(reason), true)
end)

-----------------------------------------
-- tabs

local panels, tabs = {}, {}

function BC.SelectTab(index)
	PanelTemplates_SetTab(frame, index)
	for i, panel in ipairs(panels) do
		if i == index then panel:Show() else panel:Hide() end
	end
	BC.currentTab = index
	BC.Fire("TAB", index)
end

function BC.AddTab(name)
	local index = #panels + 1
	local panel = CreateFrame("Frame", nil, content)
	panel:SetAllPoints(content)
	panel:Hide()
	panels[index] = panel

	local tab = BC.CreateTab(frame, index, name, BC.SelectTab)
	if index == 1 then
		tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 11, dragon and 2 or 4)
	else
		tab:SetPoint("TOPLEFT", tabs[index - 1], "TOPRIGHT", dragon and 1 or -15, 0)
	end
	tabs[index] = tab
	PanelTemplates_SetNumTabs(frame, index)
	return panel, index
end

-----------------------------------------

frame:SetScript("OnShow", function ()
	PlaySound("igCharacterInfoOpen")
	placeFrame()
	status:SetText("")
	updateProgress()
	BC.SelectTab(BC.currentTab or 1)
	BC.Refresh()
end)

frame:SetScript("OnHide", function ()
	PlaySound("igCharacterInfoClose")
	StaticPopup_Hide("BEASTCOLLECTION_CONFIRM")
end)

-----------------------------------------
-- one confirmation dialog

StaticPopupDialogs["BEASTCOLLECTION_CONFIRM"] = {
	text = "%s",
	button1 = ACCEPT,
	button2 = CANCEL,
	OnAccept = function (self, data) if data then data() end end,
	timeout = 0,
	exclusive = 1,
	hideOnEscape = 1,
	showAlert = 1,
}

function BC.Confirm(text, onAccept)
	local dialog = StaticPopup_Show("BEASTCOLLECTION_CONFIRM", text)
	if dialog then dialog.data = onAccept end
end

-----------------------------------------
-- a way in from the stable master's window

local stableButton
local function addStableButton()
	if stableButton or not PetStableFrame then return end
	stableButton = BC.CreateButton(PetStableFrame, "Beast Collection", 130, 22)
	-- Outside the window, on its right edge, where nothing of the stock frame sits.
	stableButton:SetPoint("TOPLEFT", PetStableFrame, "TOPRIGHT", -34, -76)
	stableButton:SetScript("OnClick", function () frame:Show() end)
end

local hook = CreateFrame("Frame")
hook:RegisterEvent("PET_STABLE_SHOW")
hook:SetScript("OnEvent", addStableButton)
