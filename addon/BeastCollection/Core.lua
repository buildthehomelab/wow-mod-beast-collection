-- BeastCollection core: the server protocol, the collection's data, timers and slash commands.
-- The window itself is built in Frame.lua and the tab files.

BeastCollection = BeastCollection or {}
local BC = BeastCollection

BC.PREFIX = "BCOL"
BC.PROTOCOL = 1

-- Look flags (src/BeastCollection.h, Catalog::LookFlags)
BC.LOOK_EXOTIC = 1
BC.LOOK_SHINY = 2
BC.LOOK_RARE = 4

-- Pet flags (src/BeastBox.cpp)
BC.PET_ACTIVE = 1
BC.PET_STABLE = 2
BC.PET_BOX = 4
BC.PET_DEAD = 8
BC.PET_SHINY = 16
BC.PET_EXOTIC = 32
BC.PET_DISMISSED = 64

-- Server feature flags (HELLO)
BC.FEATURE_BOX = 1
BC.FEATURE_SHINY = 2
BC.FEATURE_REWARDS = 4
BC.FEATURE_DISCOVERY = 8

-- How much the account knows about a look (field guide)
BC.KNOW_NONE = 0
BC.KNOW_FOUND = 1     -- targeted one
BC.KNOW_STUDIED = 2   -- cast Beast Lore on one
BC.KNOW_TAMED = 3

-- What the server knows: catalog, the account's dex, this character's pets, the rewards.
BC.families = {}      -- id -> { id, name, exotic, normal, shiny, talent, food, abilities }
BC.familyList = {}
BC.looks = {}         -- display -> { display, family, flags, entry, minLevel, maxLevel, name, zones, spells }
BC.lookList = {}
BC.owned = {}         -- display -> true
BC.seen = {}          -- display -> KNOW_FOUND / KNOW_STUDIED
BC.pets = {}
BC.rewards = {}
BC.maps = {}          -- display -> { { id, name, pins = { {x, y}, ... } }, ... } (spawn maps, asked for one by one)
BC.zonePins = {}      -- lower-case zone name -> { id, pins = { {display, x, y}, ... } }
BC.catalogReady = false

local bit_band = bit.band

function BC.Has(flags, flag)
	return bit_band(flags or 0, flag) ~= 0
end

-----------------------------------------
-- tiny event bus, so tabs can react to each other without knowing about each other

local listeners = {}

function BC.On(event, fn)
	listeners[event] = listeners[event] or {}
	table.insert(listeners[event], fn)
end

function BC.Fire(event, ...)
	local list = listeners[event]
	if not list then return end
	for i = 1, #list do list[i](...) end
end

-----------------------------------------
-- timers (3.3.5a has no C_Timer)

local timerFrame = CreateFrame("Frame")
local timers = {}

function BC.After(delay, fn)
	table.insert(timers, { at = GetTime() + delay, fn = fn })
	timerFrame:Show()
end

timerFrame:SetScript("OnUpdate", function (self)
	local now = GetTime()
	local i = 1
	while i <= #timers do
		if timers[i].at <= now then
			local t = table.remove(timers, i)
			t.fn()
		else
			i = i + 1
		end
	end
	if #timers == 0 then self:Hide() end
end)

-----------------------------------------
-- formatting

function BC.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffb48c4bBeast Collection:|r " .. msg)
end

-- Hunter pet family icons (CreatureFamily.dbc ids).
local FAMILY_ICONS = {
	[1] = "Ability_Hunter_Pet_Wolf", [2] = "Ability_Hunter_Pet_Cat", [3] = "Ability_Hunter_Pet_Spider",
	[4] = "Ability_Hunter_Pet_Bear", [5] = "Ability_Hunter_Pet_Boar", [6] = "Ability_Hunter_Pet_Crocolisk",
	[7] = "Ability_Hunter_Pet_Vulture", [8] = "Ability_Hunter_Pet_Crab", [9] = "Ability_Hunter_Pet_Gorilla",
	[11] = "Ability_Hunter_Pet_Raptor", [12] = "Ability_Hunter_Pet_TallStrider", [20] = "Ability_Hunter_Pet_Scorpid",
	[21] = "Ability_Hunter_Pet_Turtle", [24] = "Ability_Hunter_Pet_Bat", [25] = "Ability_Hunter_Pet_Hyena",
	[26] = "Ability_Hunter_Pet_Owl", [27] = "Ability_Hunter_Pet_WindSerpent", [30] = "Ability_Hunter_Pet_DragonHawk",
	[31] = "Ability_Hunter_Pet_Ravager", [32] = "Ability_Hunter_Pet_WarpStalker", [33] = "Ability_Hunter_Pet_Sporebat",
	[34] = "Ability_Hunter_Pet_NetherRay", [35] = "Spell_Nature_GuardianWard", [37] = "Ability_Hunter_Pet_Moth",
	[38] = "Ability_Hunter_Pet_Chimera", [39] = "Ability_Hunter_Pet_Devilsaur", [41] = "Ability_Hunter_Pet_Silithid",
	[42] = "Ability_Hunter_Pet_Worm", [43] = "Ability_Hunter_Pet_Rhino", [44] = "Ability_Hunter_Pet_Wasp",
	[45] = "Ability_Hunter_Pet_CoreHound", [46] = "Ability_Druid_PrimalPrecision",
}

function BC.FamilyIcon(family)
	return "Interface\\Icons\\" .. (FAMILY_ICONS[family] or "Ability_Hunter_BeastTaming")
end

function BC.FamilyName(family)
	local f = BC.families[family]
	return f and f.name or "?"
end

BC.SHINY_STAR = "|TInterface\\Common\\ReputationStar:12:12:0:0:32:32:0:16:0:16|t"

function BC.LevelRange(minLevel, maxLevel)
	if not minLevel or minLevel == 0 then return "" end
	if maxLevel and maxLevel > minLevel then return minLevel .. "-" .. maxLevel end
	return tostring(minLevel)
end

-----------------------------------------
-- counts

-- Tamed, studied, found or nothing.
function BC.Knowledge(display)
	if BC.owned[display] then return BC.KNOW_TAMED end
	return BC.seen[display] or BC.KNOW_NONE
end

-- Immersive mode: looks stay hidden until the account finds them. Only when the server keeps
-- finds; otherwise nothing could ever be revealed.
function BC.Immersive()
	return BC.Setting("immersive") and BC.server and BC.Has(BC.server.flags, BC.FEATURE_DISCOVERY)
end

function BC.Revealed(look)
	return not BC.Immersive() or BC.Knowledge(look.display) > BC.KNOW_NONE
end

-- Beast Lore (or taming) shows what a beast casts; reveal-all mode shows it anyway.
function BC.Studied(look)
	return not BC.Immersive() or BC.Knowledge(look.display) >= BC.KNOW_STUDIED
end

function BC.IsFavorite(display)
	return BeastCollectionDB and BeastCollectionDB.favorites and BeastCollectionDB.favorites[display] or false
end

function BC.SetFavorite(display, on)
	BeastCollectionDB.favorites = BeastCollectionDB.favorites or {}
	BeastCollectionDB.favorites[display] = on and true or nil
	BC.Fire("FAVORITES")
end

-----------------------------------------
-- settings (BeastCollectionDB.settings)

local DEFAULTS = {
	immersive = true,   -- hide beasts the account hasn't found
	worldPins = true,   -- beasts on the world map
	record = true,      -- report beasts we target or point at
}

function BC.Setting(key)
	local settings = BeastCollectionDB and BeastCollectionDB.settings
	local value = settings and settings[key]
	if value == nil then return DEFAULTS[key] end
	return value
end

function BC.SetSetting(key, value)
	BeastCollectionDB.settings = BeastCollectionDB.settings or {}
	BeastCollectionDB.settings[key] = value
	BC.Fire("SETTINGS", key)
end

-- normal, shiny, and normal looks per family the account has.
function BC.Counts()
	local normal, shiny, byFamily = 0, 0, {}
	for display in pairs(BC.owned) do
		local look = BC.looks[display]
		if look then
			if BC.Has(look.flags, BC.LOOK_SHINY) then
				shiny = shiny + 1
			else
				normal = normal + 1
				byFamily[look.family] = (byFamily[look.family] or 0) + 1
			end
		end
	end
	return normal, shiny, byFamily
end

-- Normal looks found (incl. studied and tamed), studied (incl. tamed), and found per family.
function BC.FoundCounts()
	local found, studied, byFamily = 0, 0, {}
	for _, look in ipairs(BC.lookList) do
		if not BC.Has(look.flags, BC.LOOK_SHINY) then
			local know = BC.Knowledge(look.display)
			if know >= BC.KNOW_FOUND then
				found = found + 1
				byFamily[look.family] = (byFamily[look.family] or 0) + 1
			end
			if know >= BC.KNOW_STUDIED then studied = studied + 1 end
		end
	end
	return found, studied, byFamily
end

-----------------------------------------
-- the protocol: addon whispers to ourselves; the server answers the same way

function BC.Send(command)
	SendAddonMessage(BC.PREFIX, command, "WHISPER", UnitName("player"))
end

local function split(text, sep)
	local out = {}
	if not text or text == "" then return out end
	local start = 1
	while true do
		local i = string.find(text, sep, start, true)
		if not i then
			table.insert(out, string.sub(text, start))
			break
		end
		table.insert(out, string.sub(text, start, i - 1))
		start = i + 1
	end
	return out
end
BC.Split = split

local function eachRow(body, fn)
	for _, row in ipairs(split(body, ";")) do
		if row ~= "" then fn(split(row, ",")) end
	end
end

local pending = { F = {}, A = {}, C = {}, P = {}, O = {}, R = {}, S = {} }
local pendingMaps, pendingZones = {}, {}

local function realmCache()
	BeastCollectionDB.catalogs = BeastCollectionDB.catalogs or {}
	local realm = GetRealmName() or "?"
	return BeastCollectionDB.catalogs, realm
end

local function buildCatalog(familyRows, lookRows, abilityRows)
	wipe(BC.families)
	wipe(BC.familyList)
	wipe(BC.looks)
	wipe(BC.lookList)
	for _, f in ipairs(familyRows) do
		local family = {
			id = tonumber(f[1]), name = f[2] or "?", exotic = f[3] == "1",
			normal = tonumber(f[4]) or 0, shiny = tonumber(f[5]) or 0,
			talent = tonumber(f[6]) or -1, food = tonumber(f[7]) or 0, abilities = {},
		}
		if family.id then
			BC.families[family.id] = family
			table.insert(BC.familyList, family)
		end
	end
	table.sort(BC.familyList, function (a, b) return a.name < b.name end)
	-- "<family>,<spell>-<pet level>/<spell>-<pet level>...": one ability, its ranks in order
	for _, a in ipairs(abilityRows or {}) do
		local family = BC.families[tonumber(a[1]) or 0]
		if family and a[2] then
			local ranks = {}
			for _, rank in ipairs(split(a[2], "/")) do
				local spell, level = string.match(rank, "^(%d+)-(%d+)$")
				if spell then table.insert(ranks, { spell = tonumber(spell), level = tonumber(level) }) end
			end
			if #ranks > 0 then table.insert(family.abilities, ranks) end
		end
	end
	for i, l in ipairs(lookRows) do
		local look = {
			display = tonumber(l[1]), family = tonumber(l[2]) or 0, flags = tonumber(l[3]) or 0,
			entry = tonumber(l[4]) or 0, minLevel = tonumber(l[5]) or 0, maxLevel = tonumber(l[6]) or 0,
			name = l[7] or "?", zones = l[8] or "", spells = {}, order = i,
		}
		for _, spell in ipairs(split(l[9] or "", "/")) do
			if tonumber(spell) then table.insert(look.spells, tonumber(spell)) end
		end
		if look.display then
			BC.looks[look.display] = look
			table.insert(BC.lookList, look)
		end
	end
	BC.catalogReady = true
	BC.Fire("CATALOG")
end

local ERRORS = {
	dead = "You are dead.",
	combat = "Not while in combat.",
	mounted = "Dismount first.",
	arena = "Not in an arena.",
	instance = "Not inside an instance.",
	charm = "You are controlling something else.",
	active = "That beast is already at your side.",
	notfound = "That beast isn't in your collection any more.",
	exotic = "Only Beast Mastery hunters can control exotic beasts.",
	nottameable = "That beast can't be controlled.",
	full = "Your beast box is full.",
	failed = "The beast didn't come. Try again.",
	class = "Only hunters keep beasts.",
	disabled = "The beast box is turned off on this realm.",
	unknown = "The server didn't understand that. Update the addon?",
	notready = "The server is still starting up.",
}

function BC.ErrorText(reason)
	local what, ms = string.match(reason or "", "^(%w+),?(%d*)$")
	if what == "cooldown" then
		return string.format("You can call another beast in %d sec.", math.ceil((tonumber(ms) or 0) / 1000))
	end
	return ERRORS[what or ""] or reason or "?"
end

local handlers = {}

handlers.HELLO = function (args)
	local parts = split(args, ":")
	local protocol = tonumber(parts[1])
	BC.server = {
		protocol = protocol, hash = parts[2], normalTotal = tonumber(parts[3]) or 0,
		shinyTotal = tonumber(parts[4]) or 0, swapCooldown = tonumber(parts[5]) or 0,
		flags = tonumber(parts[6]) or 0, hunter = parts[7] == "1",
	}
	if protocol ~= BC.PROTOCOL then
		BC.server.mismatch = true
		BC.Print("this addon doesn't match the server (protocol " .. tostring(protocol) .. ", addon " .. BC.PROTOCOL .. "). Update it.")
		return
	end
	local cache, realm = realmCache()
	local cached = cache[realm]
	if cached and cached.hash == BC.server.hash then
		buildCatalog(cached.families, cached.looks, cached.abilities)
	end
	BC.Fire("HELLO")
end

handlers.OFF = function ()
	BC.server = { off = true }
	BC.Fire("HELLO")
end

handlers.F = function (body) eachRow(body, function (row) table.insert(pending.F, row) end) end
handlers.A = function (body) eachRow(body, function (row) table.insert(pending.A, row) end) end
handlers.C = function (body) eachRow(body, function (row) table.insert(pending.C, row) end) end

handlers.CE = function (args)
	local hash = split(args, ":")[1]
	local cache, realm = realmCache()
	cache[realm] = { hash = hash, families = pending.F, looks = pending.C, abilities = pending.A }
	buildCatalog(pending.F, pending.C, pending.A)
	pending.F, pending.C, pending.A = {}, {}, {}
end

handlers.O = function (body)
	for _, display in ipairs(split(body, ";")) do
		local n = tonumber(display)
		if n then table.insert(pending.O, n) end
	end
end

handlers.OE = function ()
	wipe(BC.owned)
	for _, display in ipairs(pending.O) do BC.owned[display] = true end
	pending.O = {}
	BC.Fire("DEX")
end

handlers.R = function (body) eachRow(body, function (row) table.insert(pending.R, row) end) end

handlers.S = function (body) eachRow(body, function (row) table.insert(pending.S, row) end) end

handlers.SE = function ()
	wipe(BC.seen)
	for _, row in ipairs(pending.S) do
		local display, level = tonumber(row[1]), tonumber(row[2])
		if display and level then BC.seen[display] = level end
	end
	pending.S = {}
	BC.Fire("DEX")
end

-- SEEN:<display>:<level>:<found>: a look found or studied just now.
handlers.SEEN = function (args)
	local parts = split(args, ":")
	local display, level = tonumber(parts[1]), tonumber(parts[2])
	if not display or not level then return end
	if (BC.seen[display] or 0) < level then BC.seen[display] = level end
	BC.Fire("DEX")
	BC.Fire("SEEN", display, level)
end

-- Spawn maps. MZ:<display>:<zone>,<name>,<pins>;...  MP:<display>:<zone>,<x>,<y>;...  ME:<display>
local function pendingMap(display)
	pendingMaps[display] = pendingMaps[display] or { zones = {}, byId = {} }
	return pendingMaps[display]
end

handlers.MZ = function (args)
	local display, body = string.match(args, "^(%d+):(.*)$")
	if not display then return end
	local map = pendingMap(tonumber(display))
	eachRow(body, function (row)
		local zone = { id = tonumber(row[1]) or 0, name = row[2] or "?", pins = {} }
		table.insert(map.zones, zone)
		map.byId[zone.id] = zone
	end)
end

handlers.MP = function (args)
	local display, body = string.match(args, "^(%d+):(.*)$")
	if not display then return end
	local map = pendingMap(tonumber(display))
	eachRow(body, function (row)
		local zone = map.byId[tonumber(row[1]) or 0]
		local x, y = tonumber(row[2]), tonumber(row[3])
		if zone and x and y then table.insert(zone.pins, { x / 10, y / 10 }) end
	end)
end

handlers.ME = function (args)
	local display = tonumber(split(args, ":")[1])
	if not display then return end
	BC.maps[display] = (pendingMaps[display] or { zones = {} }).zones
	pendingMaps[display] = nil
	BC.Fire("MAP", display)
end

-- Every look's spawns in one zone. ZP:<zone>:<display>,<x>,<y>;...  ZE:<zone>:<pins>:<name>
handlers.ZP = function (args)
	local zone, body = string.match(args, "^(%d+):(.*)$")
	if not zone then return end
	local pins = pendingZones[zone] or {}
	pendingZones[zone] = pins
	eachRow(body, function (row)
		local display, x, y = tonumber(row[1]), tonumber(row[2]), tonumber(row[3])
		if display and x and y then table.insert(pins, { display, x / 10, y / 10 }) end
	end)
end

handlers.ZE = function (args)
	local zone, name = string.match(args, "^(%d+):%d+:(.*)$")
	if not zone then return end
	BC.zonePins[string.lower(name)] = { id = tonumber(zone), pins = pendingZones[zone] or {} }
	pendingZones[zone] = nil
	BC.Fire("ZONE", name)
end

handlers.RE = function ()
	wipe(BC.rewards)
	for i, r in ipairs(pending.R) do
		table.insert(BC.rewards, {
			id = tonumber(r[1]), type = tonumber(r[2]) or 0, count = tonumber(r[3]) or 0,
			family = tonumber(r[4]) or 0, claimed = tonumber(r[5]) or 0, item = tonumber(r[6]) or 0,
			money = tonumber(r[7]) or 0, text = r[8] or "", order = i,
		})
	end
	pending.R = {}
	BC.Fire("REWARDS")
end

handlers.P = function (body) eachRow(body, function (row) table.insert(pending.P, row) end) end

handlers.PE = function (args)
	local parts = split(args, ":")
	wipe(BC.pets)
	for i, p in ipairs(pending.P) do
		table.insert(BC.pets, {
			id = tonumber(p[1]), entry = tonumber(p[2]) or 0, display = tonumber(p[3]) or 0,
			level = tonumber(p[4]) or 0, flags = tonumber(p[5]) or 0, family = tonumber(p[6]) or 0,
			name = p[7] or "?", order = i,
		})
	end
	pending.P = {}
	BC.cooldownEnds = GetTime() + (tonumber(parts[2]) or 0) / 1000
	BC.boxCount = tonumber(parts[3]) or 0
	BC.boxMax = tonumber(parts[4]) or 0
	BC.Fire("PETS")
end

handlers.NEW = function (args)
	local display = tonumber(split(args, ":")[1])
	if display then BC.owned[display] = true end
	PlaySoundFile("Sound\\Interface\\LevelUp.wav")
	BC.Fire("DEX")
	BC.Fire("NEW", display)
end

handlers.REWARD = function ()
	-- the server says it in chat; refresh the rewards tab
	BC.Send("DEX")
end

handlers.OK = function (args)
	local command = split(args, ":")[1]
	BC.Fire("OK", command)
end

handlers.ERR = function (args)
	local parts = split(args, ":")
	local command = parts[1]
	local reason = table.concat(parts, ":", 2)
	BC.Fire("ERR", command, reason)
	if command == "CALL" or command == "STORE" or command == "FREE" then
		UIErrorsFrame:AddMessage(BC.ErrorText(reason), 1, 0.1, 0.1)
	end
end

local function onMessage(message)
	local header, rest = string.match(message, "^(%u+):?(.*)$")
	local fn = header and handlers[header]
	if fn then fn(rest or "") end
end

-----------------------------------------
-- asking

-- Everything the window shows; the catalog only when there's no cached copy of it.
function BC.Refresh()
	if not BC.server then
		BC.Send("H")
		return
	end
	if BC.server.mismatch or BC.server.off then return end
	if not BC.catalogReady then BC.Send("CAT") end
	BC.Send("DEX")
	BC.Send("PETS")
end

function BC.Call(pet)
	BC.Send("CALL:" .. pet.id)
end

function BC.Store(pet)
	BC.Send("STORE:" .. pet.id)
end

function BC.Release(pet)
	BC.Send("FREE:" .. pet.id)
end

local mapAsked, zoneAsked = {}, {}

-- A look's spawn map; MAP fires when it's there.
function BC.RequestMap(display)
	if BC.maps[display] or mapAsked[display] or not BC.server or BC.server.mismatch or BC.server.off then return end
	mapAsked[display] = true
	BC.Send("MAP:" .. display)
end

-- Every beast's spawns in a zone, by the name the world map gives it; ZONE fires when it's there.
function BC.RequestZone(name)
	local key = string.lower(name or "")
	if key == "" or BC.zonePins[key] or zoneAsked[key] or not BC.server or BC.server.mismatch or BC.server.off then return end
	zoneAsked[key] = true
	BC.Send("ZONE:" .. name)
end

-----------------------------------------
-- the field guide: tell the server about tameable-looking beasts we target or point at; it
-- checks the creature really is there and tameable

local reported = {}

local function report(unit)
	local server = BC.server
	if not server or not server.hunter or server.mismatch or server.off or not BC.Has(server.flags, BC.FEATURE_DISCOVERY) then return end
	if not BC.Setting("record") then return end
	if not UnitExists(unit) or UnitIsPlayer(unit) or UnitPlayerControlled(unit) or not UnitCreatureFamily(unit) then return end
	local guid = UnitGUID(unit)
	if not guid or reported[guid] then return end
	reported[guid] = true
	BC.Send("SEE:" .. guid)
end

-----------------------------------------
-- events

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
events:SetScript("OnEvent", function (self, event, a1, a2, a3, a4)
	if event == "ADDON_LOADED" and a1 == "BeastCollection" then
		BeastCollectionDB = BeastCollectionDB or {}
	elseif event == "PLAYER_LOGIN" then
		-- Let the world settle before the first whisper.
		BC.After(4, function () BC.Send("H") end)
	elseif event == "CHAT_MSG_ADDON" then
		if a1 == BC.PREFIX and a3 == "WHISPER" and a4 == UnitName("player") then
			onMessage(a2)
		end
	elseif event == "PLAYER_TARGET_CHANGED" then
		report("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		report("mouseover")
	end
end)

BC.On("HELLO", function ()
	if BC.frame and BC.frame:IsShown() then BC.Refresh() end
end)

function BC.Toggle()
	if not BC.frame then return end
	if BC.frame:IsShown() then BC.frame:Hide() else BC.frame:Show() end
end

-- Opens the window on the Field Guide tab, at a look if one is given.
function BC.ShowLook(display)
	if not BC.frame then return end
	BC.frame:Show()
	if BC.dexTab then BC.SelectTab(BC.dexTab) end
	if display then BC.Fire("SHOW_LOOK", display) end
end

SLASH_BEASTCOLLECTION1 = "/beasts"
SLASH_BEASTCOLLECTION2 = "/beastcollection"
SLASH_BEASTCOLLECTION3 = "/fieldguide"
SlashCmdList["BEASTCOLLECTION"] = function (msg)
	msg = string.lower(msg or "")
	if msg == "guide" or msg == "dex" then
		BC.ShowLook()
		return
	end
	if msg == "reset" then
		BeastCollectionDB.position = nil
		BeastCollectionDB.catalogs = nil
		BC.catalogReady = false
		BC.Print("window position and cached beast list reset.")
		return
	end
	BC.Toggle()
end

BINDING_HEADER_BEASTCOLLECTION = "Beast Collection"
BINDING_NAME_BEASTCOLLECTION_TOGGLE = "Toggle Beast Collection"
