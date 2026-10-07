-- The Beasts tab: this hunter's pets, at their side, in the stable and in the box. Pick one and
-- call it, send it to the box, or release a boxed one.

local BC = BeastCollection

local panel = BC.AddTab("Beasts")

local selectedId
local search = ""

local function where(pet)
	if BC.Has(pet.flags, BC.PET_DISMISSED) then return 2, "|cff9acd32Dismissed|r" end
	if BC.Has(pet.flags, BC.PET_ACTIVE) then return 1, "|cff40ff40With you|r" end
	if BC.Has(pet.flags, BC.PET_STABLE) then return 3, "|cffffd100Stable|r" end
	return 4, "|cffc0c0c0Box|r"
end

local function selectedPet()
	for _, pet in ipairs(BC.pets) do
		if pet.id == selectedId then return pet end
	end
end

local function lookOf(pet)
	return BC.looks[pet.display]
end

-----------------------------------------
-- left: search and the list

local searchBox = BC.CreateEditBox(panel, 220)
searchBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -6)
local searchLabel = BC.CreateLabel(panel, "Search", "GameFontDisableSmall")
searchLabel:SetPoint("LEFT", searchBox, "LEFT", 4, 0)

local counter = BC.CreateLabel(panel, "", "GameFontHighlightSmall")
counter:SetPoint("LEFT", searchBox, "RIGHT", 14, 0)

local listPane = BC.CreateInset(panel)
listPane:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -30)
listPane:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
listPane:SetWidth(450)

local list
local refreshList

list = BC.CreateList(listPane, {
	rows = 22,
	rowHeight = 20,
	columns = {
		{ title = NAME, icon = function (pet) return BC.FamilyIcon(pet.family) end,
		  desaturate = function (pet) return BC.Has(pet.flags, BC.PET_DEAD) end,
		  text = function (pet)
			local name = pet.name
			if BC.Has(pet.flags, BC.PET_SHINY) then name = name .. " " .. BC.SHINY_STAR end
			if BC.Has(pet.flags, BC.PET_DEAD) then name = "|cff808080" .. name .. "|r" end
			return name
		  end,
		  sort = function (pet) return string.lower(pet.name) end },
		{ title = LEVEL_ABBR or "Lvl", width = 44, align = "CENTER",
		  text = function (pet) return pet.level end,
		  sort = function (pet) return pet.level end, defaultDesc = true },
		{ title = "Family", width = 110,
		  text = function (pet) return BC.FamilyName(pet.family) end,
		  sort = function (pet) return BC.FamilyName(pet.family) end },
		{ title = "Where", width = 84,
		  text = function (pet) local _, text = where(pet); return text end,
		  sort = function (pet) return (where(pet)) end },
	},
	defaultSort = 4,
	empty = "No beasts yet. Tame one!",
	isSelected = function (pet) return pet.id == selectedId end,
	onClick = function (pet)
		selectedId = pet.id
		BC.Fire("PET_SELECTED")
	end,
	onDoubleClick = function (pet)
		if not BC.Has(pet.flags, BC.PET_ACTIVE) or BC.Has(pet.flags, BC.PET_DISMISSED) then BC.Call(pet) end
	end,
	tooltip = function (pet, tip)
		tip:AddLine(pet.name)
		tip:AddLine(string.format("Level %d %s", pet.level, BC.FamilyName(pet.family)), 1, 1, 1)
		local look = lookOf(pet)
		if look then tip:AddLine("Look: " .. look.name, 0.7, 0.7, 0.7) end
		if BC.Has(pet.flags, BC.PET_SHINY) then tip:AddLine(BC.SHINY_STAR .. " Shiny", 1, 0.5, 1) end
		tip:AddLine("Double-click to call.", 0.5, 0.8, 1)
	end,
})
list:SetPoint("TOPLEFT", listPane, "TOPLEFT", 6, -6)
list:SetPoint("RIGHT", listPane, "RIGHT", -4, 0)

function refreshList()
	local items = {}
	for _, pet in ipairs(BC.pets) do
		local hay = string.lower(pet.name .. " " .. BC.FamilyName(pet.family))
		if search == "" or string.find(hay, search, 1, true) then
			table.insert(items, pet)
		end
	end
	list:SetItems(items, true)

	local boxText = BC.boxMax and BC.boxMax > 0 and (BC.boxCount .. "/" .. BC.boxMax) or tostring(BC.boxCount or 0)
	counter:SetText(string.format("%d beasts, %s in the box", #BC.pets, boxText))
end

searchBox:SetScript("OnTextChanged", function (self)
	search = string.lower(self:GetText() or "")
	if search == "" then searchLabel:Show() else searchLabel:Hide() end
	refreshList()
end)
searchBox:SetScript("OnEditFocusGained", function () searchLabel:Hide() end)
searchBox:SetScript("OnEditFocusLost", function (self) if self:GetText() == "" then searchLabel:Show() end end)

-----------------------------------------
-- right: the selected beast

local detail = BC.CreateInset(panel)
detail:SetPoint("TOPLEFT", listPane, "TOPRIGHT", 8, 30)
detail:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

local model = BC.CreateModel(detail)
model:SetPoint("TOPLEFT", detail, "TOPLEFT", 6, -6)
model:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -6, -6)
model:SetHeight(250)

local nameText = BC.CreateLabel(detail, "", "GameFontNormalLarge")
nameText:SetPoint("TOP", model, "BOTTOM", 0, -8)

local infoText = BC.CreateLabel(detail, "", "GameFontHighlight")
infoText:SetPoint("TOP", nameText, "BOTTOM", 0, -6)

local whereText = BC.CreateLabel(detail, "", "GameFontHighlightSmall")
whereText:SetPoint("TOP", infoText, "BOTTOM", 0, -6)

local notesText = BC.CreateLabel(detail, "", "GameFontDisableSmall")
notesText:SetPoint("TOP", whereText, "BOTTOM", 0, -6)
notesText:SetWidth(300)

local callButton = BC.CreateButton(detail, "Call", 96, 24)
local storeButton = BC.CreateButton(detail, "To Box", 96, 24)
local releaseButton = BC.CreateButton(detail, "Release", 96, 24)
storeButton:SetPoint("BOTTOM", detail, "BOTTOM", 0, 12)
callButton:SetPoint("RIGHT", storeButton, "LEFT", -6, 0)
releaseButton:SetPoint("LEFT", storeButton, "RIGHT", 6, 0)

local cooldownText = BC.CreateLabel(detail, "", "GameFontDisableSmall")
cooldownText:SetPoint("BOTTOM", storeButton, "TOP", 0, 6)

local noHunter = BC.CreateLabel(panel, "", "GameFontNormal")
noHunter:SetPoint("CENTER", listPane, "CENTER", 0, 0)
noHunter:SetWidth(380)

local function refreshDetail()
	local pet = selectedPet()
	if not pet then
		model:ShowCreature(nil)
		nameText:SetText("")
		infoText:SetText("")
		whereText:SetText("")
		notesText:SetText("Pick a beast on the left.")
		BC.SetEnabled(callButton, false)
		BC.SetEnabled(storeButton, false)
		BC.SetEnabled(releaseButton, false)
		return
	end

	local look = lookOf(pet)
	model:ShowCreature(look and look.entry ~= 0 and look.entry or pet.entry, false)

	local name = pet.name
	if BC.Has(pet.flags, BC.PET_SHINY) then name = BC.SHINY_STAR .. " " .. name .. " " .. BC.SHINY_STAR end
	nameText:SetText(name)
	infoText:SetText(string.format("Level %d %s", pet.level, BC.FamilyName(pet.family)))
	local _, whereLabel = where(pet)
	whereText:SetText(whereLabel)

	local notes = {}
	if look then table.insert(notes, "Look: " .. look.name) end
	if BC.Has(pet.flags, BC.PET_EXOTIC) then table.insert(notes, "|cffff8040Exotic|r") end
	if BC.Has(pet.flags, BC.PET_DEAD) then table.insert(notes, "|cffff4040Dead: revive it after calling.|r") end
	notesText:SetText(table.concat(notes, "\n"))

	local active = BC.Has(pet.flags, BC.PET_ACTIVE) and not BC.Has(pet.flags, BC.PET_DISMISSED)
	local hunter = BC.server and BC.server.hunter
	BC.SetEnabled(callButton, hunter and not active)
	BC.SetEnabled(storeButton, hunter and not BC.Has(pet.flags, BC.PET_BOX))
	BC.SetEnabled(releaseButton, hunter and BC.Has(pet.flags, BC.PET_BOX))
end

callButton:SetScript("OnClick", function ()
	local pet = selectedPet()
	if pet then BC.Call(pet) end
end)

storeButton:SetScript("OnClick", function ()
	local pet = selectedPet()
	if pet then BC.Store(pet) end
end)

releaseButton:SetScript("OnClick", function ()
	local pet = selectedPet()
	if not pet then return end
	BC.Confirm(string.format("Release %s (level %d %s) back into the wild?\nIt will be gone for good.",
		pet.name, pet.level, BC.FamilyName(pet.family)), function () BC.Release(pet) end)
end)

-- The call cooldown, counted down here; the server has the final say.
local ticker = CreateFrame("Frame", nil, panel)
local elapsed = 0
ticker:SetScript("OnUpdate", function (self, dt)
	elapsed = elapsed + dt
	if elapsed < 0.25 then return end
	elapsed = 0
	local left = (BC.cooldownEnds or 0) - GetTime()
	if left > 0 then
		cooldownText:SetText(string.format("Next call in %d sec", math.ceil(left)))
	else
		cooldownText:SetText("")
	end
end)

local function refresh()
	if BC.server and BC.server.off then
		noHunter:SetText("The beast collection is turned off on this realm.")
		noHunter:Show()
	elseif BC.server and not BC.server.hunter then
		noHunter:SetText("Only hunters keep beasts.\nThe Field Guide tab shows every beast your account has found and tamed.")
		noHunter:Show()
	else
		noHunter:Hide()
	end
	if not selectedPet() then
		-- default to the beast at your side
		selectedId = nil
		for _, pet in ipairs(BC.pets) do
			if BC.Has(pet.flags, BC.PET_ACTIVE) then selectedId = pet.id end
		end
	end
	refreshList()
	refreshDetail()
end

BC.On("PETS", refresh)
BC.On("HELLO", refresh)
BC.On("CATALOG", refresh)
BC.On("PET_SELECTED", refreshDetail)

BC.On("OK", function (command)
	if command == "CALL" then
		BC.Status("Your beast is at your side.")
	elseif command == "STORE" then
		BC.Status("Sent to the box.")
	elseif command == "FREE" then
		BC.Status("Released.")
		selectedId = nil
	end
end)

panel:SetScript("OnShow", refresh)
