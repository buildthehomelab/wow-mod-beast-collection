-- ModelView: a creature preview the player can turn, zoom and move, remembered per creature for the
-- whole account. Left drag turns, right drag moves, the wheel zooms, a middle click goes back to the
-- creature's default view.
--
-- Several addons ship this same file. The newest copy loaded serves them all and they share one set
-- of views, so a mount framed in one window keeps that framing in the next. Each addon hands over
-- its saved variables with Bind. Raise VERSION with any change, and copy the file to all of them.
--
--   ModelViewLib.Wire(model, facing)      once, after the model's own OnHide is set
--   ModelViewLib.AddHint(model, inset)    the line that says how, inset leaving room on the right
--   ModelViewLib.BeforeLoad(model)        before SetCreature or ClearModel
--   ModelViewLib.Frame(model, entry)      once the creature has drawn
--
-- Based on DragonUI's core/modelview.lua, Copyright (c) 2026 NeticSoul, MIT License. What it measured
-- on the 3.3.5a client is why this works the way it does:
-- - There is no camera, and GetPosition reads the value from before a reload, so the view is kept here.
-- - SetModelScale zooms. A depth push is a world-space move that slides the subject off centre.
-- - A scale is anchored on the subject's feet, so the height is corrected as it changes.
-- - SetCreature re-fits the model and folds whatever scale it finds into the fit, so a model goes back
--   to neutral before every load and gets its view only after it.
-- - The swap lands several frames after the call returns, so the view is set again for a moment.
-- DragonUI never carries a zoom across a load; it goes back to 1 each time. Doing so rests on its
-- finding that the fold happens inside the SetCreature call, which it only measured at scale 1.
-- If a remembered zoom comes back too small, the fold is later than that: holdSeconds keeps the
-- model neutral a moment longer, at the price of the view popping in. /run ModelViewLib.holdSeconds=0.3

local VERSION = 1

local M = _G.ModelViewLib
if M and M.version >= VERSION then return end
M = M or { views = {} }
M.version = VERSION
_G.ModelViewLib = M

M.HINT = "Drag: turn  Right-drag: move  Wheel: zoom  Middle-click: reset"
M.holdSeconds = M.holdSeconds or 0

-- Half a creature's height in offset units, measured in the client by DragonUI.
local PIVOT = 0.15
-- Lower than DragonUI's 0.5: some retail mounts fill the frame several times over.
local ZOOM_STEP, ZOOM_MIN, ZOOM_MAX = 1.15, 0.1, 4
local MOVE_LIMIT, MOVE_SPEED = 1.5, 0.011
local TURN_SPEED = 0.012
local SETTLE_SECONDS = 1
local DEFAULT_FACING = 0.5

local function clamp(value, low, high)
	if value < low then return low elseif value > high then return high end
	return value
end

local function apply(model)
	local view = M.views[model.mvEntry]
	local zoom = view and view.zoom or 1
	pcall(model.SetModelScale, model, zoom)
	pcall(model.SetPosition, model, 0, view and view.x or 0, (view and view.y or 0) - PIVOT * (zoom - 1))
	pcall(model.SetFacing, model, view and view.facing or model.mvFacing)
end

local function neutral(model)
	model.mvEntry = nil
	model.mvSettle:Hide()
	pcall(model.SetModelScale, model, 1)
	pcall(model.SetPosition, model, 0, 0, 0)
end

-- The subject grows with the zoom while an offset stays worth the same pixels, so the travel needed
-- to reach its edge grows with it.
local function clampMove(view)
	local limit = MOVE_LIMIT * math.max(1, view.zoom)
	view.x = clamp(view.x, -limit, limit)
	view.y = clamp(view.y, -limit, limit)
end

-- The creature's view to change, made on the first change: nothing is kept for one left alone.
local function editable(model)
	local entry = model.mvEntry
	if not entry then return end
	local view = M.views[entry]
	if not view then
		view = { zoom = 1, x = 0, y = 0, facing = model.mvFacing }
		M.views[entry] = view
	end
	view.at = time()
	return view
end

local function cursor(model)
	local scale = model:GetEffectiveScale()
	if not scale or scale <= 0 then scale = 1 end
	local x, y = GetCursorPosition()
	return x / scale, y / scale
end

-- Polled, not ended by OnMouseUp alone: letting go with the cursor off the model never delivers it.
local function dragger(model, button, step)
	local drag = CreateFrame("Frame", nil, model)
	drag:Hide()
	drag:SetScript("OnUpdate", function (self)
		if not IsMouseButtonDown(button) then
			self:Hide()
			return
		end
		local x, y = cursor(model)
		local dx, dy = x - self.x, y - self.y
		self.x, self.y = x, y
		if dx == 0 and dy == 0 then return end
		local view = editable(model)
		if view then
			step(view, dx, dy)
			apply(model)
		end
	end)
	return drag
end

function M.Wire(model, facing)
	if model.mvWired then return end
	model.mvWired = true
	model.mvFacing = facing or DEFAULT_FACING

	local settle = CreateFrame("Frame", nil, model)
	settle:Hide()
	settle:SetScript("OnUpdate", function (self, elapsed)
		self.left = self.left - elapsed
		if self.held > 0 then self.held = self.held - elapsed end
		if self.held <= 0 and model.mvEntry then apply(model) end
		if self.left <= 0 then self:Hide() end
	end)
	model.mvSettle = settle

	local turner = dragger(model, "LeftButton", function (view, dx)
		view.facing = view.facing + dx * TURN_SPEED
	end)
	local mover = dragger(model, "RightButton", function (view, dx, dy)
		view.x = view.x + dx * MOVE_SPEED
		view.y = view.y + dy * MOVE_SPEED
		clampMove(view)
	end)

	model:EnableMouse(true)
	model:EnableMouseWheel(true)
	model:SetScript("OnMouseDown", function (self, button)
		if button == "LeftButton" then
			turner.x, turner.y = cursor(self)
			turner:Show()
		elseif button == "RightButton" then
			mover.x, mover.y = cursor(self)
			mover:Show()
		elseif button == "MiddleButton" and self.mvEntry then
			M.views[self.mvEntry] = nil
			apply(self)
		end
	end)
	model:SetScript("OnMouseUp", function (_, button)
		if button == "LeftButton" then turner:Hide() end
		if button == "RightButton" then mover:Hide() end
	end)
	model:SetScript("OnMouseWheel", function (self, delta)
		local view = editable(self)
		if view then
			view.zoom = clamp(view.zoom * ZOOM_STEP ^ delta, ZOOM_MIN, ZOOM_MAX)
			clampMove(view)
			apply(self)
		end
	end)
	-- A hidden model is loaded again when it next shows, and has to be neutral for that.
	model:HookScript("OnHide", function (self)
		turner:Hide()
		mover:Hide()
		neutral(self)
	end)
end

function M.AddHint(model, inset)
	local hint = model:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", model, "BOTTOMLEFT", 6, 4)
	hint:SetPoint("BOTTOMRIGHT", model, "BOTTOMRIGHT", -(inset or 6), 4)
	hint:SetJustifyH("LEFT")
	hint:SetText(M.HINT)
	return hint
end

function M.BeforeLoad(model)
	neutral(model)
end

function M.Frame(model, entry)
	model.mvEntry = entry
	local settle = model.mvSettle
	settle.held = M.holdSeconds
	settle.left = SETTLE_SECONDS + settle.held
	if settle.held > 0 then
		pcall(model.SetFacing, model, model.mvFacing)
	else
		apply(model)
	end
	settle:Show()
end

-- Takes the views an addon saved and has it save the shared ones from now on. Where two addons have
-- a view of the same creature, the later change wins: they only differ if one was turned off a while.
function M.Bind(db)
	local saved = db.modelViews
	if saved and saved ~= M.views then
		for entry, view in pairs(saved) do
			local have = M.views[entry]
			if not have or (view.at or 0) > (have.at or 0) then M.views[entry] = view end
		end
	end
	db.modelViews = M.views
end
