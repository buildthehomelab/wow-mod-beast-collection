-- The Field Guide tab: every look a hunter can tame, by family. Target a beast to record it as
-- found, cast Beast Lore on it to study it, tame it to collect it. In immersive mode (the
-- default) looks the account hasn't found stay hidden; reveal-all shows everything.
--
-- Left: families. Middle: the looks. Right: the selected look (model, what it casts, spawn map)
-- or, with no look picked, the family's page (talent tree, diet, the abilities its pets learn).

local BC = BeastCollection

local panel, tabIndex = BC.AddTab("Field Guide")
BC.dexTab = tabIndex

local FILTER_ALL, FILTER_SHINY = -1, -2
local familyFilter = FILTER_ALL
local search = ""
local filters = {}       -- untamed, unfound, rare, zone, favorites
local selectedDisplay

local FAVORITE_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local FAVORITE_MARK = "|T" .. FAVORITE_ICON .. ":12:12|t"
local BEAST_LORE_ICON = "Interface\\Icons\\Ability_Physical_Taunt"

local TALENT_TREES = {
	[0] = { "Ferocity", "Damage. Dash or Dive, and the most damage talents." },
	[1] = { "Tenacity", "Tanking. Extra health, armor and threat talents." },
	[2] = { "Cunning", "Utility. Movement, control and PvP talents." },
}

local DIET = {
	{ 1, "Meat" }, { 2, "Fish" }, { 4, "Cheese" }, { 8, "Bread" },
	{ 16, "Fungus" }, { 32, "Fruit" }, { 64, "Raw Meat" }, { 128, "Raw Fish" },
}

local KNOW_TEXT = {
	[BC.KNOW_NONE] = "|cff909090Not found yet|r",
	[BC.KNOW_FOUND] = "|cffffd100Found|r",
	[BC.KNOW_STUDIED] = "|cff70c0ffStudied with Beast Lore|r",
	[BC.KNOW_TAMED] = "|cff40ff40Tamed|r",
}

local function isShiny(look)
	return BC.Has(look.flags, BC.LOOK_SHINY)
end

local function isRare(look)
	return BC.Has(look.flags, BC.LOOK_RARE)
end

local function lookName(look)
	if not BC.Revealed(look) then return "???" end
	if isShiny(look) then return "Shiny " .. look.name end
	return look.name
end

local function zoneList(look)
	return (string.gsub(look.zones or "", "/", ", "))
end

local function dietText(mask)
	local out = {}
	for _, d in ipairs(DIET) do
		if BC.Has(mask, d[1]) then table.insert(out, d[2]) end
	end
	return #out > 0 and table.concat(out, ", ") or "?"
end

local function progressText(have, total)
	if total > 0 and have >= total then
		return string.format("|cff40ff40%d/%d|r", have, total)
	end
	return string.format("%d/%d", have, total)
end

-- Ability names of a family in lower case, for search. Built when first needed: GetSpellInfo
-- works any time, but there's no need to pay for it before anyone searches.
local function familySearchText(family)
	if not family.searchText then
		local names = {}
		for _, ranks in ipairs(family.abilities) do
			local name = GetSpellInfo(ranks[1].spell)
			if name then table.insert(names, string.lower(name)) end
		end
		family.searchText = table.concat(names, " ")
	end
	return family.searchText
end

local function inMyZone(look)
	local here = GetRealZoneText and GetRealZoneText()
	if not here or here == "" then return false end
	for _, zone in ipairs(BC.Split(look.zones or "", "/")) do
		if zone == here then return true end
	end
	return false
end

-----------------------------------------
-- left: families

local familyPane = BC.CreateInset(panel)
familyPane:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
familyPane:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
familyPane:SetWidth(196)

local familyList = BC.CreateList(familyPane, {
	rows = 24,
	rowHeight = 20,
	columns = {
		{ title = "Family", icon = function (item) return item.icon end,
		  text = function (item) return item.label end },
		{ title = "", width = 58, align = "RIGHT", text = function (item) return item.progress end },
	},
	isSelected = function (item) return item.id == familyFilter end,
	onClick = function (item)
		familyFilter = item.id
		selectedDisplay = nil
		BC.Fire("DEX_FILTER")
		BC.Fire("LOOK_SELECTED")
	end,
	tooltip = function (item, tip)
		tip:AddLine(item.title or item.label)
		if item.found then
			tip:AddLine(string.format("Found %d, studied %d, tamed %d of %d", item.found, item.studied, item.tamed, item.total), 1, 1, 1)
		end
	end,
})
familyList:SetPoint("TOPLEFT", familyPane, "TOPLEFT", 6, -6)
familyList:SetPoint("RIGHT", familyPane, "RIGHT", -4, 0)

local function familyStats()
	local stats = {}
	for _, look in ipairs(BC.lookList) do
		if not isShiny(look) then
			local s = stats[look.family] or { found = 0, studied = 0, tamed = 0 }
			stats[look.family] = s
			local know = BC.Knowledge(look.display)
			if know >= BC.KNOW_FOUND then s.found = s.found + 1 end
			if know >= BC.KNOW_STUDIED then s.studied = s.studied + 1 end
			if know >= BC.KNOW_TAMED then s.tamed = s.tamed + 1 end
		end
	end
	return stats
end

local function refreshFamilies()
	local items = {}
	local normal, shiny = BC.Counts()
	local found, studied = BC.FoundCounts()
	if BC.server then
		table.insert(items, { id = FILTER_ALL, label = "|cffffd100All beasts|r", title = "All beasts",
			icon = "Interface\\Icons\\Ability_Hunter_BeastTaming", progress = progressText(normal, BC.server.normalTotal),
			found = found, studied = studied, tamed = normal, total = BC.server.normalTotal, order = 1 })
		if BC.server.shinyTotal > 0 then
			table.insert(items, { id = FILTER_SHINY, label = "|cffff80ffShiny|r", icon = "Interface\\Icons\\INV_Misc_Gem_Pearl_04",
				progress = progressText(shiny, BC.server.shinyTotal), order = 2 })
		end
	end
	local stats = familyStats()
	for i, family in ipairs(BC.familyList) do
		local label = family.name
		if family.exotic then label = label .. " |cffff8040*|r" end
		local s = stats[family.id] or { found = 0, studied = 0, tamed = 0 }
		table.insert(items, { id = family.id, label = label, title = family.name, icon = BC.FamilyIcon(family.id),
			progress = progressText(s.tamed, family.normal), found = s.found, studied = s.studied, tamed = s.tamed,
			total = family.normal, order = 2 + i })
	end
	familyList:SetItems(items, true)
end

-----------------------------------------
-- middle: search, filters and the looks

local searchBox = BC.CreateEditBox(panel, 150)
searchBox:SetPoint("TOPLEFT", familyPane, "TOPRIGHT", 14, -6)
local searchLabel = BC.CreateLabel(panel, "Search beasts, zones, abilities", "GameFontDisableSmall")
searchLabel:SetPoint("LEFT", searchBox, "LEFT", 4, 0)
searchLabel:SetWidth(146)
searchLabel:SetJustifyH("LEFT")

local filterButton = BC.CreateButton(panel, "Filters", 110, 22)
filterButton:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)

local lookPane = BC.CreateInset(panel)
lookPane:SetPoint("TOPLEFT", familyPane, "TOPRIGHT", 6, -30)
lookPane:SetPoint("BOTTOMLEFT", familyPane, "BOTTOMRIGHT", 6, 0)
lookPane:SetWidth(300)

local function listIcon(look)
	local know = BC.Knowledge(look.display)
	if know >= BC.KNOW_TAMED then return "Interface\\RaidFrame\\ReadyCheck-Ready" end
	if know >= BC.KNOW_STUDIED then return BEAST_LORE_ICON end
	return BC.FamilyIcon(look.family)
end

local lookList = BC.CreateList(lookPane, {
	rows = 22,
	rowHeight = 20,
	columns = {
		{ title = NAME,
		  icon = listIcon,
		  desaturate = function (look) return BC.Knowledge(look.display) == BC.KNOW_NONE end,
		  text = function (look)
			local name = lookName(look)
			local revealed = BC.Revealed(look)
			if isShiny(look) and revealed then name = name .. " " .. BC.SHINY_STAR end
			if BC.IsFavorite(look.display) then name = name .. " " .. FAVORITE_MARK end
			if revealed and isRare(look) then return "|cff3fa0ff" .. name .. "|r" end
			if BC.Knowledge(look.display) > BC.KNOW_NONE then return "|cffffffff" .. name .. "|r" end
			return "|cff909090" .. name .. "|r"
		  end,
		  -- hidden looks sort last, so the order gives nothing away
		  sort = function (look)
			if not BC.Revealed(look) then return "~" end
			return string.lower(lookName(look))
		  end },
		{ title = LEVEL_ABBR or "Lvl", width = 50, align = "CENTER",
		  text = function (look) return BC.LevelRange(look.minLevel, look.maxLevel) end,
		  sort = function (look) return look.minLevel end },
		{ title = ZONE or "Zone", width = 100,
		  text = function (look)
			if not BC.Revealed(look) then return "|cff909090?|r" end
			return zoneList(look)
		  end,
		  sort = function (look)
			if not BC.Revealed(look) then return "~" end
			return look.zones
		  end },
	},
	defaultSort = 2,
	empty = "Nothing here.",
	isSelected = function (look) return look.display == selectedDisplay end,
	onClick = function (look)
		selectedDisplay = look.display
		BC.Fire("LOOK_SELECTED")
	end,
	tooltip = function (look, tip)
		local family = BC.FamilyName(look.family)
		if not BC.Revealed(look) then
			tip:AddLine("Undiscovered " .. family)
			tip:AddLine("Level " .. BC.LevelRange(look.minLevel, look.maxLevel), 1, 1, 1)
			tip:AddLine("Target one to record it in your field guide.", 0.6, 0.6, 0.6, true)
			return
		end
		tip:AddLine(lookName(look))
		tip:AddLine(family .. ", level " .. BC.LevelRange(look.minLevel, look.maxLevel), 1, 1, 1)
		if look.zones ~= "" then tip:AddLine(zoneList(look), 0.7, 0.7, 0.7) end
		tip:AddLine(KNOW_TEXT[BC.Knowledge(look.display)])
	end,
})
lookList:SetPoint("TOPLEFT", lookPane, "TOPLEFT", 6, -6)
lookList:SetPoint("RIGHT", lookPane, "RIGHT", -4, 0)

local loading = BC.CreateLabel(lookPane, "Asking the server for the beast list...", "GameFontDisable")
loading:SetPoint("CENTER", lookPane, "CENTER", 0, 0)

local function passes(look)
	local know = BC.Knowledge(look.display)
	local revealed = BC.Revealed(look)
	if filters.untamed and know >= BC.KNOW_TAMED then return false end
	if filters.unfound and know >= BC.KNOW_FOUND then return false end
	if filters.rare and not (revealed and isRare(look)) then return false end
	if filters.zone and not (revealed and inMyZone(look)) then return false end
	if filters.favorites and not BC.IsFavorite(look.display) then return false end
	if search ~= "" then
		local family = BC.families[look.family]
		local hay = string.lower(BC.FamilyName(look.family))
		if revealed then hay = hay .. " " .. string.lower(lookName(look) .. " " .. (look.zones or "")) end
		if family then hay = hay .. " " .. familySearchText(family) end
		if not string.find(hay, search, 1, true) then return false end
	end
	return true
end

local function refreshLooks(keepScroll)
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
		if show and passes(look) then table.insert(items, look) end
	end
	lookList:SetItems(items, keepScroll)
end

searchBox:SetScript("OnTextChanged", function (self)
	search = string.lower(self:GetText() or "")
	if search == "" then searchLabel:Show() else searchLabel:Hide() end
	refreshLooks()
end)
searchBox:SetScript("OnEditFocusGained", function () searchLabel:Hide() end)
searchBox:SetScript("OnEditFocusLost", function (self) if self:GetText() == "" then searchLabel:Show() end end)

-----------------------------------------
-- the Filters menu: filters, then the field guide's options

local FILTERS = {
	{ "untamed", "Not tamed yet" },
	{ "unfound", "Not found yet" },
	{ "rare", "Rare beasts" },
	{ "zone", "In my zone" },
	{ "favorites", "Favorites" },
}

local OPTIONS = {
	{ "immersive", "Hide beasts I haven't found", "Immersive mode. Off shows every beast, like a finished guide." },
	{ "worldPins", "Beasts on the world map", "Pins for beasts you've found but not tamed, and favorites." },
	{ "record", "Record beasts I target", "Targeting or pointing at a tameable beast records it as found." },
}

local function updateFilterButton()
	local n = 0
	for _, f in ipairs(FILTERS) do if filters[f[1]] then n = n + 1 end end
	filterButton:SetText(n > 0 and ("Filters (" .. n .. ")") or "Filters")
end

function BC.SetDexFilter(key, on)
	filters[key] = on and true or nil
	updateFilterButton()
	refreshLooks()
end

local menu = CreateFrame("Frame", "BeastCollectionFilterMenu", panel, "UIDropDownMenuTemplate")
menu:Hide()

local function initMenu(self, level)
	local info = UIDropDownMenu_CreateInfo()
	info.text, info.isTitle, info.notCheckable = "Show only", 1, 1
	UIDropDownMenu_AddButton(info, level)
	for _, f in ipairs(FILTERS) do
		info = UIDropDownMenu_CreateInfo()
		info.text = f[2]
		info.checked = filters[f[1]] and 1 or nil
		info.keepShownOnClick = 1
		info.func = function () BC.SetDexFilter(f[1], not filters[f[1]]) end
		UIDropDownMenu_AddButton(info, level)
	end
	info = UIDropDownMenu_CreateInfo()
	info.text, info.isTitle, info.notCheckable = "Field guide", 1, 1
	UIDropDownMenu_AddButton(info, level)
	for _, o in ipairs(OPTIONS) do
		info = UIDropDownMenu_CreateInfo()
		info.text = o[2]
		info.checked = BC.Setting(o[1]) and 1 or nil
		info.keepShownOnClick = 1
		info.tooltipTitle, info.tooltipText = o[2], o[3]
		info.func = function () BC.SetSetting(o[1], not BC.Setting(o[1])) end
		UIDropDownMenu_AddButton(info, level)
	end
end

filterButton:SetScript("OnClick", function (self)
	UIDropDownMenu_Initialize(menu, initMenu, "MENU")
	ToggleDropDownMenu(1, nil, menu, self, 0, 0)
end)

-----------------------------------------
-- right: the selected look, or the family's page

local detail = BC.CreateInset(panel)
detail:SetPoint("TOPLEFT", lookPane, "TOPRIGHT", 6, 30)
detail:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

local MAP_WIDTH = 340

local lookView = CreateFrame("Frame", nil, detail)
lookView:SetAllPoints(detail)

local model = BC.CreateModel(lookView)
model:SetPoint("TOPLEFT", lookView, "TOPLEFT", 6, -6)
model:SetPoint("TOPRIGHT", lookView, "TOPRIGHT", -6, -6)
model:SetHeight(124)

local favorite = BC.CreateIconButton(lookView, FAVORITE_ICON, 20)
favorite:SetPoint("TOPRIGHT", model, "TOPRIGHT", -2, -2)
favorite:SetFrameLevel(model:GetFrameLevel() + 2)
favorite:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine(BC.IsFavorite(selectedDisplay) and "Remove from favorites" or "Add to favorites")
	GameTooltip:Show()
end)
favorite:SetScript("OnLeave", function () GameTooltip:Hide() end)
favorite:SetScript("OnClick", function ()
	if selectedDisplay then BC.SetFavorite(selectedDisplay, not BC.IsFavorite(selectedDisplay)) end
end)

local nameText = BC.CreateLabel(lookView, "", "GameFontNormalLarge")
nameText:SetPoint("TOP", model, "BOTTOM", 0, -6)
nameText:SetWidth(MAP_WIDTH)

local statusText = BC.CreateLabel(lookView, "", "GameFontHighlight")
statusText:SetPoint("TOP", nameText, "BOTTOM", 0, -4)

local infoText = BC.CreateLabel(lookView, "", "GameFontHighlightSmall")
infoText:SetPoint("TOP", statusText, "BOTTOM", 0, -6)
infoText:SetWidth(MAP_WIDTH - 10)
infoText:SetJustifyH("CENTER")

-- the spawn map, from the bottom up
local zoneMap = BC.CreateZoneMap(lookView, MAP_WIDTH)
zoneMap:SetPoint("BOTTOM", lookView, "BOTTOM", 0, 8)

local zoneText = BC.CreateLabel(lookView, "", "GameFontNormalSmall")
zoneText:SetPoint("BOTTOM", zoneMap, "TOP", 0, 5)
zoneText:SetWidth(MAP_WIDTH - 60)

local prevZone = BC.CreateIconButton(lookView, "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up", 20)
prevZone:SetPoint("BOTTOMLEFT", zoneMap, "TOPLEFT", 0, 0)
local nextZone = BC.CreateIconButton(lookView, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", 20)
nextZone:SetPoint("BOTTOMRIGHT", zoneMap, "TOPRIGHT", 0, 0)

-- what it casts in the wild
local spellLabel = BC.CreateLabel(lookView, "", "GameFontNormalSmall")
spellLabel:SetPoint("BOTTOMLEFT", zoneMap, "TOPLEFT", 4, 30)

local spellIcons = {}
for i = 1, 6 do
	local icon = BC.CreateIconButton(lookView, nil, 20)
	if i == 1 then
		icon:SetPoint("LEFT", spellLabel, "RIGHT", 6, 0)
	else
		icon:SetPoint("LEFT", spellIcons[i - 1], "RIGHT", 4, 0)
	end
	icon:SetScript("OnEnter", function (self)
		if not self.spell then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink("spell:" .. self.spell)
		GameTooltip:Show()
	end)
	icon:SetScript("OnLeave", function () GameTooltip:Hide() end)
	spellIcons[i] = icon
end

local zoneIndex = 1

local function showSpells(look)
	for _, icon in ipairs(spellIcons) do icon:Hide() end
	if not BC.Revealed(look) then
		spellLabel:SetText("")
		return
	end
	if not BC.Studied(look) then
		spellLabel:SetText("|cff909090Cast Beast Lore on one to see what it does.|r")
		return
	end
	local n = 0
	for _, spell in ipairs(look.spells or {}) do
		local name, _, texture = GetSpellInfo(spell)
		if name and n < #spellIcons then
			n = n + 1
			local icon = spellIcons[n]
			icon.spell = spell
			icon.icon:SetTexture(texture)
			icon:Show()
		end
	end
	spellLabel:SetText(n > 0 and "In the wild:" or "|cff909090Uses no special abilities in the wild.|r")
end

local function showMap(look)
	prevZone:Hide()
	nextZone:Hide()
	if not BC.Revealed(look) then
		zoneText:SetText("")
		zoneMap:Clear("Find this beast to see where it lives.")
		return
	end
	local zones = BC.maps[look.display]
	if not zones then
		zoneText:SetText("")
		zoneMap:Clear("Loading the map...")
		BC.RequestMap(look.display)
		return
	end
	if #zones == 0 then
		zoneText:SetText("")
		zoneMap:Clear(look.zones ~= "" and ("Lives in " .. zoneList(look) .. ". No world map there.") or "No spawns on a world map.")
		return
	end
	if zoneIndex > #zones then zoneIndex = 1 end
	local zone = zones[zoneIndex]
	local spawns = #zone.pins == 1 and "1 spot" or (#zone.pins .. " spots")
	zoneText:SetText(zone.name .. "  |cffffffff" .. spawns .. "|r")
	if #zones > 1 then
		prevZone:Show()
		nextZone:Show()
	end
	zoneMap:ShowZone(zone.name, zone.pins, {
		onPinEnter = function (pin, tip)
			tip:AddLine(lookName(look))
			tip:AddLine(string.format("%s %.0f, %.0f", zone.name, pin[1], pin[2]), 1, 1, 1)
			tip:AddLine("Click to open the world map.", 0.6, 0.6, 0.6)
		end,
		onPinClick = function () zoneMap:Click() end,
	})
	zoneMap.zoneName = zone.name
end

zoneMap:SetScript("OnClick", function (self)
	if not self.zoneName or not self.zone then return end
	BC.highlight = selectedDisplay
	BC.OpenWorldMap(self.zoneName)
end)
zoneMap:SetScript("OnEnter", function (self)
	if not self.zone then return end
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine("Click to open the world map here.")
	GameTooltip:Show()
end)
zoneMap:SetScript("OnLeave", function () GameTooltip:Hide() end)

local function stepZone(delta)
	local look = selectedDisplay and BC.looks[selectedDisplay]
	local zones = look and BC.maps[look.display]
	if not zones or #zones < 2 then return end
	zoneIndex = (zoneIndex - 1 + delta) % #zones + 1
	showMap(look)
end
prevZone:SetScript("OnClick", function () stepZone(-1) end)
nextZone:SetScript("OnClick", function () stepZone(1) end)

local function refreshLook(look)
	local know = BC.Knowledge(look.display)
	local revealed = BC.Revealed(look)
	model:ShowCreature(look.entry, know == BC.KNOW_NONE)
	favorite.icon:SetDesaturated(not BC.IsFavorite(look.display))
	favorite:SetAlpha(BC.IsFavorite(look.display) and 1 or 0.6)
	nameText:SetText(lookName(look))
	if revealed and isRare(look) then nameText:SetTextColor(0.25, 0.63, 1) else nameText:SetTextColor(1, 0.82, 0) end
	statusText:SetText(KNOW_TEXT[know])

	local lines = {}
	table.insert(lines, BC.FamilyName(look.family) .. ", level " .. BC.LevelRange(look.minLevel, look.maxLevel))
	if not revealed then
		table.insert(lines, "|cff909090Target one to record it.|r")
	elseif isShiny(look) then
		table.insert(lines, "|cffff80ffA rare skin: now and then a " .. look.name .. " spawns wearing it, sparkling.|r")
	elseif isRare(look) then
		table.insert(lines, "|cff3fa0ffOnly rare beasts wear this look.|r")
	end
	if BC.Has(look.flags, BC.LOOK_EXOTIC) then
		table.insert(lines, "|cffff8040Exotic: Beast Mastery hunters only.|r")
	end
	infoText:SetText(table.concat(lines, "\n"))
	showSpells(look)
	showMap(look)
end

-- the family page

local familyView = CreateFrame("Frame", nil, detail)
familyView:SetAllPoints(detail)

local familyIcon = familyView:CreateTexture(nil, "ARTWORK")
familyIcon:SetSize(40, 40)
familyIcon:SetPoint("TOPLEFT", familyView, "TOPLEFT", 14, -14)

local familyName = BC.CreateLabel(familyView, "", "GameFontNormalLarge")
familyName:SetPoint("TOPLEFT", familyIcon, "TOPRIGHT", 10, -2)

local familyTree = BC.CreateLabel(familyView, "", "GameFontHighlightSmall")
familyTree:SetPoint("TOPLEFT", familyName, "BOTTOMLEFT", 0, -4)

local familyInfo = BC.CreateLabel(familyView, "", "GameFontHighlightSmall")
familyInfo:SetPoint("TOPLEFT", familyIcon, "BOTTOMLEFT", 0, -10)
familyInfo:SetWidth(MAP_WIDTH - 16)
familyInfo:SetJustifyH("LEFT")

local abilityTitle = BC.CreateLabel(familyView, "Abilities its pets learn", "GameFontNormal")
abilityTitle:SetPoint("TOPLEFT", familyInfo, "BOTTOMLEFT", 0, -14)

local abilityRows = {}
local function abilityRow(i)
	local row = abilityRows[i]
	if row then return row end
	row = CreateFrame("Button", nil, familyView)
	row:SetSize(MAP_WIDTH - 16, 22)
	if i == 1 then
		row:SetPoint("TOPLEFT", abilityTitle, "BOTTOMLEFT", 0, -6)
	else
		row:SetPoint("TOPLEFT", abilityRows[i - 1], "BOTTOMLEFT", 0, -2)
	end
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(20, 20)
	row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
	row.name = BC.CreateLabel(row, "", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.ranks = BC.CreateLabel(row, "", "GameFontDisableSmall")
	row.ranks:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(row)
	hl:SetTexture(1, 1, 1, 0.08)
	row:SetScript("OnEnter", function (self)
		if not self.ranksList then return end
		local last = self.ranksList[#self.ranksList]
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetHyperlink("spell:" .. last.spell)
		if #self.ranksList > 1 then
			GameTooltip:AddLine(" ")
			local levels = {}
			for r, rank in ipairs(self.ranksList) do table.insert(levels, r .. ": " .. rank.level) end
			GameTooltip:AddLine("Pet level per rank  " .. table.concat(levels, "  "), 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function () GameTooltip:Hide() end)
	abilityRows[i] = row
	return row
end

local function refreshFamily(id)
	local family = BC.families[id]
	if not family then return end
	familyIcon:SetTexture(BC.FamilyIcon(id))
	familyName:SetText(family.name)
	local tree = TALENT_TREES[family.talent]
	familyTree:SetText((tree and tree[1] or "?") .. (family.exotic and "   |cffff8040Exotic: Beast Mastery only|r" or ""))

	local s = familyStats()[id] or { found = 0, studied = 0, tamed = 0 }
	local lines = {}
	if tree then table.insert(lines, tree[2]) end
	table.insert(lines, "|cffffd100Diet:|r " .. dietText(family.food))
	table.insert(lines, string.format("|cffffd100Looks:|r %d found, %d studied, %d tamed of %d", s.found, s.studied, s.tamed, family.normal))
	if family.shiny > 0 then
		local shinyTamed = 0
		for _, look in ipairs(BC.lookList) do
			if look.family == id and isShiny(look) and BC.owned[look.display] then shinyTamed = shinyTamed + 1 end
		end
		table.insert(lines, string.format("|cffff80ffShiny looks:|r %d of %d", shinyTamed, family.shiny))
	end
	familyInfo:SetText(table.concat(lines, "\n"))

	local n = 0
	for _, ranks in ipairs(family.abilities) do
		local name, _, texture = GetSpellInfo(ranks[#ranks].spell)
		if name and n < 16 then
			n = n + 1
			local row = abilityRow(n)
			row.ranksList = ranks
			row.icon:SetTexture(texture)
			row.name:SetText(name)
			if #ranks > 1 then
				row.ranks:SetText(string.format("%d ranks, pet level %d-%d", #ranks, ranks[1].level, ranks[#ranks].level))
			else
				row.ranks:SetText("pet level " .. ranks[1].level)
			end
			row:Show()
		end
	end
	for i = n + 1, #abilityRows do abilityRows[i]:Hide() end
	if n == 0 then abilityTitle:SetText("") else abilityTitle:SetText("Abilities its pets learn") end
end

-- the overview: All beasts, Shiny, or nothing yet

local overview = BC.CreateLabel(detail, "", "GameFontHighlight")
overview:SetPoint("TOPLEFT", detail, "TOPLEFT", 16, -20)
overview:SetWidth(MAP_WIDTH - 20)
overview:SetJustifyH("LEFT")

local function refreshOverview()
	if not BC.catalogReady or not BC.server then
		overview:SetText("")
		return
	end
	local normal, shiny = BC.Counts()
	local found, studied = BC.FoundCounts()
	local lines = {
		"|cffffd100Hunter's field guide|r",
		" ",
		string.format("Found  |cffffffff%d|r / %d", found, BC.server.normalTotal),
		string.format("Studied  |cffffffff%d|r / %d", studied, BC.server.normalTotal),
		string.format("Tamed  |cffffffff%d|r / %d", normal, BC.server.normalTotal),
	}
	if BC.server.shinyTotal > 0 then
		table.insert(lines, string.format("Shiny  |cffffffff%d|r / %d", shiny, BC.server.shinyTotal))
	end
	table.insert(lines, " ")
	if BC.Has(BC.server.flags, BC.FEATURE_DISCOVERY) then
		table.insert(lines, "|cffc0c0c0Target a tameable beast to record it. Cast Beast Lore on it to study it and learn what it does in the wild. Tame it to add it to your collection.|r")
		table.insert(lines, " ")
		table.insert(lines, "|cffc0c0c0Pick a family for its talent tree, diet and the abilities its pets learn.|r")
	else
		table.insert(lines, "|cffc0c0c0Pick a family for its talent tree, diet and the abilities its pets learn.|r")
	end
	overview:SetText(table.concat(lines, "\n"))
end

local function refreshDetail()
	local look = selectedDisplay and BC.looks[selectedDisplay]
	lookView:Hide()
	familyView:Hide()
	overview:Hide()
	if look then
		lookView:Show()
		refreshLook(look)
	elseif BC.families[familyFilter] then
		familyView:Show()
		refreshFamily(familyFilter)
	else
		model:ShowCreature(nil)
		overview:Show()
		refreshOverview()
	end
end

-- keepScroll: the same list with fresh data (a find, a tame), so don't jump back to the top
local function refresh(keepScroll)
	refreshFamilies()
	refreshLooks(keepScroll)
	refreshDetail()
end

BC.On("CATALOG", function () refresh() end)
BC.On("DEX", function () refresh(true) end)
BC.On("HELLO", function () refresh() end)
BC.On("FAVORITES", function ()
	refreshLooks(true)
	refreshDetail()
end)
BC.On("SETTINGS", function () refresh() end)
BC.On("DEX_FILTER", function ()
	refreshFamilies()
	refreshLooks()
end)
BC.On("LOOK_SELECTED", function ()
	zoneIndex = 1
	refreshDetail()
end)
BC.On("MAP", function (display)
	if display == selectedDisplay then refreshDetail() end
end)

-- A look just tamed: show it.
BC.On("NEW", function (display)
	if display and BC.looks[display] then
		selectedDisplay = display
		refreshDetail()
	end
end)

-- From a world map pin or elsewhere: open on this look.
BC.On("SHOW_LOOK", function (display)
	local look = BC.looks[display]
	if not look then return end
	familyFilter = isShiny(look) and FILTER_SHINY or look.family
	selectedDisplay = display
	zoneIndex = 1
	refresh()
end)

panel:SetScript("OnShow", function () refresh(true) end)
