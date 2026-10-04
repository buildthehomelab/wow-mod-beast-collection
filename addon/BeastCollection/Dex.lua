-- The Beast-dex tab: every look a hunter can tame, by family, with what the account has tamed.
-- Untamed looks show as a silhouette, with where to find them.

local BC = BeastCollection

local panel = BC.AddTab("Beast-dex")

local FILTER_ALL, FILTER_SHINY = -1, -2
local familyFilter = FILTER_ALL
local search = ""
local missingOnly = false
local selectedDisplay

local function isShiny(look)
	return BC.Has(look.flags, BC.LOOK_SHINY)
end

local function lookName(look)
	if isShiny(look) then return "Shiny " .. look.name end
	return look.name
end

-----------------------------------------
-- left: families

local familyPane = BC.CreateInset(panel)
familyPane:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
familyPane:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
familyPane:SetWidth(196)

local familyList = BC.CreateList(familyPane, {
	rows = 20,
	rowHeight = 20,
	columns = {
		{ title = "Family", icon = function (item) return item.icon end,
		  text = function (item) return item.label end },
		{ title = "", width = 58, align = "RIGHT", text = function (item) return item.progress end },
	},
	isSelected = function (item) return item.id == familyFilter end,
	onClick = function (item)
		familyFilter = item.id
		BC.Fire("DEX_FILTER")
	end,
})
familyList:SetPoint("TOPLEFT", familyPane, "TOPLEFT", 6, -6)
familyList:SetPoint("RIGHT", familyPane, "RIGHT", -4, 0)

local function progressText(have, total)
	if total > 0 and have >= total then
		return string.format("|cff40ff40%d/%d|r", have, total)
	end
	return string.format("%d/%d", have, total)
end

local function refreshFamilies()
	local items = {}
	local normal, shiny, byFamily = BC.Counts()
	if BC.server then
		table.insert(items, { id = FILTER_ALL, label = "|cffffd100All beasts|r", icon = "Interface\\Icons\\Ability_Hunter_BeastTaming",
			progress = progressText(normal, BC.server.normalTotal), order = 1 })
		if BC.server.shinyTotal > 0 then
			table.insert(items, { id = FILTER_SHINY, label = "|cffff80ffShiny|r", icon = "Interface\\Icons\\INV_Misc_Gem_Pearl_04",
				progress = progressText(shiny, BC.server.shinyTotal), order = 2 })
		end
	end
	for i, family in ipairs(BC.familyList) do
		local label = family.name
		if family.exotic then label = label .. " |cffff8040*|r" end
		table.insert(items, { id = family.id, label = label, icon = BC.FamilyIcon(family.id),
			progress = progressText(byFamily[family.id] or 0, family.normal), order = 2 + i })
	end
	familyList:SetItems(items, true)
end

-----------------------------------------
-- middle: the looks

local searchBox = BC.CreateEditBox(panel, 160)
searchBox:SetPoint("TOPLEFT", familyPane, "TOPRIGHT", 14, -6)
local searchLabel = BC.CreateLabel(panel, "Search", "GameFontDisableSmall")
searchLabel:SetPoint("LEFT", searchBox, "LEFT", 4, 0)

local missingCheck = BC.CreateCheck(panel, "Not tamed yet")
missingCheck:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)

local lookPane = BC.CreateInset(panel)
lookPane:SetPoint("TOPLEFT", familyPane, "TOPRIGHT", 6, -30)
lookPane:SetPoint("BOTTOMLEFT", familyPane, "BOTTOMRIGHT", 6, 0)
lookPane:SetWidth(330)

local lookList = BC.CreateList(lookPane, {
	rows = 19,
	rowHeight = 20,
	columns = {
		{ title = NAME,
		  icon = function (look)
			if BC.owned[look.display] then return "Interface\\RaidFrame\\ReadyCheck-Ready" end
			return BC.FamilyIcon(look.family)
		  end,
		  desaturate = function (look) return not BC.owned[look.display] end,
		  text = function (look)
			local name = lookName(look)
			if isShiny(look) then name = name .. " " .. BC.SHINY_STAR end
			if BC.owned[look.display] then return "|cffffffff" .. name .. "|r" end
			return "|cff909090" .. name .. "|r"
		  end,
		  sort = function (look) return string.lower(lookName(look)) end },
		{ title = LEVEL_ABBR or "Lvl", width = 50, align = "CENTER",
		  text = function (look) return BC.LevelRange(look.minLevel, look.maxLevel) end,
		  sort = function (look) return look.minLevel end },
		{ title = ZONE or "Zone", width = 110,
		  text = function (look) return (string.gsub(look.zones or "", "/", ", ")) end,
		  sort = function (look) return look.zones end },
	},
	defaultSort = 2,
	empty = "Nothing here.",
	isSelected = function (look) return look.display == selectedDisplay end,
	onClick = function (look)
		selectedDisplay = look.display
		BC.Fire("LOOK_SELECTED")
	end,
	tooltip = function (look, tip)
		tip:AddLine(lookName(look))
		tip:AddLine(BC.FamilyName(look.family) .. ", level " .. BC.LevelRange(look.minLevel, look.maxLevel), 1, 1, 1)
		if look.zones ~= "" then tip:AddLine((string.gsub(look.zones, "/", ", ")), 0.7, 0.7, 0.7) end
		if BC.owned[look.display] then tip:AddLine("Tamed", 0.25, 1, 0.25) else tip:AddLine("Not tamed yet", 0.6, 0.6, 0.6) end
	end,
})
lookList:SetPoint("TOPLEFT", lookPane, "TOPLEFT", 6, -6)
lookList:SetPoint("RIGHT", lookPane, "RIGHT", -4, 0)

local loading = BC.CreateLabel(lookPane, "Asking the server for the beast list...", "GameFontDisable")
loading:SetPoint("CENTER", lookPane, "CENTER", 0, 0)

local function refreshLooks()
	if not BC.catalogReady then
		loading:Show()
		lookList:SetItems({})
		return
	end
	loading:Hide()
	local items = {}
	for _, look in ipairs(BC.lookList) do
		local show
		if familyFilter == FILTER_ALL then
			show = not isShiny(look)
		elseif familyFilter == FILTER_SHINY then
			show = isShiny(look)
		else
			show = look.family == familyFilter
		end
		if show and missingOnly and BC.owned[look.display] then show = false end
		if show and search ~= "" then
			local hay = string.lower(lookName(look) .. " " .. (look.zones or "") .. " " .. BC.FamilyName(look.family))
			show = string.find(hay, search, 1, true) ~= nil
		end
		if show then table.insert(items, look) end
	end
	lookList:SetItems(items)
end

searchBox:SetScript("OnTextChanged", function (self)
	search = string.lower(self:GetText() or "")
	if search == "" then searchLabel:Show() else searchLabel:Hide() end
	refreshLooks()
end)
searchBox:SetScript("OnEditFocusGained", function () searchLabel:Hide() end)
searchBox:SetScript("OnEditFocusLost", function (self) if self:GetText() == "" then searchLabel:Show() end end)

missingCheck:SetScript("OnClick", function (self)
	missingOnly = self:GetChecked() and true or false
	refreshLooks()
end)

-----------------------------------------
-- right: the selected look

local detail = BC.CreateInset(panel)
detail:SetPoint("TOPLEFT", lookPane, "TOPRIGHT", 6, 30)
detail:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

local model = BC.CreateModel(detail)
model:SetPoint("TOPLEFT", detail, "TOPLEFT", 6, -6)
model:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -6, -6)
model:SetHeight(230)

local nameText = BC.CreateLabel(detail, "", "GameFontNormalLarge")
nameText:SetPoint("TOP", model, "BOTTOM", 0, -8)
nameText:SetWidth(240)

local statusText = BC.CreateLabel(detail, "", "GameFontHighlight")
statusText:SetPoint("TOP", nameText, "BOTTOM", 0, -6)

local infoText = BC.CreateLabel(detail, "", "GameFontHighlightSmall")
infoText:SetPoint("TOP", statusText, "BOTTOM", 0, -10)
infoText:SetWidth(240)
infoText:SetJustifyH("CENTER")

local function refreshDetail()
	local look = selectedDisplay and BC.looks[selectedDisplay]
	if not look then
		model:ShowCreature(nil)
		nameText:SetText("")
		statusText:SetText("")
		infoText:SetText(BC.catalogReady and "Pick a beast." or "")
		return
	end
	local owned = BC.owned[look.display]
	model:ShowCreature(look.entry, not owned)
	nameText:SetText(lookName(look))
	if owned then
		statusText:SetText("|cff40ff40Tamed|r")
	else
		statusText:SetText("|cff909090Not tamed yet|r")
	end

	local lines = {}
	table.insert(lines, BC.FamilyName(look.family) .. ", level " .. BC.LevelRange(look.minLevel, look.maxLevel))
	if look.zones ~= "" then table.insert(lines, "Found in " .. string.gsub(look.zones, "/", ", ")) end
	if isShiny(look) then
		table.insert(lines, "|cffff80ffA rare skin: now and then a " .. look.name .. " spawns wearing it, sparkling.|r")
	elseif BC.Has(look.flags, BC.LOOK_RARE) then
		table.insert(lines, "|cffffd100Only rare beasts wear this look.|r")
	end
	if BC.Has(look.flags, BC.LOOK_EXOTIC) then
		table.insert(lines, "|cffff8040Exotic: Beast Mastery hunters only.|r")
	end
	infoText:SetText(table.concat(lines, "\n\n"))
end

local function refresh()
	refreshFamilies()
	refreshLooks()
	refreshDetail()
end

BC.On("CATALOG", refresh)
BC.On("DEX", refresh)
BC.On("HELLO", refresh)
BC.On("DEX_FILTER", function ()
	refreshFamilies()
	refreshLooks()
end)
BC.On("LOOK_SELECTED", refreshDetail)

-- A look just tamed: show it.
BC.On("NEW", function (display)
	if display and BC.looks[display] then
		selectedDisplay = display
		refreshDetail()
	end
end)

panel:SetScript("OnShow", refresh)
