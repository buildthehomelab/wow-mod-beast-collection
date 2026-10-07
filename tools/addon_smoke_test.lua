-- Smoke test for the BeastCollection addon outside the game: stubs just enough of the 3.3.5a API,
-- loads the addon in .toc order and replays fake server replies through the real protocol code.
-- Usage (any Lua 5.3+): lua tools/addon_smoke_test.lua addon/BeastCollection

local dir = arg[1]
unpack = table.unpack
bit = {
	band = function (a, b) return math.floor(a) & math.floor(b) end,
	lshift = function (a, n) return math.floor(a) << n end,
	bor = function (a, b) return math.floor(a) | math.floor(b) end,
	bnot = function (a) return ~math.floor(a) end,
}
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
_G = _G

local now = 0
function GetTime() return now end

local errors = 0
local function report(where, err)
	errors = errors + 1
	print("ERROR in " .. where .. ": " .. tostring(err))
	print(debug.traceback())
end

-- Frames: tables with scripts; unknown methods are no-ops returning nil.
local frameMeta = {}
local allFrames = {}
local function newObject(kind, name, parent)
	local o = { __kind = kind, __name = name, __scripts = {}, __shown = kind ~= "Frame" or true, __text = "",
		__width = 100, __height = 20, __checked = nil, __children = {}, __parent = parent, __level = 1, __enabled = true }
	setmetatable(o, frameMeta)
	if name then _G[name] = o end
	table.insert(allFrames, o)
	return o
end

local methods = {}
function methods:SetScript(event, fn) self.__scripts[event] = fn end
function methods:GetScript(event) return self.__scripts[event] end
function methods:HookScript(event, fn)
	local old = self.__scripts[event]
	self.__scripts[event] = function (...) if old then old(...) end fn(...) end
end
function methods:Show() local was = self.__shown; self.__shown = true; if not was and self.__scripts.OnShow then self.__scripts.OnShow(self) end end
function methods:Hide() local was = self.__shown; self.__shown = false; if was and self.__scripts.OnHide then self.__scripts.OnHide(self) end end
function methods:IsShown() return self.__shown end
function methods:IsVisible() return self.__shown end
function methods:SetText(t) self.__text = t == nil and "" or tostring(t) end
function methods:GetText() return self.__text end
function methods:GetNumber() return tonumber(self.__text) or 0 end
function methods:SetChecked(c) self.__checked = c and 1 or nil end
function methods:GetChecked() return rawget(self, "__checked") end
function methods:GetWidth() return self.__width end
function methods:GetHeight() return self.__height end
function methods:SetWidth(w) self.__width = w end
function methods:SetHeight(h) self.__height = h end
function methods:SetSize(w, h) self.__width, self.__height = w, h end
function methods:GetName() return self.__name end
function methods:GetFrameLevel() return self.__level end
function methods:GetObjectType() return self.__kind end
function methods:GetRegions() return end
function methods:GetChildren() return end
function methods:CreateTexture() return newObject("Texture") end
function methods:CreateFontString() return newObject("FontString") end
function methods:GetTexture() return nil end
function methods:Enable() self.__enabled = true end
function methods:Disable() self.__enabled = false end
function methods:IsEnabled() return self.__enabled and 1 or nil end
function methods:HasFocus() return false end
function methods:GetID() return self.__id or 0 end
function methods:SetID(i) self.__id = i end
function methods:NumLines() return 0 end
function methods:GetStringWidth() return #self.__text * 7 end
function methods:IsOwned() return false end
function methods:GetVerticalScroll() return 0 end
-- Unknown methods (capitalised, like the real API) are no-ops; unknown fields are nil.
frameMeta.__index = function (t, k)
	if methods[k] then return methods[k] end
	if type(k) == "string" and k:match("^%u") then return function () end end
	return nil
end

function CreateFrame(kind, name, parent, template)
	local f = newObject(kind, name, parent)
	f.__shown = true
	if name and template then
		if template:find("Check") then _G[name .. "Text"] = newObject("FontString") end
		if template:find("MoneyInput") then
			for _, p in ipairs({ "Gold", "Silver", "Copper" }) do _G[name .. p] = newObject("EditBox") end
			f.__copper = 0
		end
		if template:find("FauxScroll") then _G[name .. "ScrollBar"] = newObject("Slider") end
	end
	return f
end

function MoneyInputFrame_GetCopper(f) return f.__copper or 0 end
function MoneyInputFrame_SetCopper(f, c) f.__copper = c; if f.onValueChangedFunc then f.onValueChangedFunc() end end
function MoneyInputFrame_SetOnValueChangedFunc(f, fn) f.onValueChangedFunc = fn end
function FauxScrollFrame_Update() end
function FauxScrollFrame_GetOffset() return 0 end
function FauxScrollFrame_SetOffset() end
function FauxScrollFrame_OnVerticalScroll(self, offset, h, fn) fn() end
function PanelTemplates_SetTab() end
function PanelTemplates_SetNumTabs() end
function PanelTemplates_TabResize() end
function PlaySound() end
function SetPortraitTexture() end
function OpenAllBags() end
function IsAddOnLoaded() return false end
function IsModifiedClick() return false end
function IsShiftKeyDown() return false end
function CursorHasItem() return false end
function GetCursorInfo() return nil end
function ClearCursor() end
function ChatEdit_InsertLink() end
function DressUpItemLink() end
function ChatFrame_AddMessageEventFilter() end
function StaticPopup_Hide() end
local lastPopup
function StaticPopup_Show(which, text)
	lastPopup = { which = which, text = text }
	return lastPopup
end
function UnitName() return "Tester" end
local target = nil  -- the fake target: { guid, family }
function UnitGUID(unit) if unit == "target" and target then return target.guid end return "0xF130001234005678" end
function UnitExists(unit) return unit == "target" and target ~= nil end
function UnitIsPlayer() return false end
function UnitPlayerControlled() return false end
function UnitCreatureFamily(unit) return unit == "target" and target and target.family or nil end
function GetRealZoneText() return "Duskwood" end
local SPELLS = { [17253] = "Bite", [17255] = "Bite", [61684] = "Dash", [24604] = "Furious Howl", [3604] = "Tendon Rip" }
function GetSpellInfo(id) local n = SPELLS[id] if n then return n, "", "Interface\\Icons\\Ability_Druid_Bash" end end
-- the world map: two continents, a map file per zone, one explored overlay
local MAP_ZONES = { { "Durotar", "The Barrens" }, { "Duskwood", "Elwynn Forest" } }
local mapZoom = { 0, 0 }
function GetMapContinents() return "Kalimdor", "Eastern Kingdoms" end
function GetMapZones(c) return unpack(MAP_ZONES[c] or {}) end
function SetMapZoom(c, z) mapZoom = { c, z or 0 }; mapZoomCalls = (mapZoomCalls or 0) + 1 end
function SetMapToCurrentZone() mapZoom = { 2, 1 } end
function GetCurrentMapContinent() return mapZoom[1] end
function GetCurrentMapZone() return mapZoom[2] end
function GetMapInfo() local z = MAP_ZONES[mapZoom[1]] return z and (string.gsub(z[mapZoom[2]] or "", " ", "")) end
function GetNumMapOverlays() return 1 end
function GetMapOverlayInfo() return "Interface\\WorldMap\\Duskwood\\Raven", 300, 200, 700, 500 end
local menuItems = {}
function UIDropDownMenu_CreateInfo() return {} end
function UIDropDownMenu_AddButton(info) table.insert(menuItems, info) end
function UIDropDownMenu_Initialize(frame, fn) wipe(menuItems); fn(frame, 1) end
function ToggleDropDownMenu() end
function GetMoney() return 5000000 end
function GetAuctionSellItemInfo() return nil end
function ClickAuctionSellItemButton() end
function CloseAuctionHouse() print("  (client) CloseAuctionHouse") end
function AuctionFrame_LoadUI() print("  (client) AuctionFrame_LoadUI") end
function AuctionFrame_Show() print("  (client) AuctionFrame_Show") end
function ShowUIPanel(f) f:Show() end
function HideUIPanel(f) f:Hide() end

function GetItemInfo(id)
	if id == 8490 then return "Cat Carrier (Siamese)", "item:8490", 1 end
end
function GetItemQualityColor() return 1, 1, 1, "|cffffffff" end
function GetRealmName() return "Test Realm" end
function GetCursorPosition() return 0, 0 end
function PlaySoundFile() end
UIErrorsFrame = { AddMessage = function (_, m) print("  [error] " .. m) end }
NAME, LEVEL_ABBR, ZONE = "Name", "Lvl", "Zone"
ACCEPT, CANCEL = "Accept", "Cancel"
UIParent = newObject("Frame", "UIParent")
WorldMapFrame = newObject("Frame", "WorldMapFrame")
WorldMapFrame.__shown = false
WorldMapButton = newObject("Button", "WorldMapButton")
WorldMapButton:SetSize(1002, 668)
WorldMapTooltip = newObject("GameTooltip", "WorldMapTooltip")
WorldFrame = newObject("Frame", "WorldFrame")
GameTooltip = newObject("GameTooltip", "GameTooltip")
DEFAULT_CHAT_FRAME = { AddMessage = function (_, m) print("  [chat] " .. m) end }
GameFontHighlightSmall, GameFontNormalSmall = {}, {}
UIPanelWindows, StaticPopupDialogs, SlashCmdList, UISpecialFrames = {}, {}, {}, {}

-- Outgoing messages go to a fake server that answers like mod-beast-collection.
local outbox = {}
local sent = {}
function SendAddonMessage(prefix, msg, channel, target)
	assert(prefix == "BCOL" and channel == "WHISPER", "bad addon message")
	assert(#prefix + 1 + #msg <= 254, "addon message too long: " .. #msg)
	table.insert(outbox, msg)
	table.insert(sent, msg)
end

local eventFrames = {}
function methods:RegisterEvent(e) eventFrames[e] = eventFrames[e] or {}; table.insert(eventFrames[e], self) end
function methods:UnregisterEvent() end
local function fire(event, ...)
	for _, f in ipairs(eventFrames[event] or {}) do
		local ok, err = pcall(f.__scripts.OnEvent, f, event, ...)
		if not ok then report(event, err) end
	end
end

local function reply(msg)
	assert(#msg <= 250, "server message too long: " .. #msg)
	fire("CHAT_MSG_ADDON", "BCOL", msg, "WHISPER", "Tester")
end

-- The fake server's state.
local pets = {
	{ id = 11, entry = 3122, display = 1000, level = 12, flags = 1, family = 1, name = "Fang" },
	{ id = 12, entry = 3123, display = 1001, level = 10, flags = 2, family = 2, name = "Whiskers" },
	{ id = 13, entry = 3124, display = 2000, level = 8, flags = 4 + 16, family = 1, name = "Sparkles" },
}
local owned = { 1000, 1001, 2000 }
local seen = { [1001] = 2 }
local catalogRequests = 0
local mapRequests, zoneRequests = 0, 0

local function sendPets()
	local rows = {}
	for _, p in ipairs(pets) do
		table.insert(rows, table.concat({ p.id, p.entry, p.display, p.level, p.flags, p.family, p.name }, ","))
	end
	reply("P:" .. table.concat(rows, ";"))
	reply("PE:" .. #pets .. ":0:1:0")
end

local function serve(msg)
	print("  -> " .. msg)
	local cmd, arg = msg:match("^(%u+):?(.*)$")
	if cmd == "H" then
		reply("HELLO:1:4242:3:1:10000:15:1")
	elseif cmd == "CAT" then
		catalogRequests = catalogRequests + 1
		reply("F:1,Wolf,0,2,1,0,1;2,Cat,0,1,0,0,65")
		reply("A:1,17253-1/17255-8;1,61684-10;1,24604-20;2,17253-1")
		reply("C:1000,1,0,3122,10,12,Timber Wolf,Elwynn Forest/Westfall,;1002,1,4,3125,30,30,Old Greyjaw,Duskwood,3604/99999")
		reply("C:1001,2,0,3123,8,10,Bobcat,Duskwood,;2000,1,2,9000,10,12,Timber Wolf,Elwynn Forest,")
		reply("CE:4242:4")
	elseif cmd == "DEX" then
		local rows = {}
		for _, d in ipairs(owned) do table.insert(rows, tostring(d)) end
		reply("O:" .. table.concat(rows, ";"))
		reply("OE:" .. #owned)
		reply("R:1,0,10,0,0,8490,0,Tame 10 beast looks;6,1,1,0,1,49343,0,Tame a shiny beast;7,2,0,0,1,0,250000,Complete a family")
		reply("RE:3")
		local rows = {}
		for d, level in pairs(seen) do table.insert(rows, d .. "," .. level) end
		reply("S:" .. table.concat(rows, ";"))
		reply("SE:" .. #rows)
	elseif cmd == "SEE" then
		if arg == "0xF130000C3D000101" and not seen[1002] then
			seen[1002] = 1
			reply("SEEN:1002:1:3")
		end
	elseif cmd == "MAP" then
		mapRequests = mapRequests + 1
		if arg == "1002" then
			reply("MZ:1002:10,Duskwood,2;12,Elwynn Forest,1")
			reply("MP:1002:10,455,601;10,470,622;12,300,300")
		end
		reply("ME:" .. arg)
	elseif cmd == "ZONE" then
		zoneRequests = zoneRequests + 1
		if arg == "Duskwood" then
			reply("ZP:10:1002,455,601;1002,470,622;1001,200,200;1000,500,500")
			reply("ZE:10:4:Duskwood")
		else
			reply("ZE:0:0:" .. arg)
		end
	elseif cmd == "PETS" then
		sendPets()
	elseif cmd == "CALL" then
		local id = tonumber(arg)
		if id == 11 then reply("ERR:CALL:active"); return end
		for _, p in ipairs(pets) do
			if p.flags % 2 == 1 then p.flags = p.flags - 1 + 4 end
			if p.id == id then p.flags = 1 + (p.flags >= 16 and 16 or 0) end
		end
		reply("OK:CALL:" .. id)
		sendPets()
	elseif cmd == "STORE" then
		for _, p in ipairs(pets) do if p.id == tonumber(arg) then p.flags = 4 + (p.flags >= 16 and 16 or 0) end end
		reply("OK:STORE:" .. arg)
		sendPets()
	elseif cmd == "FREE" then
		for i, p in ipairs(pets) do if p.id == tonumber(arg) then table.remove(pets, i) break end end
		reply("OK:FREE:" .. arg)
		sendPets()
	else
		reply("ERR:" .. tostring(cmd) .. ":unknown")
	end
end

local function tick(seconds)
	for _ = 1, math.ceil(seconds / 0.05) do
		now = now + 0.05
		for _, f in ipairs(allFrames) do
			if f.__shown and f.__scripts.OnUpdate then
				local ok, err = pcall(f.__scripts.OnUpdate, f, 0.05)
				if not ok then report("OnUpdate", err) end
			end
		end
		while #outbox > 0 do serve(table.remove(outbox, 1)) end
	end
end

local function step(name, fn)
	print("== " .. name)
	local ok, err = xpcall(fn, debug.traceback)
	if not ok then errors = errors + 1; print("ERROR: " .. err) end
	tick(1)
end

local function loadAddon()
	for line in io.lines(dir .. "/BeastCollection.toc") do
		if line:match("%.lua$") then
			local chunk, err = loadfile(dir .. "/" .. line)
			if not chunk then report("load " .. line, err) else
				local ok, e = pcall(chunk, "BeastCollection", {})
				if not ok then report("run " .. line, e) end
			end
		end
	end
end

local function find(pred)
	for _, f in ipairs(allFrames) do if pred(f) then return f end end
end

local function findText(pattern)
	return find(function (f) return f.__kind == "FontString" and f.__text:find(pattern, 1, true) end)
end

local function listWith(pred)
	for _, f in ipairs(allFrames) do
		local items = rawget(f, "items")
		if type(items) == "table" and #items > 0 and pred(items[1]) then return f end
	end
end

loadAddon()
local BC = BeastCollection

step("login says hello", function ()
	fire("ADDON_LOADED", "BeastCollection")
	fire("PLAYER_LOGIN")
	tick(5)
	assert(BC.server and BC.server.hunter, "no HELLO")
	assert(not BC.catalogReady, "catalog ready without asking")
end)

step("opening the window loads catalog, dex, pets and rewards", function ()
	BC.frame:Hide()
	BC.Toggle()
	tick(1)
	assert(BC.catalogReady and #BC.lookList == 4, "catalog not loaded")
	assert(BC.owned[2000], "dex not loaded")
	assert(#BC.pets == 3, "pets not loaded")
	assert(#BC.rewards == 3, "rewards not loaded")
	assert(findText("Found: |cffffffff2|r / 3   Tamed: |cffffffff2|r / 3"), "progress line wrong")
	assert(BC.seen[1001] == 2, "finds not loaded")
	assert(#BC.families[1].abilities == 3, "abilities not loaded")
	assert(BC.looks[1002].spells[1] == 3604, "wild spells not loaded")
	assert(findText("3 beasts, 1 in the box"), "pet counter wrong")
end)

step("the active pet is selected and can't be called", function ()
	assert(findText("Fang"), "active pet not shown")
	local call = find(function (f) return f.__kind == "Button" and f.__text == "Call" end)
	assert(call and not call.__enabled, "Call enabled for the active pet")
end)

step("calling a boxed pet", function ()
	local list = listWith(function (item) return item.id ~= nil and item.entry ~= nil end)
	local sparkles
	for _, p in ipairs(list.items) do if p.name == "Sparkles" then sparkles = p end end
	assert(sparkles, "boxed pet not listed")
	BC.Call(sparkles)
	tick(0.5)
	local now
	for _, p in ipairs(BC.pets) do if p.name == "Sparkles" then now = p end end
	assert(BC.Has(now.flags, BC.PET_ACTIVE), "Sparkles not active after call")
	assert(findText("Your beast is at your side."), "no status line")
end)

step("errors are shown", function ()
	BC.Call({ id = 11 })
	tick(0.5)
	assert(findText("already at your side"), "error not shown")
end)

step("release asks first", function ()
	StaticPopupDialogs.BEASTCOLLECTION_CONFIRM.OnAccept(nil, function () BC.Release({ id = 12 }) end)
	tick(0.5)
	assert(#BC.pets == 2, "pet not released")
end)

local function dexLooks()
	return listWith(function (item) return item.display ~= nil and item.zones ~= nil end)
end

step("field guide tab: families, filters, hidden beasts", function ()
	BC.SelectTab(2)
	tick(0.5)
	local looks = dexLooks()
	assert(looks and #looks.items == 3, "guide should list 3 normal looks, got " .. (looks and #looks.items or 0))
	BC.SetDexFilter("untamed", true)
	assert(#looks.items == 1 and looks.items[1].display == 1002, "untamed filter wrong")
	assert(looks.spec.columns[1].text(looks.items[1]):find("???", 1, true), "unfound look not hidden in immersive mode")
	BC.SetDexFilter("untamed", false)
	BC.SetDexFilter("zone", true)
	assert(#looks.items == 1 and looks.items[1].display == 1001, "in-my-zone filter wrong (hidden looks must not show)")
	BC.SetDexFilter("zone", false)
end)

step("search finds family abilities", function ()
	local box = find(function (f) return f.__kind == "EditBox" and f.__scripts.OnTextChanged and f.__width == 150 end)
	box:SetText("dash")
	box.__scripts.OnTextChanged(box)
	local looks = dexLooks()
	assert(#looks.items == 2, "dash should match the two wolves, got " .. #looks.items)
	box:SetText("")
	box.__scripts.OnTextChanged(box)
end)

step("family page", function ()
	local families = listWith(function (item) return item.icon ~= nil and item.progress ~= nil end)
	local wolf
	for _, item in ipairs(families.items) do if item.id == 1 then wolf = item end end
	families.spec.onClick(wolf)
	assert(findText("Diet:|r Meat"), "diet missing")
	assert(findText("Ferocity"), "talent tree missing")
	assert(findText("Furious Howl"), "ability missing")
	assert(findText("2 ranks, pet level 1-8"), "ranks missing")
end)

step("targeting a beast records it", function ()
	target = { guid = "0xF130000C3D000101", family = "Wolf" }
	fire("PLAYER_TARGET_CHANGED")
	tick(0.5)
	assert(BC.seen[1002] == 1, "target not recorded")
	assert(BC.Revealed(BC.looks[1002]), "found look still hidden")
	local before = #sent
	fire("PLAYER_TARGET_CHANGED")
	tick(0.5)
	assert(#sent == before, "same beast reported twice")
	target = nil
end)

step("a found look shows its spawn map; abilities wait for Beast Lore", function ()
	BC.Fire("SHOW_LOOK", 1002)
	tick(0.5)
	assert(mapRequests == 1 and BC.maps[1002] and #BC.maps[1002] == 2, "map not loaded")
	assert(#BC.maps[1002][1].pins == 2, "pins not loaded")
	assert(findText("Duskwood  |cffffffff2 spots|r"), "zone line missing")
	assert(findText("Cast Beast Lore"), "abilities should wait for Beast Lore")
	fire("CHAT_MSG_ADDON", "BCOL", "SEEN:1002:2:3", "WHISPER", "Tester")
	assert(findText("In the wild:"), "abilities not shown after Beast Lore")
	assert(findText("Studied with Beast Lore"), "status not studied")
	BC.Fire("SHOW_LOOK", 1002)
	tick(0.5)
	assert(mapRequests == 1, "map asked for twice")
end)

step("world map pins", function ()
	BC.highlight = nil
	WorldMapFrame:Show()
	mapZoom = { 2, 1 }
	fire("WORLD_MAP_UPDATE")
	tick(0.5)
	assert(zoneRequests == 1 and BC.zonePins["duskwood"], "zone pins not asked for")
	local pinLayer = _G.BeastCollectionWorldPins
	local count = 0
	for _, f in ipairs(allFrames) do if f.__parent == pinLayer and f.__shown and rawget(f, "display") then count = count + 1 end end
	-- 1002 is found, not tamed: two pins; 1001 and 1000 are tamed and not favorites
	assert(count == 2, "expected 2 world pins, got " .. count)
	BC.SetFavorite(1000, true)
	count = 0
	for _, f in ipairs(allFrames) do if f.__parent == pinLayer and f.__shown and rawget(f, "display") then count = count + 1 end end
	assert(count == 3, "favorite pin missing, got " .. count)
	WorldMapFrame:Hide()
end)

step("the options menu turns immersive mode off", function ()
	local button = find(function (f) return f.__kind == "Button" and f.__text == "Filters" end)
	button.__scripts.OnClick(button)
	local item
	for _, i in ipairs(menuItems) do if i.text == "Hide beasts I haven't found" then item = i end end
	assert(item and item.checked, "immersive option missing or off")
	item.func()
	assert(not BC.Immersive(), "immersive still on")
	BC.SetSetting("immersive", true)
end)

step("a new look arrives", function ()
	BC.SelectTab(2)
	fire("CHAT_MSG_ADDON", "BCOL", "NEW:1002:3:1", "WHISPER", "Tester")
	assert(BC.owned[1002], "new look not marked")
	assert(findText("Found: |cffffffff3|r / 3   Tamed: |cffffffff3|r / 3"), "progress not updated")
	assert(findText("Old Greyjaw"), "new look not selected")
end)

step("rewards tab", function ()
	BC.SelectTab(3)
	tick(1.5)
	assert(findText("3/10"), "reward progress missing")
	assert(findText("Cat Carrier (Siamese)"), "reward item missing")
end)

step("second session uses the cached catalog", function ()
	local saved = BeastCollectionDB
	local before = catalogRequests
	BC.catalogReady = false
	fire("CHAT_MSG_ADDON", "BCOL", "HELLO:1:4242:3:1:10000:15:1", "WHISPER", "Tester")
	assert(BC.catalogReady, "cached catalog not used")
	BC.Refresh()
	tick(0.5)
	assert(catalogRequests == before, "catalog asked for again")
	assert(saved.catalogs["Test Realm"].hash == "4242", "cache not keyed by realm")
	assert(#BC.families[1].abilities == 3, "abilities not cached")
end)

step("protocol mismatch stops it", function ()
	fire("CHAT_MSG_ADDON", "BCOL", "HELLO:2:1:0:0:0:0:1", "WHISPER", "Tester")
	assert(BC.server.mismatch, "mismatch not detected")
end)

print(errors == 0 and "ALL OK" or (errors .. " ERROR(S)"))
os.exit(errors == 0 and 0 or 1)
