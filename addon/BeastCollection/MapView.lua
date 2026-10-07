-- A small zone map with pins, drawn from the client's own world map art: the zone's twelve map
-- tiles plus the overlays of the areas this character has explored, the same way the world map
-- draws them. The world map is 1002x668 "map pixels"; everything here is scaled from that.

local BC = BeastCollection

local MAP_W, MAP_H = 1002, 668
local floor, ceil, min = math.floor, math.ceil, math.min

-----------------------------------------
-- zone name -> continent, zone index, map file and explored overlays

local zoneInfo = {}  -- name -> info, or false when the world map has no such zone

local function findZone(name)
	local continents = { GetMapContinents() }
	for c = 1, #continents do
		local zones = { GetMapZones(c) }
		for i = 1, #zones do
			if zones[i] == name then return c, i end
		end
	end
end

-- Where the world map keeps a zone, or nil. Reading it means pointing the world map at the
-- zone for a moment, so it waits while the world map is open.
function BC.ZoneMapInfo(name)
	local info = zoneInfo[name]
	if info ~= nil then return info or nil end
	local c, i = findZone(name)
	if not c then
		zoneInfo[name] = false
		return nil
	end
	if WorldMapFrame and WorldMapFrame:IsShown() then return nil, true end

	SetMapZoom(c, i)
	local file = GetMapInfo()
	local overlays = {}
	for o = 1, GetNumMapOverlays() do
		local texture, width, height, x, y = GetMapOverlayInfo(o)
		if texture and texture ~= "" then
			table.insert(overlays, { texture = texture, width = width, height = height, x = x, y = y })
		end
	end
	SetMapToCurrentZone()

	info = { continent = c, zone = i, file = file, overlays = overlays }
	zoneInfo[name] = info
	return info
end

-- Newly explored areas show up next time.
local exploration = CreateFrame("Frame")
exploration:RegisterEvent("MAP_EXPLORATION_UPDATED")
exploration:SetScript("OnEvent", function ()
	for name, info in pairs(zoneInfo) do
		if info then zoneInfo[name] = nil end
	end
end)

-- Opens the world map on a zone.
function BC.OpenWorldMap(name)
	local info = BC.ZoneMapInfo(name)
	if not WorldMapFrame:IsShown() then ShowUIPanel(WorldMapFrame) end
	if not info then info = zoneInfo[name] end
	if info then SetMapZoom(info.continent, info.zone) end
end

-----------------------------------------
-- the widget
--
-- map = BC.CreateZoneMap(parent, width)
-- map:ShowZone(name, pins, options)  pins = { {x, y, data}, ... } in percent;
--   options = { color = {r, g, b}, onPinEnter = fn(pin, tooltip), onPinClick = fn(pin) }
-- map:Clear(text)

function BC.CreateZoneMap(parent, width)
	local scale = width / MAP_W
	local map = CreateFrame("Button", nil, parent)
	map:SetSize(width, floor(MAP_H * scale + 0.5))

	local backdrop = map:CreateTexture(nil, "BACKGROUND", nil, -8)
	backdrop:SetAllPoints(map)
	backdrop:SetTexture(0, 0, 0, 0.6)

	local tiles = {}
	for i = 1, 12 do
		local col, row = (i - 1) % 4, floor((i - 1) / 4)
		local w = col == 3 and (MAP_W - 768) or 256
		local h = row == 2 and (MAP_H - 512) or 256
		local tile = map:CreateTexture(nil, "BACKGROUND", nil, -6)
		tile:SetSize(w * scale, h * scale)
		tile:SetPoint("TOPLEFT", map, "TOPLEFT", col * 256 * scale, -row * 256 * scale)
		tile:SetTexCoord(0, w / 256, 0, h / 256)
		tiles[i] = tile
	end

	local overlayTextures = {}
	local function overlayTexture(n)
		local tex = overlayTextures[n]
		if not tex then
			tex = map:CreateTexture(nil, "BACKGROUND", nil, -5)
			overlayTextures[n] = tex
		end
		return tex
	end

	local message = map:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	message:SetPoint("CENTER", map, "CENTER", 0, 0)
	message:SetWidth(width - 20)

	local pinLayer = CreateFrame("Frame", nil, map)
	pinLayer:SetAllPoints(map)
	pinLayer:SetFrameLevel(map:GetFrameLevel() + 2)

	local pins = {}
	local options = {}

	local function pinButton(n)
		local pin = pins[n]
		if pin then return pin end
		pin = CreateFrame("Button", nil, pinLayer)
		pin:SetSize(10, 10)
		pin.icon = pin:CreateTexture(nil, "OVERLAY")
		pin.icon:SetAllPoints(pin)
		pin.icon:SetTexture("Interface\\WorldMap\\WorldMapPartyIcon")
		pin:SetScript("OnEnter", function (self)
			if options.onPinEnter then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				options.onPinEnter(self.data, GameTooltip)
				GameTooltip:Show()
			end
		end)
		pin:SetScript("OnLeave", function () GameTooltip:Hide() end)
		pin:SetScript("OnClick", function (self)
			if options.onPinClick then options.onPinClick(self.data) end
		end)
		pins[n] = pin
		return pin
	end

	local function hideFrom(list, n)
		for i = n, #list do list[i]:Hide() end
	end

	function map:Clear(text)
		for _, tile in ipairs(tiles) do tile:Hide() end
		hideFrom(overlayTextures, 1)
		hideFrom(pins, 1)
		message:SetText(text or "")
		message:Show()
		self.zone = nil
	end

	-- The overlay pieces, cut off where they run past the map's edge.
	local function drawOverlays(list)
		local n = 0
		for _, o in ipairs(list) do
			local wide, tall = ceil(o.width / 256), ceil(o.height / 256)
			for j = 1, tall do
				local pixelH, fileH = 256, 256
				if j == tall then
					pixelH = o.height % 256
					if pixelH == 0 then pixelH = 256 end
					fileH = 16
					while fileH < pixelH do fileH = fileH * 2 end
				end
				for k = 1, wide do
					local pixelW, fileW = 256, 256
					if k == wide then
						pixelW = o.width % 256
						if pixelW == 0 then pixelW = 256 end
						fileW = 16
						while fileW < pixelW do fileW = fileW * 2 end
					end
					local x, y = o.x + 256 * (k - 1), o.y + 256 * (j - 1)
					local w, h = min(pixelW, MAP_W - x), min(pixelH, MAP_H - y)
					if w > 0 and h > 0 then
						n = n + 1
						local tex = overlayTexture(n)
						tex:SetTexture(o.texture .. ((j - 1) * wide + k))
						tex:SetTexCoord(0, w / fileW, 0, h / fileH)
						tex:SetSize(w * scale, h * scale)
						tex:ClearAllPoints()
						tex:SetPoint("TOPLEFT", map, "TOPLEFT", x * scale, -y * scale)
						tex:Show()
					end
				end
			end
		end
		hideFrom(overlayTextures, n + 1)
	end

	function map:ShowZone(name, list, opts)
		options = opts or {}
		local info, busy = BC.ZoneMapInfo(name)
		if not info then
			self:Clear(busy and "Close the world map to see this map." or "No map of " .. (name or "?") .. ".")
			return false
		end
		self.zone = name
		message:Hide()
		for i, tile in ipairs(tiles) do
			tile:SetTexture("Interface\\WorldMap\\" .. info.file .. "\\" .. info.file .. i)
			tile:Show()
		end
		drawOverlays(info.overlays)

		local color = options.color or { 1, 0.82, 0 }
		local h = self:GetHeight()
		for i, p in ipairs(list or {}) do
			local pin = pinButton(i)
			pin.data = p
			pin.icon:SetVertexColor(color[1], color[2], color[3])
			pin:ClearAllPoints()
			pin:SetPoint("CENTER", self, "TOPLEFT", p[1] / 100 * width, -p[2] / 100 * h)
			pin:Show()
		end
		hideFrom(pins, #(list or {}) + 1)
		return true
	end

	map:Clear()
	return map
end
