-- Beasts on the world map: when the world map shows a zone, pins for the beasts there that the
-- account has found but not tamed, and for favorites. The beast picked in the field guide (when
-- its spawn map was clicked) stands out in green. Click a pin to open its page.

local BC = BeastCollection

local layer, pins
local shown = 0

local function currentZoneName()
	local continent, zone = GetCurrentMapContinent(), GetCurrentMapZone()
	if not continent or continent < 1 or not zone or zone < 1 then return nil end
	return (select(zone, GetMapZones(continent)))
end

local function wanted(look)
	if not look then return false end
	if look.display == BC.highlight or BC.IsFavorite(look.display) then return true end
	local know = BC.Knowledge(look.display)
	return know >= BC.KNOW_FOUND and know < BC.KNOW_TAMED
end

local function pinButton(n)
	local pin = pins[n]
	if pin then return pin end
	pin = CreateFrame("Button", nil, layer)
	pin:SetSize(12, 12)
	pin.icon = pin:CreateTexture(nil, "OVERLAY")
	pin.icon:SetAllPoints(pin)
	pin.icon:SetTexture("Interface\\WorldMap\\WorldMapPartyIcon")
	pin:SetScript("OnEnter", function (self)
		local look = BC.looks[self.display]
		if not look then return end
		WorldMapTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local name = look.name
		if BC.Has(look.flags, BC.LOOK_SHINY) then name = "Shiny " .. name end
		WorldMapTooltip:AddLine(name)
		WorldMapTooltip:AddLine(BC.FamilyName(look.family) .. ", level " .. BC.LevelRange(look.minLevel, look.maxLevel), 1, 1, 1)
		local know = BC.Knowledge(look.display)
		if know >= BC.KNOW_TAMED then
			WorldMapTooltip:AddLine("Tamed", 0.25, 1, 0.25)
		elseif know >= BC.KNOW_STUDIED then
			WorldMapTooltip:AddLine("Studied", 0.44, 0.75, 1)
		end
		WorldMapTooltip:AddLine("Click to open it in the field guide.", 0.6, 0.6, 0.6)
		WorldMapTooltip:Show()
	end)
	pin:SetScript("OnLeave", function () WorldMapTooltip:Hide() end)
	pin:SetScript("OnClick", function (self)
		local display = self.display
		HideUIPanel(WorldMapFrame)
		BC.ShowLook(display)
	end)
	pins[n] = pin
	return pin
end

local function draw()
	if not layer then return end
	local n = 0
	local name = WorldMapFrame:IsShown() and BC.Setting("worldPins") and BC.catalogReady and currentZoneName()
	local zone = name and BC.zonePins[string.lower(name)]
	if name and not zone then BC.RequestZone(name) end
	if zone then
		local width, height = WorldMapButton:GetWidth(), WorldMapButton:GetHeight()
		for _, p in ipairs(zone.pins) do
			local look = BC.looks[p[1]]
			if wanted(look) and BC.Revealed(look) then
				n = n + 1
				local pin = pinButton(n)
				pin.display = p[1]
				if p[1] == BC.highlight then
					pin.icon:SetVertexColor(0.25, 1, 0.25)
					pin:SetSize(14, 14)
					pin:SetFrameLevel(layer:GetFrameLevel() + 2)
				else
					if BC.IsFavorite(p[1]) then pin.icon:SetVertexColor(1, 0.82, 0) else pin.icon:SetVertexColor(1, 0.55, 0.2) end
					pin:SetSize(11, 11)
					pin:SetFrameLevel(layer:GetFrameLevel() + 1)
				end
				pin:ClearAllPoints()
				pin:SetPoint("CENTER", WorldMapButton, "TOPLEFT", p[2] / 100 * width, -p[3] / 100 * height)
				pin:Show()
			end
		end
	end
	for i = n + 1, shown do pins[i]:Hide() end
	shown = n
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("WORLD_MAP_UPDATE")
events:SetScript("OnEvent", function (self, event)
	if event == "PLAYER_LOGIN" then
		if not WorldMapButton then return end
		layer = CreateFrame("Frame", "BeastCollectionWorldPins", WorldMapButton)
		layer:SetAllPoints(WorldMapButton)
		layer:SetFrameLevel(WorldMapButton:GetFrameLevel() + 5)
		pins = {}
		WorldMapFrame:HookScript("OnShow", draw)
		WorldMapFrame:HookScript("OnHide", function ()
			BC.highlight = nil
			draw()
		end)
	elseif WorldMapFrame and WorldMapFrame:IsShown() then
		draw()
	end
end)

BC.On("ZONE", draw)
BC.On("DEX", draw)
BC.On("FAVORITES", draw)
BC.On("SETTINGS", draw)
BC.On("CATALOG", draw)
