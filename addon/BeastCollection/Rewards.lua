-- The Rewards tab: the dex milestones, how far along the account is, and what each one gives.

local BC = BeastCollection

local panel = BC.AddTab("Rewards")

local TYPE_LOOKS, TYPE_SHINY, TYPE_FAMILY = 0, 1, 2

local function moneyText(copper)
	if not copper or copper <= 0 then return nil end
	local gold = math.floor(copper / 10000)
	local silver = math.floor(copper / 100) % 100
	if gold > 0 then return gold .. "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t" end
	return silver .. "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
end

local function itemName(id)
	if not id or id == 0 then return nil end
	local name, _, quality = GetItemInfo(id)
	if not name then return "item " .. id end
	local _, _, _, hex = GetItemQualityColor(quality or 1)
	return (hex or "|cffffffff") .. name .. "|r"
end

local function progress(reward)
	local normal, shiny, byFamily = BC.Counts()
	if reward.type == TYPE_LOOKS then
		return normal, reward.count
	elseif reward.type == TYPE_SHINY then
		return shiny, reward.count
	elseif reward.type == TYPE_FAMILY then
		if reward.family ~= 0 then
			local f = BC.families[reward.family]
			return byFamily[reward.family] or 0, f and f.normal or 0
		end
		local done, total = 0, 0
		for _, f in ipairs(BC.familyList) do
			if f.normal > 0 then
				total = total + 1
				if (byFamily[f.id] or 0) >= f.normal then done = done + 1 end
			end
		end
		return done, total
	end
	return 0, 0
end

local pane = BC.CreateInset(panel)
pane:SetAllPoints(panel)

local list = BC.CreateList(pane, {
	rows = 20,
	rowHeight = 20,
	columns = {
		{ title = "Milestone", text = function (r)
			local text = r.text ~= "" and r.text or "Milestone"
			if r.type == TYPE_FAMILY and r.family ~= 0 then text = text .. ": " .. BC.FamilyName(r.family) end
			if r.type == TYPE_FAMILY and r.family == 0 then text = text .. " (each family)" end
			return text
		end },
		{ title = "Progress", width = 90, align = "CENTER", text = function (r)
			local have, need = progress(r)
			if need > 0 and have >= need then return string.format("|cff40ff40%d/%d|r", have, need) end
			return string.format("%d/%d", have, need)
		end },
		{ title = "Reward", width = 260, text = function (r)
			local parts = {}
			local item = itemName(r.item)
			if item then table.insert(parts, item) end
			local money = moneyText(r.money)
			if money then table.insert(parts, money) end
			if #parts == 0 then return "|cff909090-|r" end
			return table.concat(parts, " + ")
		end },
		{ title = "", width = 110, align = "CENTER", text = function (r)
			if r.type == TYPE_FAMILY and r.family == 0 then
				return r.claimed > 0 and string.format("|cff40ff40%d claimed|r", r.claimed) or ""
			end
			return r.claimed > 0 and "|cff40ff40Claimed|r" or ""
		end },
	},
	empty = "No rewards on this realm.",
	tooltip = function (r, tip)
		if r.item and r.item > 0 then
			tip:SetHyperlink("item:" .. r.item)
		else
			tip:AddLine(r.text)
		end
	end,
})
list:SetPoint("TOPLEFT", pane, "TOPLEFT", 6, -6)
list:SetPoint("RIGHT", pane, "RIGHT", -4, 0)

local note = BC.CreateLabel(pane, "Milestones count looks across every hunter on your account. Rewards arrive by mail.", "GameFontDisableSmall")
note:SetPoint("BOTTOM", pane, "BOTTOM", 0, 10)

local function refresh()
	list:SetItems(BC.rewards, true)
end

BC.On("REWARDS", refresh)
BC.On("DEX", refresh)
BC.On("CATALOG", refresh)
-- Item names come in from the server a moment after they're first asked for.
panel:SetScript("OnShow", function ()
	refresh()
	BC.After(1, refresh)
end)
