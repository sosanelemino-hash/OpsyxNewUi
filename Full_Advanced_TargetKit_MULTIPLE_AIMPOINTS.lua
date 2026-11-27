--!nonstrict
--[[
	TargetKit: lock-on targeting toolkit.
	Hardening scope: fault isolation, guarded event/render callbacks, and
	idempotent teardown. This build does not hide from or bypass anti-cheat,
	security monitoring, or platform enforcement systems.
	Multi-aimpoint build: R6/R15-compatible body-part presets with safe root fallback.
	Advanced diagnostics build: reusable selection buffers, live performance
	telemetry, delayed rig registration, and guarded component lifecycles.
	Standalone Luau chunk: may be run as a LocalScript in your own experience
	or passed directly to an authorized Luau loadstring environment.
	No external loaders, HTTP downloads, or ban-evasion behavior are used.

	Components
	  TargetKit         core: target registry, overlays, selection, camera lock
	  TargetKitUI       settings window (RightShift toggles visibility)
	  TargetInfoCard    HUD card for the currently aimed/locked target
	  TargetKitPlayers  adapter that registers other players' characters

	Desktop PC input: hold right mouse button to aim; release to stop.
	Q remains a separate persistent Lock-On toggle.

	A target is any Model with a Humanoid and a root part, tagged "Target"
	through CollectionService, or registered by TargetKitPlayers.

	Notes
	  * Roblox renders at most 31 Highlight instances at once; extra
	    targets keep their name tag and health bar but lose the outline.
	  * Distances are reported in studs ("st").
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

-- Loadstring/executor entry points may run before LocalPlayer is initialized.
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    repeat
        task.wait()
        LocalPlayer = Players.LocalPlayer
    until LocalPlayer
end

-- Prefer the executor's supported hidden GUI container when available.
-- Fall back to the normal PlayerGui so the same source also works as a
-- standard LocalScript in an experience and in executors without gethui().
local function resolveGuiParent()
    local ok, parent = pcall(function()
        if type(gethui) == "function" then
            return gethui()
        end
        return nil
    end)

    if ok and typeof(parent) == "Instance" then
        return parent
    end

    return LocalPlayer:WaitForChild("PlayerGui")
end

local GUI_PARENT = resolveGuiParent()

-- Assigned in the bootstrap section; recreates the PlayerGui runtime marker
-- if the experience deletes it. Declared here so the UI self-check can use it.
local ensureRuntimeMarker = nil

-- Roblox LocalScripts cannot reliably read the operating-system platform.
-- Mouse + keyboard identifies desktop-style input; touch capability does not
-- disqualify touchscreen laptops or hybrid PCs. Exclude ten-foot console UI.
local function detectPCInput()
	local tenFootInterface = false
	local ok, result = pcall(function()
		return GuiService:IsTenFootInterface()
	end)
	if ok then
		tenFootInterface = result
	end

	return UserInputService.MouseEnabled
		and UserInputService.KeyboardEnabled
		and not tenFootInterface
end

local IS_PC = detectPCInput()

------------------------------------------------------------------------
-- Shared utilities
------------------------------------------------------------------------

local TARGETKIT_VERSION = "3.0.8"
local TARGETKIT_BUILD = "ADVANCED-COMMAND-CENTER"
local TARGETKIT_CHANNEL = "STABLE"
local TARGETKIT_BOOT_TIME = os.clock()
local TAG = "Target"
local RELEASE_FOV_SCALE = 1.5 -- a held lock survives until the target leaves 1.5x the FOV
local TARGET_REACQUIRE_INTERVAL = 1 / 15 -- Avoid rescanning every frame when no target is available.
local LOS_RECHECK_INTERVAL = 1 / 30 -- Cache retained-target LOS briefly instead of raycasting every frame.
local VISUAL_UPDATE_INTERVAL = 1 / 30 -- UI/ESP work does not need the full targeting update rate.

local function clampVelocity(velocity, maxSpeed)
	if typeof(velocity) ~= "Vector3" then
		return Vector3.zero
	end
	local x, y, z = velocity.X, velocity.Y, velocity.Z
	if x ~= x or y ~= y or z ~= z
		or math.abs(x) == math.huge
		or math.abs(y) == math.huge
		or math.abs(z) == math.huge then
		return Vector3.zero
	end
	local magnitude = velocity.Magnitude
	if magnitude ~= magnitude or magnitude == math.huge then
		return Vector3.zero
	end
	if magnitude > maxSpeed and magnitude > 0 then
		return velocity.Unit * maxSpeed
	end
	return velocity
end

-- Prefer a valid HumanoidRootPart, but fall back to PrimaryPart when the
-- named child exists but is not a BasePart or is absent (custom rigs).
local function findRootPart(model)
	if typeof(model) ~= "Instance" then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	local primary = model.PrimaryPart
	if primary and primary:IsA("BasePart") then
		return primary
	end
	return nil
end

local function compareVisualRecords(a, b)
	if a.VisualIsAimTarget ~= b.VisualIsAimTarget then
		return a.VisualIsAimTarget
	end
	if a.VisualDistance == b.VisualDistance then
		return a.Model.Name < b.Model.Name
	end
	return a.VisualDistance < b.VisualDistance
end

local function compareSelectionRecords(a, b)
	if a.SelectionScore == b.SelectionScore then
		return a.Model.Name < b.Model.Name
	end
	return a.SelectionScore < b.SelectionScore
end

local THEME = {
	Bg = Color3.fromRGB(20, 16, 32),
	Panel = Color3.fromRGB(32, 26, 50),
	Track = Color3.fromRGB(58, 50, 80),
	Text = Color3.fromRGB(245, 232, 250),
	Sub = Color3.fromRGB(170, 150, 195),
	Pink = Color3.fromRGB(255, 120, 175),
	Blue = Color3.fromRGB(110, 185, 255),
	HealthHigh = Color3.fromRGB(110, 230, 150),
	HealthLow = Color3.fromRGB(255, 90, 90),
}

-- Builds an instance. Parent is assigned last, after properties and
-- children, so the instance enters the tree fully configured.
local function make(className, props, children)
	local inst = Instance.new(className)
	local parent = props.Parent
	for key, value in props do
		if key ~= "Parent" then
			inst[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = inst
	end
	inst.Parent = parent
	return inst
end

local function round(radius)
	return make("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function tween(inst, duration, props)
	TweenService:Create(
		inst,
		TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		props
	):Play()
end

local function isPointerDown(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function cleanupTask(taskToClean)
	local kind = typeof(taskToClean)
	if kind == "RBXScriptConnection" then
		if taskToClean.Connected then
			taskToClean:Disconnect()
		end
	elseif kind == "Instance" then
		taskToClean:Destroy()
	elseif kind == "function" then
		taskToClean()
	elseif kind == "table" and type(taskToClean.Destroy) == "function" then
		taskToClean:Destroy()
	end
end

-- Runtime fault isolation: one bad callback should not permanently break
-- unrelated UI/input/targeting systems. Warnings are throttled per callback key.
local _lastFaultWarning = {}
local _runtimeFaultCount = 0
local _lastRuntimeFault = "None"
local function reportRuntimeFault(key, err)
	_runtimeFaultCount += 1
	_lastRuntimeFault = tostring(key) .. ": " .. tostring(err)
	local now = os.clock()
	local throttleKey = tostring(key) .. "|" .. string.sub(tostring(err), 1, 120)
	local previous = _lastFaultWarning[throttleKey] or 0
	if now - previous >= 5 then
		_lastFaultWarning[throttleKey] = now
		warn(("[TargetKit] %s failed: %s"):format(tostring(key), tostring(err)))
	end
end

-- Circuit breaker: a callback that keeps failing is paused briefly instead of
-- erroring every frame, so one broken feature cannot flood or stall the rest.
local BREAKER_LIMIT = 8 -- failures inside the window that trip the breaker
local BREAKER_WINDOW = 10 -- seconds
local BREAKER_COOLDOWN = 3 -- seconds a tripped callback stays paused
local _breakers = setmetatable({}, { __mode = "k" })
local _breakerTrips = 0

local function protectedCallback(key, callback, ...)
	local breaker = _breakers[callback]
	if breaker and breaker.PausedUntil and os.clock() < breaker.PausedUntil then
		return nil
	end
	local args = table.pack(...)
	local ok, result = xpcall(function()
		return callback(table.unpack(args, 1, args.n))
	end, function(err)
		local traceOk, trace = pcall(function()
			return debug.traceback(tostring(err), 2)
		end)
		return traceOk and trace or tostring(err)
	end)
	if not ok then
		reportRuntimeFault(key, result)
		local now = os.clock()
		breaker = breaker or { Count = 0, WindowStart = now }
		if now - breaker.WindowStart > BREAKER_WINDOW then
			breaker.Count, breaker.WindowStart = 0, now
		end
		breaker.Count += 1
		if breaker.Count >= BREAKER_LIMIT then
			breaker.Count, breaker.WindowStart = 0, now
			breaker.PausedUntil = now + BREAKER_COOLDOWN
			_breakerTrips += 1
			warn(("[TargetKit] %s paused for %ds after repeated failures"):format(tostring(key), BREAKER_COOLDOWN))
		end
		_breakers[callback] = breaker
		return nil
	end
	return result
end

-- Lifetime manager: connections, instances, callbacks, or objects with Destroy.
-- Clean() is reusable for respawn-scoped connections; Destroy() is permanent.
local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ _tasks = {}, _cleaning = false, _destroyed = false }, Maid)
end

function Maid:Give(taskToGive)
	if taskToGive == nil then
		return nil
	end
	if self._destroyed or self._cleaning then
		local ok, err = pcall(cleanupTask, taskToGive)
		if not ok then
			warn("[TargetKit] late cleanup task failed: " .. tostring(err))
		end
		return taskToGive
	end
	table.insert(self._tasks, taskToGive)
	return taskToGive
end

function Maid:Connect(signal, callback)
	if self._destroyed then
		return nil
	end
	local label = "signal callback"
	local ok, connection = pcall(function()
		return signal:Connect(function(...)
			protectedCallback(label, callback, ...)
		end)
	end)
	if not ok then
		reportRuntimeFault("signal connection", connection)
		return nil
	end
	return self:Give(connection)
end

function Maid:Clean()
	if self._cleaning then
		return
	end
	self._cleaning = true
	local tasks = self._tasks
	self._tasks = {}
	for index = #tasks, 1, -1 do
		local ok, err = pcall(cleanupTask, tasks[index])
		if not ok then
			warn("[TargetKit] cleanup task failed: " .. tostring(err))
		end
	end
	self._cleaning = false
end

function Maid:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self:Clean()
end

local function makeDraggable(maid, handle, target)
	local dragging, origin, startPosition, activePointer = false, nil, nil, nil
	maid:Connect(handle.InputBegan, function(input)
		if isPointerDown(input) then
			dragging, origin, startPosition, activePointer = true, input.Position, target.Position, input
		end
	end)
	maid:Connect(UserInputService.InputChanged, function(input)
		if not dragging or not activePointer then
			return
		end
		local isMatchingMove = (activePointer.UserInputType == Enum.UserInputType.Touch and input == activePointer)
			or (activePointer.UserInputType == Enum.UserInputType.MouseButton1
				and input.UserInputType == Enum.UserInputType.MouseMovement)
		if not isMatchingMove then
			return
		end
		local delta = input.Position - origin
		local x = startPosition.X.Offset + delta.X
		local y = startPosition.Y.Offset + delta.Y
		local camera = Workspace.CurrentCamera
		if camera then
			local topLeftInset, bottomRightInset = GuiService:GetGuiInset()
			local viewport = camera.ViewportSize
			local maxX = math.max(0, viewport.X - topLeftInset.X - bottomRightInset.X - target.AbsoluteSize.X)
			local maxY = math.max(0, viewport.Y - topLeftInset.Y - bottomRightInset.Y - target.AbsoluteSize.Y)
			x = math.clamp(x, 0, maxX)
			y = math.clamp(y, 0, maxY)
		end
		target.Position = UDim2.new(startPosition.X.Scale, x, startPosition.Y.Scale, y)
	end)
	maid:Connect(UserInputService.InputEnded, function(input)
		local matchingEnd = activePointer and (
			input == activePointer
			or (activePointer.UserInputType == Enum.UserInputType.MouseButton1
				and input.UserInputType == Enum.UserInputType.MouseButton1)
		)
		if matchingEnd then
			dragging, origin, startPosition, activePointer = false, nil, nil, nil
		end
	end)
	maid:Connect(UserInputService.WindowFocusReleased, function()
		dragging, origin, startPosition, activePointer = false, nil, nil, nil
	end)
end

------------------------------------------------------------------------
-- TargetKit (core)
------------------------------------------------------------------------

local DEFAULTS = {
	MaxDistance = 1000, -- studs
	UpdateHz = 120, -- target/overlay refresh ceiling; actual rate follows client frame rate
	FovRadius = 180, -- pixels from screen center
	LockSmoothing = 1.0, -- per-60Hz-frame blend; 1 snaps instantly
	LockKey = Enum.KeyCode.Q,
	EnablePCHoldToAim = true, -- PC only; hold right mouse button while aiming
	EnablePrediction = true, -- Velocity-based lead for the current aim target
	PredictionLeadTime = 0, -- Zero disables time-based target lead
	PredictionMaxLead = 0, -- Zero disables all positional lead
	PredictionSmoothing = 0, -- Zero uses the latest velocity sample without filtering
	PredictionMaxSpeed = 120, -- Reject/clamp implausible replicated velocity spikes
	ShowOutline = true,
	OutlineThroughWalls = true, -- AlwaysOnTop outline for targets behind geometry
	ShowName = true,
	ShowHealth = true,
	ShowDistance = true,
	ShowFov = true,
	RequireLineOfSight = true,
	SelectionMode = "Hybrid", -- "Screen", "Distance", or "Hybrid"
	HighlightLimit = 31,
	AimPart = "Head", -- Head, UpperTorso, LowerTorso, Torso, HumanoidRootPart, or Root.
	DiagnosticsEnabled = true, -- Lightweight rolling runtime telemetry for the Performance page.
}

-- Supported aim-point presets. Fallbacks keep the selector usable on both
-- standard R6 and R15 rigs, plus custom rigs with a valid registered root.
local AIM_PART_FALLBACKS = {
	Head = { "Head", "UpperTorso", "Torso", "LowerTorso" },
	UpperTorso = { "UpperTorso", "Torso", "LowerTorso" },
	LowerTorso = { "LowerTorso", "Torso", "UpperTorso" },
	Torso = { "Torso", "UpperTorso", "LowerTorso" },
	HumanoidRootPart = { "HumanoidRootPart" },
	Root = {}, -- Uses the rig root selected during target registration.
}

local LIMITS = {
	MaxDistance = { 10, 2000 },
	UpdateHz = { 1, 120 },
	FovRadius = { 20, 1000 },
	LockSmoothing = { 0.01, 1 },
	PredictionLeadTime = { 0, 0.45 },
	PredictionMaxLead = { 0, 50 },
	PredictionSmoothing = { 0, 0.5 },
	PredictionMaxSpeed = { 10, 300 },
}

local TargetKit = {}
TargetKit.__index = TargetKit

function TargetKit.new(config)
	local self = setmetatable({}, TargetKit)
	self._maid = Maid.new()
	self._destroyed = false
	self._records = {} -- [Model] = record
	self._visualOrder = {} -- Reused sorted scratch array for ESP priority.
	self._selectionCandidates = {} -- Reused record array for target reacquisition.
	self._pendingTargets = {} -- [Model] = connections waiting for a valid rig
	self._pendingTargetCount = 0
	self._outlineColors = {} -- Optional per-model outline colors, retained across rig re-registration.
	self._visualAccum = 0
	self._nextLockAcquireAt = 0
	self._nextHoldAcquireAt = 0
	self.Diagnostics = {
		UpdateSamples = 0,
		LastUpdateMs = 0,
		AverageUpdateMs = 0,
		PeakUpdateMs = 0,
		LastSelectionMs = 0,
		PeakSelectionMs = 0,
		LastSelectionRaycasts = 0,
		Raycasts = 0,
		TargetCount = 0,
		PendingTargets = 0,
		ActiveHighlights = 0,
		VisualUpdateMs = 0,
		HeartbeatRate = 0,
	}
	self._locked = nil
	self._lockEnabled = false
	self._holdAimActive = false -- Momentary PC-only aim; never persists after release.
	self._holdAimTarget = nil
	self._isPC = IS_PC
	self._localAlive = true -- Lock-On is unavailable while the local character is dead.
	self._resumeLockAfterRespawn = false
	self._accum = 0
	self._bindName = "TargetKitLock_" .. HttpService:GenerateGUID(false)

	self.Config = table.clone(DEFAULTS)
	if config ~= nil and typeof(config) ~= "table" then
		warn("[TargetKit] configuration must be a table; defaults will be used")
		config = nil
	end
	for key, value in config or {} do
		if DEFAULTS[key] == nil then
			warn(("[TargetKit] unknown option '%s' ignored"):format(tostring(key)))
		elseif typeof(value) ~= typeof(DEFAULTS[key]) then
			warn(("[TargetKit] option '%s' expects %s"):format(key, typeof(DEFAULTS[key])))
		else
			self.Config[key] = value
		end
	end
	for key, range in LIMITS do
		local value = self.Config[key]
		if typeof(value) ~= "number" or value ~= value
			or value == math.huge or value == -math.huge then
			value = DEFAULTS[key]
		end
		self.Config[key] = math.clamp(value, range[1], range[2])
	end
	if self.Config.SelectionMode ~= "Screen"
		and self.Config.SelectionMode ~= "Distance"
		and self.Config.SelectionMode ~= "Hybrid"
	then
		self.Config.SelectionMode = DEFAULTS.SelectionMode
	end
	local highlightLimit = tonumber(self.Config.HighlightLimit)
	if not highlightLimit or highlightLimit ~= highlightLimit
		or highlightLimit == math.huge or highlightLimit == -math.huge then
		highlightLimit = DEFAULTS.HighlightLimit
	end
	self.Config.HighlightLimit = math.clamp(math.floor(highlightLimit), 1, 31)
	if AIM_PART_FALLBACKS[self.Config.AimPart] == nil then
		self.Config.AimPart = DEFAULTS.AimPart
	end
	if typeof(self.Config.LockKey) ~= "EnumItem" or self.Config.LockKey.EnumType ~= Enum.KeyCode then
		self.Config.LockKey = DEFAULTS.LockKey
	end

	self._losParams = RaycastParams.new()
	self._losParams.FilterType = Enum.RaycastFilterType.Exclude
	self._losParams.RespectCanCollide = false
	self._losFilterWithCharacter = { nil, nil }
	self._losFilterWithoutCharacter = { nil }

	local lockChanged = self._maid:Give(Instance.new("BindableEvent"))
	self._lockChanged = lockChanged
	self.LockChanged = lockChanged.Event -- fires with (enabled: boolean)

	local holdAimChanged = self._maid:Give(Instance.new("BindableEvent"))
	self._holdAimChanged = holdAimChanged
	self.HoldAimChanged = holdAimChanged.Event -- fires with (active: boolean)

	local ok, err = xpcall(function()
		self:_buildOverlay()
		self:_hookTagged()
		self:_hookLoops()
	end, debug.traceback)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

-- Registers a child component so it is destroyed together with the kit.
function TargetKit:Give(task)
	return self._maid:Give(task)
end

function TargetKit:IsLockEnabled()
	return self._lockEnabled
end

function TargetKit:IsLockResumePending()
	return self._resumeLockAfterRespawn
end

function TargetKit:IsPCHoldToAimSupported()
	return self._isPC
end

function TargetKit:SetPCHoldToAimEnabled(enabled)
	if self._destroyed then
		return false
	end
	self.Config.EnablePCHoldToAim = enabled == true
	if not self.Config.EnablePCHoldToAim then
		self:SetHoldAim(false)
	end
	return true
end

-- Momentary aim control. On desktop, hold RMB to aim and release to stop.
-- This does not toggle or modify the persistent Q Lock-On state.
function TargetKit:SetHoldAim(active)
	if self._destroyed then
		return false
	end
	active = active == true
	if active and (not self._isPC or not self.Config.EnablePCHoldToAim or not self._localAlive) then
		return false
	end
	if self._holdAimActive == active then
		return true
	end
	self._holdAimActive = active
	if active then
		self._holdAimTarget = self:_pickTarget()
		self._nextHoldAcquireAt = os.clock() + TARGET_REACQUIRE_INTERVAL
	else
		self._holdAimTarget = nil
		self._nextHoldAcquireAt = 0
	end
	self._holdAimChanged:Fire(active)
	return true
end

-- Called by the player adapter when the local character dies or respawns.
function TargetKit:SetLocalAlive(alive)
	if self._destroyed then
		return
	end
	alive = alive == true

	if not alive then
		-- A held input is transient and must never survive death/respawn.
		self:SetHoldAim(false)
		if self._localAlive then
			-- Remember the user's active state before death so it can be
			-- restored once the replacement character is alive.
			self._resumeLockAfterRespawn = self._lockEnabled
		end
		self._localAlive = false
		self._nextLockAcquireAt = 0
		if self._lockEnabled then
			self._lockEnabled = false
			self._locked = nil
			self._lockChanged:Fire(false)
		end
		return
	end

	local shouldResume = not self._localAlive and self._resumeLockAfterRespawn
	self._localAlive = true
	self._resumeLockAfterRespawn = false
	if shouldResume then
		self:SetLock(true)
	end
end

-- Re-enables Lock-On after the watchdog rebuilds the kit; if the local
-- character is not alive yet, the lock resumes on respawn instead.
function TargetKit:RestoreLock()
	if self._destroyed then
		return false
	end
	if self._localAlive and self:SetLock(true) then
		return true
	end
	self._resumeLockAfterRespawn = true
	return false
end

function TargetKit:GetRecord(model)
	return self._records[model]
end

-- Store team/custom colors independently of the live Highlight instance so
-- delayed rig registration and root-part replacement keep the intended color.
function TargetKit:SetTargetOutlineColor(model, color)
	if self._destroyed or typeof(model) ~= "Instance" or not model:IsA("Model") then
		return false
	end
	if color ~= nil and typeof(color) ~= "Color3" then
		return false
	end
	self._outlineColors[model] = color
	local record = self._records[model]
	if record and record.Highlight then
		record.Highlight.OutlineColor = color or THEME.Pink
	end
	return true
end

function TargetKit:ResetDiagnostics()
	if self._destroyed then
		return false
	end
	local diagnostics = self.Diagnostics
	diagnostics.UpdateSamples = 0
	diagnostics.LastUpdateMs = 0
	diagnostics.AverageUpdateMs = 0
	diagnostics.PeakUpdateMs = 0
	diagnostics.LastSelectionMs = 0
	diagnostics.PeakSelectionMs = 0
	diagnostics.LastSelectionRaycasts = 0
	diagnostics.Raycasts = 0
	diagnostics.VisualUpdateMs = 0
	return true
end

function TargetKit:GetLockedRecord()
	local model = self._locked
	return model and self._records[model] or nil
end

function TargetKit:GetAimRecord()
	if self._holdAimActive then
		local model = self._holdAimTarget
		return model and self._records[model] or nil
	end
	return self:GetLockedRecord()
end

function TargetKit:_buildOverlay()
	-- IgnoreGuiInset keeps the FOV circle on the same center that
	-- WorldToViewportPoint measures against (the full viewport).
	self.Gui = self._maid:Give(make("ScreenGui", {
		Name = "TargetKitOverlay",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 5,
		Parent = GUI_PARENT,
	}))
	self.FovCircle = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = self.Gui,
	}, {
		make("UICorner", { CornerRadius = UDim.new(1, 0) }),
		make("UIStroke", { Color = THEME.Blue, Thickness = 1.5 }),
	})
end

function TargetKit:_hookTagged()
	for _, model in CollectionService:GetTagged(TAG) do
		self:AddTarget(model)
	end
	self._maid:Connect(CollectionService:GetInstanceAddedSignal(TAG), function(model)
		self:AddTarget(model)
	end)
	self._maid:Connect(CollectionService:GetInstanceRemovedSignal(TAG), function(model)
		self:RemoveTarget(model)
	end)
end

function TargetKit:_clearPendingTarget(model)
	local connections = self._pendingTargets[model]
	if not connections then
		return
	end
	self._pendingTargets[model] = nil
	self._pendingTargetCount = math.max(0, self._pendingTargetCount - 1)
	for _, connection in pairs(connections) do
		if connection and connection.Connected then
			connection:Disconnect()
		end
	end
end

function TargetKit:_watchPendingTarget(model)
	if self._destroyed or self._pendingTargets[model] then
		return
	end

	local connections = {}
	self._pendingTargets[model] = connections
	self._pendingTargetCount += 1

	local watchedHumanoid = nil
	local function tryRegister()
		if self._destroyed then
			self:_clearPendingTarget(model)
			return
		end
		if not model:IsDescendantOf(Workspace) then
			return
		end
		local root = findRootPart(model)
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid ~= watchedHumanoid then
			if connections.HealthChanged then
				connections.HealthChanged:Disconnect()
				connections.HealthChanged = nil
			end
			watchedHumanoid = humanoid
			if humanoid then
				connections.HealthChanged = humanoid.HealthChanged:Connect(function(health)
					if health > 0 then
						tryRegister()
					end
				end)
			end
		end
		if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
			self:_clearPendingTarget(model)
			self:AddTarget(model)
		end
	end

	connections.DescendantAdded = model.DescendantAdded:Connect(tryRegister)
	connections.AncestryChanged = model.AncestryChanged:Connect(tryRegister)
	connections.PrimaryPartChanged = model:GetPropertyChangedSignal("PrimaryPart"):Connect(tryRegister)
	connections.Destroying = model.Destroying:Connect(function()
		self:_clearPendingTarget(model)
	end)
	tryRegister()
end

function TargetKit:AddTarget(model)
	if self._destroyed or typeof(model) ~= "Instance" or not model:IsA("Model") then
		return false
	end
	local existing = self._records[model]
	if existing then
		-- Registration is idempotent: callers can still claim ownership of an
		-- already-created record after a pending watcher wins the race.
		local existingIsValid = model:IsDescendantOf(Workspace)
			and existing.Root:IsDescendantOf(model)
			and existing.Humanoid:IsDescendantOf(model)
			and existing.Humanoid.Health > 0
		if existingIsValid then
			return true
		end
		self:RemoveTarget(model)
	end
	local root = findRootPart(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not model:IsDescendantOf(Workspace)
		or not root or not root:IsA("BasePart")
		or not humanoid or humanoid.Health <= 0 then
		self:_watchPendingTarget(model)
		return false
	end
	self:_clearPendingTarget(model)

	-- Highlights are allocated only for the current top-N budget in
	-- _updateVisuals; inactive targets do not each retain a disabled instance.
	local highlight = nil

	-- Keep the name/distance label above the character. The health meter is
	-- a separate, slim BillboardGui positioned beside the rig so it reads as
	-- a vertical player-side status bar rather than a horizontal nameplate.
	local label = make("TextLabel", {
		-- Use scale dimensions inside a world-scaled BillboardGui. Offset sizes
		-- stay fixed in screen pixels and make the nameplate dwarf the rig at range.
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, 0),
		BackgroundTransparency = 1,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.7,
		TextSize = 14,
		TextScaled = true,
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, {
		make("UITextSizeConstraint", { MinTextSize = 1, MaxTextSize = 14 }),
	})
	local board = make("BillboardGui", {
		Name = "TargetKitBoard",
		-- Scale components are physical stud dimensions, so the entire
		-- name + distance display shrinks naturally with camera distance.
		Size = UDim2.fromScale(6.5, 0.85),
		StudsOffset = Vector3.new(0, 2.65, 0),
		-- Keep the player name and distance readable through world geometry.
		AlwaysOnTop = true,
		MaxDistance = self.Config.MaxDistance,
		Enabled = false,
		Adornee = root,
		Parent = root,
	}, { label })

	-- Vertical health bar: full-height dark track with a bottom-anchored fill.
	-- The small world offset keeps it beside the player's body, not over the name.
	local bar = make("Frame", {
		Name = "HealthFill",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = THEME.HealthHigh,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, { round(3) })
	local barBack = make("Frame", {
		Name = "HealthTrack",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		-- Keep the rail proportional to its BillboardGui canvas at every range.
		Size = UDim2.fromScale(0.5, 0.9),
		BackgroundColor3 = Color3.fromRGB(24, 22, 32),
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, { round(3), bar })
	local healthBoard = make("BillboardGui", {
		Name = "TargetKitHealthBar",
		-- Stud-scaled canvas makes the rail shrink in screen space as the
		-- character recedes instead of remaining a fixed 60-pixel overlay.
		Size = UDim2.fromScale(0.8, 3.9),
		-- Move the rail farther out from the torso so it never sits on top of
		-- the character silhouette. The offset remains attached to the root.
		StudsOffset = Vector3.new(-2.0, 0.2, 0),
		-- Match the nameplate so the vertical health bar is not occluded either.
		AlwaysOnTop = true,
		MaxDistance = self.Config.MaxDistance,
		Enabled = false,
		Adornee = root,
		Parent = root,
	}, { barBack })

	-- Drop stale records when the model/rig leaves the world or dies.
	local recordConnections = {}
	recordConnections.ModelAncestry = model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(Workspace) then
			self:RemoveTarget(model)
			if CollectionService:HasTag(model, TAG) then
				self:_watchPendingTarget(model)
			end
		end
	end)
	recordConnections.ModelDestroying = model.Destroying:Connect(function()
		self:RemoveTarget(model)
	end)
	recordConnections.RootAncestry = root.AncestryChanged:Connect(function()
		if not root:IsDescendantOf(model) then
			self:RemoveTarget(model)
			self:_watchPendingTarget(model)
		end
	end)
	recordConnections.HumanoidAncestry = humanoid.AncestryChanged:Connect(function()
		if not humanoid:IsDescendantOf(model) then
			self:RemoveTarget(model)
			if CollectionService:HasTag(model, TAG) then
				self:_watchPendingTarget(model)
			end
		end
	end)
	recordConnections.HumanoidDied = humanoid.Died:Connect(function()
		self:RemoveTarget(model)
		if CollectionService:HasTag(model, TAG) then
			self:_watchPendingTarget(model)
		end
	end)

	self._records[model] = {
		Model = model, Root = root, Humanoid = humanoid,
		Highlight = highlight, Board = board, Label = label,
		HealthBoard = healthBoard, Bar = bar,
		Connections = recordConnections,
		PredictionState = nil, -- Lazily initialized only while this model is being aimed.
	}
	return true
end

function TargetKit:RemoveTarget(model)
	if model == nil then
		return
	end
	self:_clearPendingTarget(model)
	local record = self._records[model]
	if not record then
		return
	end
	self._records[model] = nil
	for _, connection in pairs(record.Connections or {}) do
		if connection and connection.Connected then
			connection:Disconnect()
		end
	end
	if record.Highlight then record.Highlight:Destroy() end
	if record.Board then record.Board:Destroy() end
	if record.HealthBoard then record.HealthBoard:Destroy() end
	if self._locked == model then
		self._locked = nil
	end
	if self._holdAimTarget == model then
		self._holdAimTarget = nil
	end
end

------------------------------------------------------------------------
-- Selection
------------------------------------------------------------------------

function TargetKit:_hasLineOfSight(record)
	local camera = Workspace.CurrentCamera
	if not camera then
		return false
	end
	local character = LocalPlayer.Character
	local filter
	if character then
		filter = self._losFilterWithCharacter
		filter[1], filter[2] = record.Model, character
	else
		filter = self._losFilterWithoutCharacter
		filter[1] = record.Model
	end
	self._losParams.FilterDescendantsInstances = filter
	local origin = camera.CFrame.Position
	if self.Config.DiagnosticsEnabled then
		self.Diagnostics.Raycasts += 1
	end
	return Workspace:Raycast(origin, self:_getAimPosition(record) - origin, self._losParams) == nil
end

function TargetKit:_screenDistance(camera, position)
	local point, onScreen = camera:WorldToViewportPoint(position)
	if not onScreen then
		return nil
	end
	local center = camera.ViewportSize / 2
	local dx, dy = point.X - center.X, point.Y - center.Y
	return math.sqrt(dx * dx + dy * dy)
end

function TargetKit:_getAimPosition(record)
	local fallbacks = AIM_PART_FALLBACKS[self.Config.AimPart] or AIM_PART_FALLBACKS.Head
	for _, partName in ipairs(fallbacks) do
		local part = record.Model:FindFirstChild(partName)
		if part and part:IsA("BasePart") then
			return part.Position
		end
	end
	-- HumanoidRootPart is a useful explicit choice, but custom rigs may only
	-- expose PrimaryPart. Always finish at the registered, validated root.
	return record.Root.Position
end

-- Predict only the final camera aim point. Target selection, FOV checks, and
-- line-of-sight tests continue to use the real current position so prediction
-- cannot make the selector acquire targets outside the configured FOV/range.
function TargetKit:_getPredictedAimPosition(record)
	local currentPosition = self:_getAimPosition(record)
	local cfg = self.Config
	if not cfg.EnablePrediction or cfg.PredictionLeadTime <= 0 or cfg.PredictionMaxLead <= 0 then
		return currentPosition
	end

	local root = record.Root
	if not root or not root:IsA("BasePart") or not root:IsDescendantOf(record.Model) then
		return currentPosition
	end

	local now = os.clock()
	local maxSpeed = cfg.PredictionMaxSpeed
	local physicsVelocity = clampVelocity(root.AssemblyLinearVelocity, maxSpeed)
	local state = record.PredictionState
	if not state or state.Root ~= root then
		state = {
			Root = root,
			LastPosition = root.Position,
			LastSampleAt = now,
			Velocity = physicsVelocity,
		}
		record.PredictionState = state
	else
		local sampleDt = now - state.LastSampleAt
		-- Sample at a bounded cadence. Position-delta velocity is useful for
		-- replicated characters whose AssemblyLinearVelocity is intermittently 0.
		if sampleDt >= 0.05 then
			local observedVelocity = (root.Position - state.LastPosition) / sampleDt
			local observedSpeed = observedVelocity.Magnitude
			local candidateVelocity = physicsVelocity
			-- Reject teleports / replication corrections instead of turning them
			-- into a huge one-frame lead. Clamp all accepted velocity afterwards.
			if sampleDt <= 0.35 and observedSpeed == observedSpeed
				and observedSpeed <= maxSpeed * 1.25 then
				if physicsVelocity.Magnitude < 0.5 then
					candidateVelocity = observedVelocity
				else
					candidateVelocity = physicsVelocity:Lerp(observedVelocity, 0.30)
				end
			end
			candidateVelocity = clampVelocity(candidateVelocity, maxSpeed)
			if sampleDt > 0.35 then
				state.Velocity = candidateVelocity
			elseif cfg.PredictionSmoothing <= 0 then
				-- A zero filter time means no temporal smoothing: use the latest
				-- validated velocity sample directly.
				state.Velocity = candidateVelocity
			else
				local alpha = 1 - math.exp(-sampleDt / cfg.PredictionSmoothing)
				state.Velocity = clampVelocity(state.Velocity:Lerp(candidateVelocity, alpha), maxSpeed)
			end
			state.LastPosition = root.Position
			state.LastSampleAt = now
		end
	end

	local velocity = clampVelocity(state.Velocity, maxSpeed)
	local lead = velocity * math.clamp(cfg.PredictionLeadTime, 0, 0.45)
	local maxLead = math.clamp(cfg.PredictionMaxLead, 0, 50)
	local leadMagnitude = lead.Magnitude
	if leadMagnitude > maxLead and leadMagnitude > 0 then
		lead = lead.Unit * maxLead
	end
	return currentPosition + lead
end

function TargetKit:_scoreTarget(record, camera)
	local cfg = self.Config
	local position = self:_getAimPosition(record)
	local worldDistance = (position - camera.CFrame.Position).Magnitude
	if worldDistance > cfg.MaxDistance then
		return nil
	end

	local screenDistance = self:_screenDistance(camera, position)
	if not screenDistance or screenDistance > cfg.FovRadius then
		return nil
	end
	if cfg.SelectionMode == "Distance" then
		return worldDistance
	elseif cfg.SelectionMode == "Screen" then
		return screenDistance
	end

	local screenScore = screenDistance / math.max(cfg.FovRadius, 1)
	local rangeScore = worldDistance / math.max(cfg.MaxDistance, 1)
	return screenScore * 0.72 + rangeScore * 0.28
end

function TargetKit:_finishSelectionDiagnostics(startedAt, raycastsBefore)
	if not startedAt then
		return
	end
	local diagnostics = self.Diagnostics
	local elapsedMs = (os.clock() - startedAt) * 1000
	diagnostics.LastSelectionMs = elapsedMs
	diagnostics.PeakSelectionMs = math.max(diagnostics.PeakSelectionMs, elapsedMs)
	diagnostics.LastSelectionRaycasts = diagnostics.Raycasts - raycastsBefore
end

function TargetKit:_pickTarget()
	local diagnosticsEnabled = self.Config.DiagnosticsEnabled
	local startedAt = diagnosticsEnabled and os.clock() or nil
	local raycastsBefore = diagnosticsEnabled and self.Diagnostics.Raycasts or 0
	local camera = Workspace.CurrentCamera
	if not camera then
		self:_finishSelectionDiagnostics(startedAt, raycastsBefore)
		return nil
	end

	-- Reuse candidate records already stored in the registry. The scratch list
	-- is cleared between calls, avoiding one table per candidate and call.
	local candidates = self._selectionCandidates
	table.clear(candidates)
	for model, record in self._records do
		local rigValid = model:IsDescendantOf(Workspace)
			and record.Root:IsDescendantOf(model)
			and record.Humanoid:IsDescendantOf(model)
			and record.Humanoid.Health > 0
		if rigValid then
			local score = self:_scoreTarget(record, camera)
			if score then
				record.SelectionScore = score
				candidates[#candidates + 1] = record
			end
		end
	end

	table.sort(candidates, compareSelectionRecords)

	-- Rank cheaply first, then raycast in score order and stop at the first
	-- visible candidate. This avoids one LOS raycast per player every update.
	for _, candidateRecord in ipairs(candidates) do
		if not self.Config.RequireLineOfSight or self:_hasLineOfSight(candidateRecord) then
			self:_finishSelectionDiagnostics(startedAt, raycastsBefore)
			return candidateRecord.Model
		end
	end
	self:_finishSelectionDiagnostics(startedAt, raycastsBefore)
	return nil
end

-- A held lock must stay alive and in range, and (optionally) remain visible.
function TargetKit:_isRetained(record)
	local cfg = self.Config
	local camera = Workspace.CurrentCamera
	if not camera
		or not record.Model:IsDescendantOf(Workspace)
		or not record.Root:IsDescendantOf(record.Model)
		or not record.Humanoid:IsDescendantOf(record.Model)
		or record.Humanoid.Health <= 0 then
		return false
	end
	local position = self:_getAimPosition(record)
	if (position - camera.CFrame.Position).Magnitude > cfg.MaxDistance then
		return false
	end
	-- FOV is an acquisition filter, not a retention filter. During camera
	-- catch-up, the projected screen position can move even though the target
	-- remains valid. Dropping the lock here causes the camera to stop tracking
	-- and can look like a snap back toward the previous view.
	if not cfg.RequireLineOfSight then
		return true
	end

	-- Retain the last LOS result for a short window. Geometry changes are still
	-- noticed promptly, while a 120 Hz lock loop avoids 120 identical raycasts.
	local now = os.clock()
	if record.NextLineOfSightCheckAt == nil or now >= record.NextLineOfSightCheckAt then
		record.HasLineOfSight = self:_hasLineOfSight(record)
		record.NextLineOfSightCheckAt = now + LOS_RECHECK_INTERVAL
	end
	return record.HasLineOfSight == true
end

function TargetKit:_maintainLock()
	-- Do not let temporary RMB camera movement retarget the persistent Q lock.
	if not self._lockEnabled or self._holdAimActive then
		return
	end
	local record = self:GetLockedRecord()
	if record and self:_isRetained(record) then
		return
	end
	self._locked = nil

	-- When no candidate is available, a full registry scan every frame is
	-- wasted work. Reacquire at a responsive 15 Hz until a target is found.
	local now = os.clock()
	if now < self._nextLockAcquireAt then
		return
	end
	self._locked = self:_pickTarget()
	self._nextLockAcquireAt = now + TARGET_REACQUIRE_INTERVAL
end

function TargetKit:_maintainHoldAim()
	if not self._holdAimActive then
		return
	end
	if not self._isPC or not self.Config.EnablePCHoldToAim or not self._localAlive then
		self:SetHoldAim(false)
		return
	end
	local record = self._holdAimTarget and self._records[self._holdAimTarget]
	if record and self:_isRetained(record) then
		return
	end
	self._holdAimTarget = nil
	local now = os.clock()
	if now < self._nextHoldAcquireAt then
		return
	end
	self._holdAimTarget = self:_pickTarget()
	self._nextHoldAcquireAt = now + TARGET_REACQUIRE_INTERVAL
end

function TargetKit:SetLock(enabled)
	if self._destroyed then
		return false
	end
	enabled = enabled == true
	local hadPendingResume = self._resumeLockAfterRespawn

	-- An explicit OFF must cancel a queued auto-resume even while dead.
	if not enabled then
		self._resumeLockAfterRespawn = false
	end
	if enabled and not self._localAlive then
		return false -- Do not allow the keybind or UI to re-enable Lock-On while dead.
	end
	if self._lockEnabled == enabled then
		if hadPendingResume ~= self._resumeLockAfterRespawn then
			self._lockChanged:Fire(enabled)
		end
		return true
	end
	self._lockEnabled = enabled
	self._nextLockAcquireAt = 0
	self._locked = enabled and self:_pickTarget() or nil
	if enabled then
		self._nextLockAcquireAt = os.clock() + TARGET_REACQUIRE_INTERVAL
	end
	self._lockChanged:Fire(enabled)
	return true
end

------------------------------------------------------------------------
-- Update loops
------------------------------------------------------------------------

function TargetKit:_updateVisuals()
	local cfg = self.Config
	local diagnosticsEnabled = cfg.DiagnosticsEnabled
	local startedAt = diagnosticsEnabled and os.clock() or nil
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local validTargetCount = 0
	local cameraPosition = camera.CFrame.Position
	local ordered = self._visualOrder
	table.clear(ordered)
	local showName = cfg.ShowName
	local showDistance = cfg.ShowDistance
	local showHealth = cfg.ShowHealth
	local showOutline = cfg.ShowOutline

	-- One registry pass updates boards and disables ineligible outlines immediately.
	for model, record in self._records do
		local humanoid = record.Humanoid
		local root = record.Root
		local rigValid = model:IsDescendantOf(Workspace)
			and root:IsDescendantOf(model)
			and humanoid:IsDescendantOf(model)
			and humanoid.Health > 0
		local distance = rigValid and (root.Position - cameraPosition).Magnitude or math.huge
		local visible = rigValid and distance <= cfg.MaxDistance
		if rigValid then
			validTargetCount += 1
		end

		if record.Board.MaxDistance ~= cfg.MaxDistance then
			record.Board.MaxDistance = cfg.MaxDistance
		end
		if record.Board.Enabled ~= visible then
			record.Board.Enabled = visible
		end
		local showHealthBar = visible and showHealth
		if record.HealthBoard.MaxDistance ~= cfg.MaxDistance then
			record.HealthBoard.MaxDistance = cfg.MaxDistance
		end
		if record.HealthBoard.Enabled ~= showHealthBar then
			record.HealthBoard.Enabled = showHealthBar
		end

		if not visible then
			if record.Highlight then
				record.Highlight:Destroy()
				record.Highlight = nil
			end
		else
			local displayName = showName and model.Name or nil
			local displayDistance = showDistance and math.floor(distance) or nil
			if record.LastLabelName ~= displayName or record.LastLabelDistance ~= displayDistance then
				local labelText = ""
				if displayName and displayDistance then
					labelText = displayName .. "  " .. tostring(displayDistance) .. " st"
				elseif displayName then
					labelText = displayName
				elseif displayDistance then
					labelText = tostring(displayDistance) .. " st"
				end
				record.Label.Text = labelText
				record.LastLabelName = displayName
				record.LastLabelDistance = displayDistance
			end
			local labelVisible = displayName ~= nil or displayDistance ~= nil
			if record.Label.Visible ~= labelVisible then
				record.Label.Visible = labelVisible
			end
			if showHealth then
				local health = humanoid.Health
				local maxHealth = humanoid.MaxHealth
				if record.LastHealth ~= health or record.LastMaxHealth ~= maxHealth then
					local ratio = math.clamp(health / math.max(maxHealth, 1), 0, 1)
					-- Height represents remaining health; anchor at the bottom so the
					-- fill drains downwards as damage is taken.
					record.Bar.Size = UDim2.new(1, 0, ratio, 0)
					record.Bar.BackgroundColor3 = THEME.HealthLow:Lerp(THEME.HealthHigh, ratio)
					record.LastHealth = health
					record.LastMaxHealth = maxHealth
				end
			end

			if showOutline then
				record.VisualDistance = distance
				record.VisualIsAimTarget = model == self._locked
					or (self._holdAimActive and model == self._holdAimTarget)
				ordered[#ordered + 1] = record
			elseif record.Highlight then
				record.Highlight:Destroy()
				record.Highlight = nil
			end
		end
	end

	-- The locked/held target wins the limited Highlight budget; remaining slots go to nearest targets.
	if #ordered > 1 then
		table.sort(ordered, compareVisualRecords)
	end

	local activeHighlights = math.min(#ordered, cfg.HighlightLimit, 31)
	local desiredDepthMode = cfg.OutlineThroughWalls
		and Enum.HighlightDepthMode.AlwaysOnTop
		or Enum.HighlightDepthMode.Occluded
	for index, record in ipairs(ordered) do
		local shouldEnable = index <= activeHighlights
		local highlight = record.Highlight
		if shouldEnable then
			if not highlight or not highlight.Parent then
				highlight = make("Highlight", {
					Name = "TargetKitHighlight",
					FillTransparency = 0.8,
					OutlineColor = self._outlineColors[record.Model] or THEME.Pink,
					DepthMode = desiredDepthMode,
					Enabled = true,
					Parent = record.Model,
				})
				record.Highlight = highlight
			end
			if highlight.DepthMode ~= desiredDepthMode then
				highlight.DepthMode = desiredDepthMode
			end
			if not highlight.Enabled then
				highlight.Enabled = true
			end
		elseif highlight then
			highlight:Destroy()
			record.Highlight = nil
		end
	end

	local diameter = cfg.FovRadius * 2
	if self.FovCircle.Visible ~= cfg.ShowFov then
		self.FovCircle.Visible = cfg.ShowFov
	end
	if self._lastFovDiameter ~= diameter then
		self.FovCircle.Size = UDim2.fromOffset(diameter, diameter)
		self._lastFovDiameter = diameter
	end

	if startedAt then
		local diagnostics = self.Diagnostics
		diagnostics.TargetCount = validTargetCount
		diagnostics.PendingTargets = self._pendingTargetCount
		diagnostics.ActiveHighlights = activeHighlights
		diagnostics.VisualUpdateMs = (os.clock() - startedAt) * 1000
	end
end

function TargetKit:_hookLoops()
	self._maid:Connect(RunService.Heartbeat, function(dt)
		local diagnosticsEnabled = self.Config.DiagnosticsEnabled
		if diagnosticsEnabled and dt > 0 then
			local sampleRate = 1 / dt
			local diagnostics = self.Diagnostics
			diagnostics.HeartbeatRate = diagnostics.HeartbeatRate == 0
				and sampleRate
				or diagnostics.HeartbeatRate * 0.9 + sampleRate * 0.1
		end

		-- Update world-space UI and ESP at 30 Hz independently from targeting.
		-- Lock maintenance can remain at the configured 1-120 Hz rate.
		self._visualAccum += dt
		if self._visualAccum >= VISUAL_UPDATE_INTERVAL then
			self._visualAccum %= VISUAL_UPDATE_INTERVAL
			self:_updateVisuals()
		end

		local interval = 1 / self.Config.UpdateHz
		self._accum += dt
		if self._accum < interval then
			return
		end
		self._accum %= interval

		local startedAt = diagnosticsEnabled and os.clock() or nil
		self:_maintainLock()
		self:_maintainHoldAim()
		if startedAt then
			local diagnostics = self.Diagnostics
			local elapsedMs = (os.clock() - startedAt) * 1000
			diagnostics.LastUpdateMs = elapsedMs
			diagnostics.AverageUpdateMs = diagnostics.UpdateSamples == 0
				and elapsedMs
				or diagnostics.AverageUpdateMs * 0.9 + elapsedMs * 0.1
			diagnostics.PeakUpdateMs = math.max(diagnostics.PeakUpdateMs, elapsedMs)
			diagnostics.UpdateSamples += 1
		end
	end)

	local renderStepOk, renderStepError = pcall(function()
		local function cameraStep(dt)
		-- Held PC aim temporarily takes priority; otherwise normal Q Lock-On applies.
		local aimModel
		if self._holdAimActive then
			aimModel = self._holdAimTarget
		elseif self._lockEnabled then
			aimModel = self._locked
		end
		local record = aimModel and self._records[aimModel]
		local camera = Workspace.CurrentCamera
		if not (record and camera) then
			return
		end
		local current = camera.CFrame
		local targetPosition = self:_getPredictedAimPosition(record)
		if (targetPosition - current.Position).Magnitude < 1e-3 then
			return
		end
		-- Frame-rate independent smoothing: LockSmoothing is the blend per 60 Hz frame.
		local alpha = 1 - (1 - self.Config.LockSmoothing) ^ (dt * 60)
		camera.CFrame = current:Lerp(CFrame.lookAt(current.Position, targetPosition), alpha)
		end
		RunService:BindToRenderStep(self._bindName, Enum.RenderPriority.Camera.Value + 1, function(dt)
			protectedCallback("camera render callback", cameraStep, dt)
		end)
	end)
	if not renderStepOk then
		reportRuntimeFault("render-step binding", renderStepError)
	end
	self._maid:Give(function()
		RunService:UnbindFromRenderStep(self._bindName)
	end)

	self._maid:Connect(UserInputService.InputBegan, function(input, processed)
		-- RMB is intentionally observed even when Roblox's default camera marks it
		-- processed. A focused text box still blocks the action.
		if self._isPC and input.UserInputType == Enum.UserInputType.MouseButton2 then
			if not UserInputService:GetFocusedTextBox() and not GuiService.MenuIsOpen then
				self:SetHoldAim(true)
			end
			return
		end
		if not processed and not UserInputService:GetFocusedTextBox()
			and input.KeyCode == self.Config.LockKey then
			local requested = self._lockEnabled or self._resumeLockAfterRespawn
			self:SetLock(not requested)
		end
	end)

	self._maid:Connect(UserInputService.InputEnded, function(input)
		if self._isPC and input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:SetHoldAim(false)
		end
	end)

	-- Prevent a stuck hold if the player alt-tabs or the client loses focus.
	self._maid:Connect(UserInputService.WindowFocusReleased, function()
		self:SetHoldAim(false)
	end)
end

function TargetKit:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._lockEnabled = false
	self._holdAimActive = false
	self._holdAimTarget = nil
	self._maid:Destroy()
	local pendingModels = {}
	for model in pairs(self._pendingTargets) do
		table.insert(pendingModels, model)
	end
	for _, model in ipairs(pendingModels) do
		self:_clearPendingTarget(model)
	end
	local models = {}
	for model in self._records do
		table.insert(models, model)
	end
	for _, model in models do
		self:RemoveTarget(model)
	end
	table.clear(self._outlineColors)
end

------------------------------------------------------------------------
-- TargetKitUI (settings window)
------------------------------------------------------------------------

local TargetKitUI = {}
TargetKitUI.__index = TargetKitUI

function TargetKitUI.new(kit, playerAdapter)
	local self = setmetatable({}, TargetKitUI)
	self.Kit = kit
	self.PlayerAdapter = playerAdapter
	self._maid = Maid.new()
	self._pages = {}
	self._tabs = {}

	self.Gui = self._maid:Give(make("ScreenGui", {
		Name = "TargetKitUI",
		ResetOnSpawn = false,
		DisplayOrder = 10,
		Parent = kit.Gui.Parent,
	}))

	local ok, err = xpcall(function()
		self:_build()
		self:_bindInput()
	end, debug.traceback)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

function TargetKitUI:_addToggle(page, label, get, set, changedSignal)
	local row = make("Frame", {
		Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = THEME.Panel, Parent = page,
	}, { round(10) })
	make("TextLabel", {
		Size = UDim2.new(1, -64, 1, 0), Position = UDim2.fromOffset(12, 0),
		BackgroundTransparency = 1, Text = label, TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = THEME.Text, Parent = row,
	})
	local switch = make("TextButton", {
		Size = UDim2.fromOffset(40, 20), Position = UDim2.new(1, -52, 0.5, -10),
		Text = "", AutoButtonColor = false, Parent = row,
	}, { round(10) })
	local knob = make("Frame", {
		Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(3, 3),
		BackgroundColor3 = Color3.new(1, 1, 1), Parent = switch,
	}, { round(7) })

	local function render(animated)
		local on = get() == true
		local goalPosition = on and UDim2.fromOffset(23, 3) or UDim2.fromOffset(3, 3)
		local goalColor = on and THEME.Pink or Color3.fromRGB(70, 62, 92)
		if animated then
			if knob.Position ~= goalPosition then
				tween(knob, 0.2, { Position = goalPosition })
			end
			if switch.BackgroundColor3 ~= goalColor then
				tween(switch, 0.2, { BackgroundColor3 = goalColor })
			end
		else
			knob.Position = goalPosition
			switch.BackgroundColor3 = goalColor
		end
	end

	self._maid:Connect(switch.Activated, function()
		set(not get())
		-- LockChanged already renders the toggle when the setter emits an event.
		if not changedSignal then
			render(true)
		end
	end)
	if changedSignal then
		self._maid:Connect(changedSignal, function()
			render(true)
		end)
	end
	render(false)
end

function TargetKitUI:_addSlider(page, label, min, max, get, set, format)
	local row = make("Frame", {
		Size = UDim2.new(1, 0, 0, 48), BackgroundColor3 = THEME.Panel, Parent = page,
	}, { round(10) })
	make("TextLabel", {
		Size = UDim2.new(1, -90, 0, 22), Position = UDim2.fromOffset(12, 4),
		BackgroundTransparency = 1, Text = label, TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = THEME.Text, Parent = row,
	})
	local valueLabel = make("TextLabel", {
		Size = UDim2.fromOffset(70, 22), Position = UDim2.new(1, -82, 0, 4),
		BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Right,
		Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = THEME.Blue, Parent = row,
	})
	local track = make("TextButton", {
		Size = UDim2.new(1, -24, 0, 6), Position = UDim2.fromOffset(12, 33),
		BackgroundColor3 = THEME.Track, Text = "", AutoButtonColor = false, Parent = row,
	}, { round(3) })
	local fill = make("Frame", {
		Size = UDim2.fromScale(0, 1), BackgroundColor3 = THEME.Pink, Parent = track,
	}, {
		round(3),
		make("UIGradient", { Color = ColorSequence.new(THEME.Pink, THEME.Blue) }),
	})

	local function render()
		local value = tonumber(get()) or min
		local range = max - min
		local alpha = range > 0 and math.clamp((value - min) / range, 0, 1) or 0
		fill.Size = UDim2.fromScale(alpha, 1)
		valueLabel.Text = format(value)
	end

	local function apply(x)
		local width = track.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local alpha = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
		set(min + (max - min) * alpha)
		render()
	end

	local dragging, activePointer = false, nil
	self._maid:Connect(track.InputBegan, function(input)
		if isPointerDown(input) then
			dragging, activePointer = true, input
			apply(input.Position.X)
		end
	end)
	self._maid:Connect(UserInputService.InputChanged, function(input)
		if not dragging or not activePointer then
			return
		end
		local isMatchingMove = (activePointer.UserInputType == Enum.UserInputType.Touch and input == activePointer)
			or (activePointer.UserInputType == Enum.UserInputType.MouseButton1
				and input.UserInputType == Enum.UserInputType.MouseMovement)
		if isMatchingMove then
			apply(input.Position.X)
		end
	end)
	self._maid:Connect(UserInputService.InputEnded, function(input)
		local matchingEnd = activePointer and (
			input == activePointer
			or (activePointer.UserInputType == Enum.UserInputType.MouseButton1
				and input.UserInputType == Enum.UserInputType.MouseButton1)
		)
		if matchingEnd then
			dragging, activePointer = false, nil
		end
	end)
	self._maid:Connect(UserInputService.WindowFocusReleased, function()
		dragging, activePointer = false, nil
	end)
	render()
end

function TargetKitUI:_addCycle(page, label, values, get, set)
	local row = make("Frame", {
		Size = UDim2.new(1, 0, 0, 38),
		BackgroundColor3 = THEME.Panel,
		Parent = page,
	}, { round(10) })
	make("TextLabel", {
		Size = UDim2.new(1, -154, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		BackgroundTransparency = 1,
		Text = label,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = THEME.Text,
		Parent = row,
	})
	local button = make("TextButton", {
		Size = UDim2.fromOffset(132, 26),
		Position = UDim2.new(1, -142, 0.5, -13),
		BackgroundColor3 = THEME.Track,
		Text = "",
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 9,
		TextColor3 = THEME.Blue,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	}, { round(8) })

	local function render()
		button.Text = tostring(get())
	end
	self._maid:Connect(button.Activated, function()
		local index = table.find(values, get()) or 0
		set(values[(index % #values) + 1])
		render()
	end)
	render()
end

function TargetKitUI:_selectTab(name)
	for tabName, button in self._tabs do
		local active = tabName == name
		tween(button, 0.2, { BackgroundColor3 = active and THEME.Pink or THEME.Panel })
		button.TextColor3 = active and THEME.Bg or THEME.Sub
		self._pages[tabName].Visible = active
	end
end

function TargetKitUI:_build()
	local kit = self.Kit
	local cfg = kit.Config

	self.Window = make("Frame", {
		Size = UDim2.fromOffset(360, 290), Position = UDim2.fromOffset(12, 90),
		BackgroundColor3 = THEME.Bg, BackgroundTransparency = 0.05, Parent = self.Gui,
	}, { round(18) })
	self._windowScale = make("UIScale", { Scale = 1, Parent = self.Window })
	local function updateWindowScale()
		local camera = Workspace.CurrentCamera
		if not camera then return end
		local viewport = camera.ViewportSize
		local fitScale = math.min((viewport.X - 20) / 360, (viewport.Y - 24) / 290, 1)
		self._windowScale.Scale = math.max(0.35, fitScale)
	end
	updateWindowScale()
	local scaleRefresh = 0
	self._maid:Connect(RunService.Heartbeat, function(dt)
		scaleRefresh += dt
		if scaleRefresh >= 0.5 then
			scaleRefresh = 0
			updateWindowScale()
		end
	end)
	local stroke = make("UIStroke", { Thickness = 2, Color = Color3.new(1, 1, 1), Parent = self.Window })
	self._strokeGradient = make("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, THEME.Pink),
			ColorSequenceKeypoint.new(0.5, THEME.Blue),
			ColorSequenceKeypoint.new(1, THEME.Pink),
		}),
		Parent = stroke,
	})

	local titleBar = make("TextButton", {
		Size = UDim2.new(1, -80, 0, 40), BackgroundTransparency = 1, Text = "",
		AutoButtonColor = false, Parent = self.Window,
	})
	self.VersionLabel = make("TextLabel", {
		Size = UDim2.new(1, -190, 1, 0), Position = UDim2.fromOffset(16, 0), BackgroundTransparency = 1,
		Text = "TARGETKIT  v" .. TARGETKIT_VERSION, TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = THEME.Text, Parent = titleBar,
	})
	self.StatusLabel = make("TextLabel", {
		Size = UDim2.fromOffset(104, 18), Position = UDim2.new(1, -174, 0, 11),
		BackgroundColor3 = Color3.fromRGB(65, 58, 78), BackgroundTransparency = 0.05,
		Text = "STARTING", Font = Enum.Font.GothamBold, TextSize = 9,
		TextColor3 = THEME.Sub, Parent = self.Window,
	}, { round(8) })
	makeDraggable(self._maid, titleBar, self.Window)

	local function headerButton(text, offset)
		return make("TextButton", {
			Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, offset, 0, 7),
			BackgroundColor3 = THEME.Panel, Text = text, Font = Enum.Font.GothamBold,
			TextSize = 14, TextColor3 = THEME.Text, Parent = self.Window,
		}, { round(13) })
	end
	local minimize = headerButton("-", -64)
	local close = headerButton("x", -34)

	self.Orb = make("TextButton", {
		Size = UDim2.fromOffset(46, 46), Position = self.Window.Position, Visible = false,
		BackgroundColor3 = THEME.Pink, Text = "☣️", Font = Enum.Font.GothamBold,
		TextSize = 30, TextColor3 = THEME.Bg, Parent = self.Gui,
	}, { round(23) })

	self._maid:Connect(minimize.Activated, function()
		self.Orb.Position = self.Window.Position
		self.Window.Visible = false
		self.Orb.Visible = true
	end)
	self._maid:Connect(self.Orb.Activated, function()
		self.Window.Position = self.Orb.Position
		self.Orb.Visible = false
		self.Window.Visible = true
	end)
	self._maid:Connect(close.Activated, function()
		self:SetVisible(false)
	end)
	makeDraggable(self._maid, self.Orb, self.Orb)

	local sidebar = make("Frame", {
		Size = UDim2.new(0, 84, 1, -52), Position = UDim2.fromOffset(10, 44),
		BackgroundTransparency = 1, Parent = self.Window,
	}, { make("UIListLayout", { Padding = UDim.new(0, 6) }) })
	local content = make("Frame", {
		Size = UDim2.new(1, -112, 1, -52), Position = UDim2.fromOffset(102, 44),
		BackgroundTransparency = 1, Parent = self.Window,
	})

	for _, name in { "Visuals", "Lock-on", "Ignore Players", "Performance" } do
		local button = make("TextButton", {
			Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = THEME.Panel, Text = name,
			Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = THEME.Sub,
			AutoButtonColor = false, Parent = sidebar,
		}, { round(10) })
		local page = make("ScrollingFrame", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
			ScrollBarThickness = 2, CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false, Parent = content,
		}, { make("UIListLayout", {
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}) })
		self._tabs[name] = button
		self._pages[name] = page
		self._maid:Connect(button.Activated, function()
			self:_selectTab(name)
		end)
	end

	local function accessors(key)
		return function() return cfg[key] end, function(value) cfg[key] = value end
	end

	for _, entry in {
		{ "Outline", "ShowOutline" }, { "Through-wall outline", "OutlineThroughWalls" },
		{ "Name tags", "ShowName" }, { "Health bars", "ShowHealth" },
		{ "Distance", "ShowDistance" }, { "FOV circle", "ShowFov" },
	} do
		local get, set = accessors(entry[2])
		self:_addToggle(self._pages.Visuals, entry[1], get, set)
	end

	local lockPage = self._pages["Lock-on"]
	self:_addToggle(lockPage, "Lock-on (Q toggle)",
		function() return kit:IsLockEnabled() or kit:IsLockResumePending() end,
		function(value) kit:SetLock(value) end,
		kit.LockChanged)
	if kit:IsPCHoldToAimSupported() then
		self:_addToggle(lockPage, "PC-only hold aim (RMB)",
			function() return cfg.EnablePCHoldToAim end,
			function(value) kit:SetPCHoldToAimEnabled(value) end)
		make("TextLabel", {
			Size = UDim2.new(1, -8, 0, 30),
			BackgroundTransparency = 1,
			Text = "Desktop only: hold right mouse button to aim; release to stop.",
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.Gotham,
			TextSize = 10,
			TextColor3 = THEME.Sub,
			Parent = lockPage,
		})
		local holdAimStatus = make("TextLabel", {
			Size = UDim2.new(1, -8, 0, 20),
			BackgroundTransparency = 1,
			Text = "HOLD AIM: READY · HOLD RMB",
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.GothamBold,
			TextSize = 10,
			TextColor3 = THEME.HealthHigh,
			Parent = lockPage,
		})
		self._maid:Connect(kit.HoldAimChanged, function(active)
			holdAimStatus.Text = active and "HOLD AIM: ACTIVE · RELEASE RMB TO STOP" or "HOLD AIM: READY · HOLD RMB"
			holdAimStatus.TextColor3 = active and THEME.Pink or THEME.HealthHigh
		end)
	end
	local losGet, losSet = accessors("RequireLineOfSight")
	self:_addToggle(lockPage, "Line of sight", losGet, losSet)
	self:_addCycle(lockPage, "Target priority", { "Hybrid", "Screen", "Distance" },
		function() return cfg.SelectionMode end,
		function(value) cfg.SelectionMode = value end)
	self:_addCycle(lockPage, "Aim point", {
		"Head", "UpperTorso", "LowerTorso", "Torso", "HumanoidRootPart", "Root",
	},
		function() return cfg.AimPart end,
		function(value) cfg.AimPart = value end)
	self:_addSlider(lockPage, "FOV radius", 40, 400,
		function() return cfg.FovRadius end,
		function(value) cfg.FovRadius = math.floor(value) end,
		function(value) return string.format("%d px", value) end)
	self:_addSlider(lockPage, "Smoothing", 0.05, 1,
		function() return cfg.LockSmoothing end,
		function(value) cfg.LockSmoothing = value end,
		function(value) return string.format("%.2f", value) end)

	local predictionGet, predictionSet = accessors("EnablePrediction")
	self:_addToggle(lockPage, "Predictive aim (velocity lead)", predictionGet, predictionSet)
	self:_addSlider(lockPage, "Prediction lead time", 0, 0.45,
		function() return cfg.PredictionLeadTime end,
		function(value) cfg.PredictionLeadTime = math.floor(value * 100 + 0.5) / 100 end,
		function(value) return string.format("%.2f s", value) end)
	self:_addSlider(lockPage, "Maximum prediction lead", 0, 50,
		function() return cfg.PredictionMaxLead end,
		function(value) cfg.PredictionMaxLead = math.floor(value + 0.5) end,
		function(value) return string.format("%d st", value) end)
	self:_addSlider(lockPage, "Velocity filter", 0, 0.5,
		function() return cfg.PredictionSmoothing end,
		function(value) cfg.PredictionSmoothing = math.floor(value * 100 + 0.5) / 100 end,
		function(value) return string.format("%.2f s", value) end)
	make("TextLabel", {
		Size = UDim2.new(1, -8, 0, 40),
		BackgroundTransparency = 1,
		Text = "Lead time 0 or max lead 0 disables positional prediction. Velocity filter 0 uses the latest validated velocity sample without smoothing.",
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = THEME.Sub,
		Parent = lockPage,
	})

	-- Player exclusion list. Each row is a button that toggles whether that
	-- player may be registered as a lock-on target.
	local ignorePage = self._pages["Ignore Players"]
	local ignoreHint = make("TextLabel", {
		Size = UDim2.new(1, -8, 0, 34),
		BackgroundTransparency = 1,
		Text = "Tap a player to ignore or allow them",
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextColor3 = THEME.Sub,
		Parent = ignorePage,
	})
	local playerRows = {}
	local playerRowConnections = {}
	local orderedPlayers = {}
	local playerSortData = {}
	self._maid:Give(function()
		for player, connection in pairs(playerRowConnections) do
			if connection and connection.Connected then
				connection:Disconnect()
			end
			playerRowConnections[player] = nil
		end
	end)
	local function getPlayerDistance(player)
		local localRoot = findRootPart(LocalPlayer.Character)
		local targetRoot = findRootPart(player.Character)
		if localRoot and targetRoot then
			return (targetRoot.Position - localRoot.Position).Magnitude
		end
		return math.huge
	end

	local function sortPlayerRowsByDistance()
		table.clear(orderedPlayers)
		for player, row in playerRows do
			if player.Parent == Players and row.Parent then
				local entry = playerSortData[player]
				if not entry then
					entry = { Player = player }
					playerSortData[player] = entry
				end
				entry.Row = row
				entry.Distance = getPlayerDistance(player)
				orderedPlayers[#orderedPlayers + 1] = entry
			end
		end
		table.sort(orderedPlayers, function(a, b)
			if a.Distance == b.Distance then
				return a.Player.UserId < b.Player.UserId
			end
			return a.Distance < b.Distance
		end)
		for index, entry in ipairs(orderedPlayers) do
			entry.Row.LayoutOrder = index
			local stateLabel = entry.Row:FindFirstChild("PlayerStateLabel")
			local nameLabel = entry.Row:FindFirstChild("PlayerNameLabel")
			local ignored = self.PlayerAdapter:IsIgnored(entry.Player)
			if stateLabel then
				stateLabel.Text = ignored and "IGNORED" or "ALLOW"
				stateLabel.TextColor3 = ignored and THEME.Pink or THEME.HealthHigh
			end
			if nameLabel then
				local distanceText = entry.Distance < math.huge
					and string.format("%d st", math.floor(entry.Distance))
					or "--"
				nameLabel.Text = entry.Player.DisplayName .. "  @" .. entry.Player.Name .. "  ·  " .. distanceText
			end
		end
	end

	local function refreshPlayerList()
		for player, row in playerRows do
			if not player.Parent then
				local connection = playerRowConnections[player]
				if connection then
					connection:Disconnect()
					playerRowConnections[player] = nil
				end
				row:Destroy()
				playerRows[player] = nil
				playerSortData[player] = nil
			end
		end
		for _, player in Players:GetPlayers() do
			if player ~= LocalPlayer and not playerRows[player] then
				local row = make("TextButton", {
					Size = UDim2.new(1, -4, 0, 34),
					BackgroundColor3 = THEME.Panel,
					Text = "",
					AutoButtonColor = false,
					Parent = ignorePage,
				}, { round(9) })
				local nameLabel = make("TextLabel", {
					Name = "PlayerNameLabel",
					Size = UDim2.new(1, -66, 1, 0),
					Position = UDim2.fromOffset(10, 0),
					BackgroundTransparency = 1,
					Text = player.DisplayName .. "  @" .. player.Name,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Font = Enum.Font.GothamMedium,
					TextSize = 11,
					TextColor3 = THEME.Text,
					Parent = row,
				})
				local stateLabel = make("TextLabel", {
					Name = "PlayerStateLabel",
					Size = UDim2.fromOffset(52, 22),
					Position = UDim2.new(1, -58, 0.5, -11),
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBold,
					TextSize = 10,
					Parent = row,
				})
				local function renderRow()
					local ignored = self.PlayerAdapter:IsIgnored(player)
					stateLabel.Text = ignored and "IGNORED" or "ALLOW"
					stateLabel.TextColor3 = ignored and THEME.Pink or THEME.HealthHigh
					row.BackgroundColor3 = ignored and Color3.fromRGB(49, 31, 57) or THEME.Panel
				end
				playerRowConnections[player] = row.Activated:Connect(function()
					self.PlayerAdapter:SetIgnored(player, not self.PlayerAdapter:IsIgnored(player))
					renderRow()
					sortPlayerRowsByDistance()
				end)
				playerRows[player] = row
				renderRow()
			end
		end
		sortPlayerRowsByDistance()
	end
	refreshPlayerList()
	-- Reorder periodically so the closest player stays at the top as
	-- characters move, respawn, or the local player changes position.
	local sortAccumulator = 0
	self._maid:Connect(RunService.Heartbeat, function(dt)
		if not self.Gui.Enabled or not self.Window.Visible or not ignorePage.Visible then
			sortAccumulator = 0
			return
		end
		sortAccumulator += dt
		if sortAccumulator >= 0.5 then
			sortAccumulator %= 0.5
			sortPlayerRowsByDistance()
		end
	end)
	self._maid:Connect(Players.PlayerAdded, refreshPlayerList)
	self._maid:Connect(Players.PlayerRemoving, function(player)
		local connection = playerRowConnections[player]
		if connection then
			connection:Disconnect()
			playerRowConnections[player] = nil
		end
		local row = playerRows[player]
		if row then
			row:Destroy()
			playerRows[player] = nil
			playerSortData[player] = nil
		end
	end)

	local perfPage = self._pages.Performance
	self:_addToggle(perfPage, "Live diagnostics",
		function() return cfg.DiagnosticsEnabled end,
		function(value) cfg.DiagnosticsEnabled = value end)
	self._diagnosticLabel = make("TextLabel", {
		Size = UDim2.new(1, -8, 0, 126),
		BackgroundColor3 = THEME.Panel,
		BackgroundTransparency = 0.08,
		Text = "LIVE DIAGNOSTICS · WAITING FOR SAMPLES",
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = Enum.Font.Code,
		TextSize = 10,
		TextColor3 = THEME.Blue,
		Parent = perfPage,
	}, { round(9) })
	local resetDiagnostics = make("TextButton", {
		Size = UDim2.new(1, -8, 0, 28),
		BackgroundColor3 = THEME.Track,
		Text = "RESET PERFORMANCE PEAKS",
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = THEME.Text,
		AutoButtonColor = true,
		Parent = perfPage,
	}, { round(8) })
	self._maid:Connect(resetDiagnostics.Activated, function()
		kit:ResetDiagnostics()
	end)

	-- Built-in health check verifies only observable local runtime components.
	local selfCheckButton = make("TextButton", {
		Size = UDim2.new(1, -8, 0, 30),
		BackgroundColor3 = THEME.Panel,
		Text = "RUN SYSTEM SELF-CHECK",
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextColor3 = THEME.Text,
		AutoButtonColor = true,
		Parent = perfPage,
	}, { round(8) })
	self._selfCheckLabel = make("TextLabel", {
		Size = UDim2.new(1, -8, 0, 104),
		BackgroundColor3 = THEME.Panel,
		BackgroundTransparency = 0.08,
		Text = "SELF-CHECK · NOT RUN",
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = Enum.Font.Code,
		TextSize = 10,
		TextColor3 = THEME.Sub,
		Parent = perfPage,
	}, { round(9) })
	self._maid:Connect(selfCheckButton.Activated, function()
		local checks = {}
		local function addCheck(label, passed)
			table.insert(checks, (passed and "[OK] " or "[FAIL] ") .. label)
		end
		local camera = Workspace.CurrentCamera
		local localPlayerGui = LocalPlayer:FindFirstChild("PlayerGui")
		addCheck("Core object active", kit ~= nil and not kit._destroyed)
		addCheck("UI parent available", self.Gui ~= nil and self.Gui.Parent ~= nil)
		addCheck("PlayerGui available", localPlayerGui ~= nil and localPlayerGui.Parent ~= nil)
		addCheck("Camera available", camera ~= nil)
		addCheck("Input service available", UserInputService ~= nil)
		local runtime = localPlayerGui and localPlayerGui:FindFirstChild("TargetKitRuntime")
		local restored = false
		if not runtime and localPlayerGui and ensureRuntimeMarker then
			runtime = ensureRuntimeMarker()
			restored = runtime ~= nil
		end
		addCheck(restored and "Runtime marker present (was missing, restored)" or "Runtime marker present", runtime ~= nil)
		local allPassed = true
		for _, line in checks do
			if string.sub(line, 1, 6) == "[FAIL]" then allPassed = false break end
		end
		self._selfCheckLabel.Text = (allPassed and "SELF-CHECK · PASS\n" or "SELF-CHECK · ATTENTION\n") .. table.concat(checks, "\n")
		self._selfCheckLabel.TextColor3 = allPassed and THEME.HealthHigh or THEME.HealthLow
	end)
	self:_addSlider(perfPage, "Max distance", 30, 1000,
		function() return cfg.MaxDistance end,
		function(value) cfg.MaxDistance = math.floor(value) end,
		function(value) return string.format("%d st", value) end)
	self:_addSlider(perfPage, "Update rate", 5, 120,
		function() return cfg.UpdateHz end,
		function(value) cfg.UpdateHz = math.floor(value) end,
		function(value) return string.format("%d Hz", value) end)
	self:_addSlider(perfPage, "ESP highlight budget", 1, 31,
		function() return cfg.HighlightLimit end,
		function(value) cfg.HighlightLimit = math.clamp(math.floor(value), 1, 31) end,
		function(value) return string.format("%d / 31", value) end)

	self:_selectTab("Visuals")
end

function TargetKitUI:SetRuntimeStatus(status, detail)
	if self.StatusLabel and self.StatusLabel.Parent then
		self.StatusLabel.Text = tostring(status or "UNKNOWN") .. (detail and (" • " .. tostring(detail)) or "")
		if status == "READY" then
			self.StatusLabel.BackgroundColor3 = Color3.fromRGB(38, 105, 75)
			self.StatusLabel.TextColor3 = Color3.fromRGB(180, 255, 210)
		elseif status == "ERROR" then
			self.StatusLabel.BackgroundColor3 = Color3.fromRGB(125, 45, 55)
			self.StatusLabel.TextColor3 = Color3.fromRGB(255, 205, 205)
		else
			self.StatusLabel.BackgroundColor3 = Color3.fromRGB(65, 58, 78)
			self.StatusLabel.TextColor3 = THEME.Sub
		end
	end
end

function TargetKitUI:SetVisible(visible)
	self.Gui.Enabled = visible
end

function TargetKitUI:_bindInput()
	local gradientAccumulator = 0
	local diagnosticsAccumulator = 0
	local fpsAverage = 0
	self._maid:Connect(RunService.RenderStepped, function(dt)
		if not self.Gui.Enabled or not self.Window.Visible then
			gradientAccumulator = 0
			diagnosticsAccumulator = 0
			return
		end
		gradientAccumulator += dt
		if gradientAccumulator >= 1 / 30 then
			self._strokeGradient.Rotation = (self._strokeGradient.Rotation + gradientAccumulator * 60) % 360
			gradientAccumulator = 0
		end

		local performancePage = self._pages.Performance
		if performancePage and performancePage.Visible and self._diagnosticLabel then
			diagnosticsAccumulator += dt
			if diagnosticsAccumulator >= 0.25 then
				diagnosticsAccumulator %= 0.25
				local cfg = self.Kit.Config
				local d = self.Kit.Diagnostics
				local camera = Workspace.CurrentCamera
				if dt > 0 and dt == dt and dt < math.huge then
					local instantFPS = 1 / dt
					fpsAverage = fpsAverage == 0
						and instantFPS
						or (fpsAverage * 0.9 + instantFPS * 0.1)
				end
				local fps = math.floor(fpsAverage + 0.5)
				local uptime = math.max(0, os.clock() - TARGETKIT_BOOT_TIME)
				local inputMode = IS_PC and "PC" or (UserInputService.TouchEnabled and "MOBILE" or "OTHER")
				local performanceLine
				if cfg.DiagnosticsEnabled then
					performanceLine = string.format(
						"UPDATE %.2f / %.2f ms · VISUAL %.2f ms\nSELECT %.2f ms · LOS %d · TARGETS %d\nPENDING %d · OUTLINES %d/31 · HEARTBEAT %d Hz",
						d.AverageUpdateMs, d.PeakUpdateMs, d.VisualUpdateMs,
						d.LastSelectionMs, d.LastSelectionRaycasts, d.TargetCount,
						d.PendingTargets, d.ActiveHighlights, math.floor(d.HeartbeatRate + 0.5)
					)
				else
					performanceLine = "PERFORMANCE SAMPLING PAUSED"
				end
				self._diagnosticLabel.Text = string.format(
					"TARGETKIT v%s · %s\nINPUT %s · FPS ~%d · CAMERA %s\nUPTIME %02d:%02d · FAULTS %d · PAUSES %d\n%s",
					TARGETKIT_VERSION, TARGETKIT_CHANNEL, inputMode, fps,
					camera and "OK" or "MISSING",
					math.floor(uptime / 60), math.floor(uptime % 60),
					_runtimeFaultCount, _breakerTrips, performanceLine
				)
			end
		else
			diagnosticsAccumulator = 0
		end
	end)
	self._maid:Connect(UserInputService.InputBegan, function(input, processed)
		if not processed and not UserInputService:GetFocusedTextBox() and not GuiService.MenuIsOpen
			and input.KeyCode == Enum.KeyCode.RightShift then
			self:SetVisible(not self.Gui.Enabled)
		end
	end)
end

function TargetKitUI:Destroy()
	self._maid:Destroy()
end

------------------------------------------------------------------------
-- TargetInfoCard (HUD)
------------------------------------------------------------------------

local TargetInfoCard = {}
TargetInfoCard.__index = TargetInfoCard

function TargetInfoCard.new(kit)
	local self = setmetatable({}, TargetInfoCard)
	self.Kit = kit
	self._maid = Maid.new()
	self._shown = false

	local ok, err = xpcall(function()
		self.Gui = self._maid:Give(make("ScreenGui", {
			Name = "TargetInfoCard",
			ResetOnSpawn = false,
			DisplayOrder = 8,
			Parent = kit.Gui.Parent,
		}))

		-- Keep the active-target HUD at the bottom so it never covers the
		-- top-center Roblox status / menu area shown in the user's screenshot.
		self.Card = make("Frame", {
			Size = UDim2.fromOffset(240, 62), AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, 90), BackgroundColor3 = THEME.Bg,
			BackgroundTransparency = 0.05, Parent = self.Gui,
		}, {
			round(16),
			make("UIStroke", { Color = THEME.Blue, Thickness = 2 }),
		})
		self.NameLabel = make("TextLabel", {
			Size = UDim2.new(1, -90, 0, 22), Position = UDim2.fromOffset(14, 8),
			BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = THEME.Text, Parent = self.Card,
		})
		self.DistanceLabel = make("TextLabel", {
			Size = UDim2.fromOffset(70, 22), Position = UDim2.new(1, -82, 0, 8),
			BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Right,
			Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = THEME.Blue, Parent = self.Card,
		})
		local track = make("Frame", {
			Size = UDim2.new(1, -28, 0, 8), Position = UDim2.fromOffset(14, 38),
			BackgroundColor3 = THEME.Track, Parent = self.Card,
		}, { round(4) })
		self.Fill = make("Frame", {
			Size = UDim2.fromScale(1, 1), BackgroundColor3 = THEME.Pink, Parent = track,
		}, { round(4) })
		self.HealthLabel = make("TextLabel", {
			Size = UDim2.new(1, -28, 0, 12), Position = UDim2.fromOffset(14, 47),
			BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Right,
			Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = THEME.Sub, Parent = self.Card,
		})

		local updateAccumulator = 0
		self._maid:Connect(RunService.Heartbeat, function(dt)
			updateAccumulator += dt
			if updateAccumulator >= 0.08 then
				updateAccumulator %= 0.08
				self:_update()
			end
		end)
	end, debug.traceback)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

function TargetInfoCard:_slide(show)
	if self._shown == show then
		return
	end
	self._shown = show
	-- Slide in above the bottom edge; slide fully off-screen when unlocked.
	tween(self.Card, 0.3, { Position = UDim2.new(0.5, 0, 1, show and -16 or 90) })
end

function TargetInfoCard:_update()
	local record = self.Kit:GetAimRecord()
	local camera = Workspace.CurrentCamera
	local recordValid = record
		and record.Model:IsDescendantOf(Workspace)
		and record.Root:IsDescendantOf(record.Model)
		and record.Humanoid:IsDescendantOf(record.Model)
		and record.Humanoid.Health > 0
	if not (recordValid and camera) then
		self:_slide(false)
		return
	end
	self:_slide(true)
	local humanoid = record.Humanoid
	local distance = (record.Root.Position - camera.CFrame.Position).Magnitude
	local ratio = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
	self.NameLabel.Text = record.Model.Name
	self.DistanceLabel.Text = string.format("%d st", math.floor(distance))
	self.Fill.Size = UDim2.fromScale(ratio, 1)
	self.HealthLabel.Text = string.format("%.0f / %.0f", math.ceil(humanoid.Health), math.ceil(humanoid.MaxHealth))
end

function TargetInfoCard:Destroy()
	self._maid:Destroy()
end

------------------------------------------------------------------------
-- TargetKitPlayers (player adapter)
------------------------------------------------------------------------

local PLAYER_DEFAULTS = {
	TeamCheck = true, -- true: only other teams; false: free-for-all
	IgnoredUserIds = {},
}

local TargetKitPlayers = {}
TargetKitPlayers.__index = TargetKitPlayers

function TargetKitPlayers.new(kit, options)
	local self = setmetatable({}, TargetKitPlayers)
	self.Kit = kit
	self.Options = table.clone(PLAYER_DEFAULTS)
	self.Options.IgnoredUserIds = {}
	if options ~= nil and typeof(options) ~= "table" then
		warn("[TargetKitPlayers] options must be a table; defaults will be used")
		options = nil
	end
	for key, value in options or {} do
		if key == "IgnoredUserIds" and typeof(value) == "table" then
			for userKey, userValue in value do
				local userId
				if typeof(userKey) == "number" and userValue == true then
					userId = userKey
				elseif typeof(userValue) == "number" then
					userId = userValue
				end
				if userId and userId > 0 and userId == userId and userId < math.huge then
					self.Options.IgnoredUserIds[math.floor(userId)] = true
				end
			end
		elseif key == "TeamCheck" and typeof(value) == "boolean" then
			self.Options.TeamCheck = value
		elseif key ~= "IgnoredUserIds" then
			warn(("[TargetKitPlayers] invalid or unknown option '%s' ignored"):format(tostring(key)))
		end
	end
	self._destroyed = false
	self._maid = Maid.new()
	self._tracked = {} -- [Player] = Model currently registered with the kit
	self._playerMaids = {} -- [Player] = Maid
	self._localCharacterMaid = Maid.new()
	self._localCharacterToken = 0
	local ok, err = xpcall(function()
		self:_hookLocalCharacter()

		for _, player in Players:GetPlayers() do
			self:_track(player)
		end
		self._maid:Connect(Players.PlayerAdded, function(player)
			self:_track(player)
		end)
		self._maid:Connect(Players.PlayerRemoving, function(player)
			self:_untrack(player)
		end)
		self._maid:Connect(LocalPlayer:GetPropertyChangedSignal("Team"), function()
			self:RefreshAll()
		end)
	end, debug.traceback)
	if not ok then
		self:Destroy()
		error(err, 0)
	end
	return self
end

-- Local death/respawn lifecycle is tracked separately from target players.
-- Died disables Lock-On immediately; a fresh living character re-enables it.
function TargetKitPlayers:_bindLocalCharacter(character)
	self._localCharacterToken += 1
	local token = self._localCharacterToken
	self._localCharacterMaid:Clean()
	self.Kit:SetLocalAlive(false)

	if not character then
		return
	end

	task.spawn(function()
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid then
			return
		end
		if self._destroyed or token ~= self._localCharacterToken
			or LocalPlayer.Character ~= character then
			return
		end

		-- Subscribe before checking Health so a death during setup cannot be missed.
		local function isCurrentCharacter()
			return not self._destroyed
				and token == self._localCharacterToken
				and LocalPlayer.Character == character
		end
		self._localCharacterMaid:Connect(humanoid.Died, function()
			if isCurrentCharacter() then
				self.Kit:SetLocalAlive(false)
			end
		end)
		self._localCharacterMaid:Connect(humanoid.HealthChanged, function(health)
			if isCurrentCharacter() and health <= 0 then
				self.Kit:SetLocalAlive(false)
			end
		end)

		-- Never resume lock from a CharacterAdded event whose Humanoid is already dead.
		self.Kit:SetLocalAlive(humanoid.Health > 0)
	end)
end

function TargetKitPlayers:_hookLocalCharacter()
	self._maid:Connect(LocalPlayer.CharacterAdded, function(character)
		self:_bindLocalCharacter(character)
	end)
	self._maid:Connect(LocalPlayer.CharacterRemoving, function(character)
		if LocalPlayer.Character == character then
			self:_bindLocalCharacter(nil)
		end
	end)

	if LocalPlayer.Character then
		self:_bindLocalCharacter(LocalPlayer.Character)
	else
		self.Kit:SetLocalAlive(false)
	end
end

function TargetKitPlayers:SetTeamCheck(enabled)
	if self._destroyed then return end
	self.Options.TeamCheck = enabled == true
	self:RefreshAll()
end

function TargetKitPlayers:_shouldTarget(player)
	if player == LocalPlayer then
		return false
	end
	if self:IsIgnored(player) then
		return false
	end
	if not self.Options.TeamCheck then
		return true
	end
	local myTeam, theirTeam = LocalPlayer.Team, player.Team
	if myTeam == nil or theirTeam == nil then
		return true
	end
	return theirTeam ~= myTeam
end

-- Ignored players are removed from the registry immediately, so they cannot
-- remain selected or be reacquired by the lock-maintenance loop.
function TargetKitPlayers:IsIgnored(player)
	return typeof(player) == "Instance"
		and player:IsA("Player")
		and self.Options.IgnoredUserIds[player.UserId] == true
end

function TargetKitPlayers:SetIgnored(player, ignored)
	if self._destroyed or typeof(player) ~= "Instance" or not player:IsA("Player") or player == LocalPlayer then
		return false
	end
	if ignored == true then
		self.Options.IgnoredUserIds[player.UserId] = true
	else
		self.Options.IgnoredUserIds[player.UserId] = nil
	end
	self:_refresh(player)
	return true
end

function TargetKitPlayers:_release(player)
	local character = self._tracked[player]
	if character then
		self._tracked[player] = nil
		self.Kit:SetTargetOutlineColor(character, nil)
		self.Kit:RemoveTarget(character)
	end
end

function TargetKitPlayers:_refresh(player)
	if self._destroyed then return end
	self:_release(player)
	local character = player.Character
	if not character or not self:_shouldTarget(player) then
		return
	end

	-- AddTarget already watches incomplete rigs. Register immediately instead
	-- of waiting up to 5-10 seconds for named body parts; this also supports
	-- custom rigs that provide a valid PrimaryPart rather than an HRP.
	self._tracked[player] = character
	local teamColor = player.Team and player.TeamColor.Color or nil
	self.Kit:SetTargetOutlineColor(character, teamColor)
	self.Kit:AddTarget(character)

	-- The color is stored on the kit before registration, so it will also be
	-- applied later if AddTarget has to wait for the rig to finish loading.
	local record = self.Kit:GetRecord(character)
	if record and record.Highlight then
		record.Highlight.OutlineColor = teamColor or THEME.Pink
	end
end

function TargetKitPlayers:RefreshAll()
	if self._destroyed then return end
	for _, player in Players:GetPlayers() do
		self:_refresh(player)
	end
end

function TargetKitPlayers:_track(player)
	if self._destroyed or player == LocalPlayer or self._playerMaids[player] then
		return
	end
	local maid = Maid.new()
	maid:Connect(player.CharacterAdded, function()
		self:_refresh(player)
	end)
	maid:Connect(player.CharacterRemoving, function()
		self:_release(player)
	end)
	maid:Connect(player:GetPropertyChangedSignal("Team"), function()
		self:_refresh(player)
	end)
	self._playerMaids[player] = maid
	self:_refresh(player)
end

function TargetKitPlayers:_untrack(player)
	self:_release(player)
	local maid = self._playerMaids[player]
	if maid then
		self._playerMaids[player] = nil
		maid:Destroy()
	end
end

function TargetKitPlayers:Destroy()
	if self._destroyed then return end
	self._destroyed = true
	local players = {}
	for player in self._playerMaids do
		table.insert(players, player)
	end
	for _, player in players do
		self:_untrack(player)
	end
	self._maid:Destroy()
	self._localCharacterToken += 1
	self._localCharacterMaid:Destroy()
end

------------------------------------------------------------------------
-- Bootstrap / safe re-execution guard
------------------------------------------------------------------------

-- This guard is scoped to this LocalPlayer's PlayerGui. It does not bypass
-- Roblox security or anti-cheat; it only shuts down an older copy of this UI.
local playerGui = LocalPlayer:WaitForChild("PlayerGui")
-- Keep the runtime shutdown marker in PlayerGui even when the visible UI
-- itself is parented to an executor-provided GUI container.
local RUNTIME_NAME = "TargetKitRuntime"
local previousRuntime = playerGui:FindFirstChild(RUNTIME_NAME)
if previousRuntime then
	local previousShutdown = previousRuntime:FindFirstChild("Shutdown")
	if not (previousShutdown and previousShutdown:IsA("BindableFunction")) then
		warn("[TargetKit] previous runtime has no valid shutdown handler; refusing duplicate startup")
		return
	end

	local ok, result = pcall(function()
		return previousShutdown:Invoke()
	end)
	if not ok or result ~= true then
		warn("[TargetKit] previous runtime did not confirm shutdown; refusing duplicate startup: "
			.. tostring(result))
		return
	end

	-- The previous runtime confirms teardown before its marker is removed.
	if previousRuntime.Parent then
		previousRuntime:Destroy()
	end
end

local BOOT_TIME = os.clock()
local runtimeFolder = nil
local shutdownFunction = nil
local shuttingDown = false
local shutdown -- defined below

local function buildRuntimeMarker(status)
	local folder = Instance.new("Folder")
	folder.Name = RUNTIME_NAME
	folder:SetAttribute("Version", TARGETKIT_VERSION)
	folder:SetAttribute("Build", TARGETKIT_BUILD)
	folder:SetAttribute("Channel", TARGETKIT_CHANNEL)
	folder:SetAttribute("Status", status)
	local fn = Instance.new("BindableFunction")
	fn.Name = "Shutdown"
	fn.OnInvoke = function()
		shutdown()
		return true
	end
	fn.Parent = folder
	folder.Parent = playerGui
	runtimeFolder = folder
	shutdownFunction = fn
	return folder
end

ensureRuntimeMarker = function()
	if shuttingDown then
		return nil
	end
	if runtimeFolder and runtimeFolder.Parent == playerGui then
		return runtimeFolder
	end
	local previousStatus = runtimeFolder and runtimeFolder:GetAttribute("Status") or "READY"
	return buildRuntimeMarker(previousStatus)
end

buildRuntimeMarker("STARTING")

local kit, playerAdapter, ui, infoCard
local shutdownConnection
local shutdownMarkerConnection
local watchdogConnection
local lastSettings = nil

local SETTINGS_FILE = "TargetKit_settings.json"
local CAN_PERSIST = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
local WATCHDOG_INTERVAL = 1 -- seconds between health checks
local MAX_REBUILDS_PER_MINUTE = 4

local function inputModeName()
	return IS_PC and "PC" or (UserInputService.TouchEnabled and "MOBILE" or "INPUT")
end

-- Snapshot of everything worth keeping across a rebuild or a restart.
local function captureSettings()
	if not (kit and not kit._destroyed and playerAdapter) then
		return lastSettings
	end
	local settings = {
		Config = table.clone(kit.Config),
		TeamCheck = playerAdapter.Options.TeamCheck,
		Ignored = {},
	}
	for userId in playerAdapter.Options.IgnoredUserIds do
		table.insert(settings.Ignored, userId)
	end
	table.sort(settings.Ignored)
	lastSettings = settings
	return settings
end

-- Deterministic JSON (sorted key/value pairs) so unchanged settings never rewrite the file.
local function encodeSettings(settings)
	local pairsList = {}
	for key, default in DEFAULTS do
		local kind = typeof(default)
		if kind == "number" or kind == "boolean" or kind == "string" then
			local value = settings.Config[key]
			if typeof(value) == kind then
				table.insert(pairsList, { key, value })
			end
		end
	end
	table.sort(pairsList, function(a, b) return a[1] < b[1] end)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode({
			Config = pairsList,
			TeamCheck = settings.TeamCheck,
			Ignored = settings.Ignored,
		})
	end)
	return ok and encoded or nil
end

local function readSavedSettings()
	if not CAN_PERSIST then
		return nil
	end
	local ok, decoded = pcall(function()
		if not isfile(SETTINGS_FILE) then
			return nil
		end
		return HttpService:JSONDecode(readfile(SETTINGS_FILE))
	end)
	if not ok or typeof(decoded) ~= "table" then
		return nil
	end
	local saved = { Config = {}, TeamCheck = decoded.TeamCheck, Ignored = {} }
	if typeof(decoded.Config) == "table" then
		for _, pair in decoded.Config do
			local key = typeof(pair) == "table" and pair[1] or nil
			if typeof(key) == "string" and DEFAULTS[key] ~= nil and typeof(pair[2]) == typeof(DEFAULTS[key]) then
				saved.Config[key] = pair[2]
			end
		end
	end
	if typeof(decoded.Ignored) == "table" then
		for _, userId in decoded.Ignored do
			if typeof(userId) == "number" then
				table.insert(saved.Ignored, userId)
			end
		end
	end
	return saved
end

local function defaultStartSettings()
	return {
		Config = { MaxDistance = 1000, UpdateHz = 120, LockSmoothing = 1.0, HighlightLimit = 31, FovRadius = 160 },
		TeamCheck = true, -- false = free-for-all
		Ignored = {},
	}
end

local function stopComponents()
	if playerAdapter then
		local ok, err = pcall(function() playerAdapter:Destroy() end)
		if not ok then
			warn("[TargetKit] player adapter cleanup failed: " .. tostring(err))
		end
		playerAdapter = nil
	end
	if kit then
		local ok, err = pcall(function() kit:Destroy() end)
		if not ok then
			warn("[TargetKit] shutdown failed: " .. tostring(err))
		end
		kit = nil
	end
	ui, infoCard = nil, nil
end

local function buildComponents(settings)
	return xpcall(function()
		kit = TargetKit.new(settings.Config)
		playerAdapter = TargetKitPlayers.new(kit, {
			TeamCheck = settings.TeamCheck == true,
			IgnoredUserIds = settings.Ignored,
		})
		ui = TargetKitUI.new(kit, playerAdapter)
		kit:Give(ui)
		infoCard = TargetInfoCard.new(kit)
		kit:Give(infoCard)
		kit:Give(playerAdapter)
		return kit
	end, debug.traceback)
end

local function announceReady()
	local marker = ensureRuntimeMarker()
	if marker then
		marker:SetAttribute("Status", "READY")
		marker:SetAttribute("StartedAt", os.time())
	end
	if ui then
		ui:SetRuntimeStatus("READY", inputModeName())
		ui.VersionLabel.Text = "TARGETKIT  v" .. TARGETKIT_VERSION .. "  \u{2022}  V3"
	end
end

shutdown = function()
	if shuttingDown then return end
	shuttingDown = true
	if watchdogConnection then
		watchdogConnection:Disconnect()
		watchdogConnection = nil
	end
	stopComponents()
	if shutdownConnection then
		shutdownConnection:Disconnect()
		shutdownConnection = nil
	end
	if shutdownMarkerConnection then
		shutdownMarkerConnection:Disconnect()
		shutdownMarkerConnection = nil
	end
	if runtimeFolder and runtimeFolder.Parent then
		pcall(function()
			runtimeFolder:SetAttribute("Status", "STOPPED")
			runtimeFolder:Destroy()
		end)
	end
end

-- If the experience deletes the marker, put it back so re-execution and the
-- self-check keep working.
shutdownMarkerConnection = playerGui.ChildRemoved:Connect(function(child)
	if child == runtimeFolder and not shuttingDown then
		task.defer(ensureRuntimeMarker)
	end
end)

-- Watchdog: rebuilds the overlay, settings window and target card if the
-- experience removes them, keeping settings, ignore list, window position and
-- Lock-On state. Gives up after repeated rebuilds so it cannot loop forever.
local function componentsHealthy()
	return kit ~= nil and not kit._destroyed
		and kit.Gui ~= nil and kit.Gui.Parent ~= nil
		and ui ~= nil and ui.Gui ~= nil and ui.Gui.Parent ~= nil
		and infoCard ~= nil and infoCard.Gui ~= nil and infoCard.Gui.Parent ~= nil
end

local function rebuildFromCurrentState()
	local settings = captureSettings() or defaultStartSettings()
	local wasLocked = kit ~= nil and (kit:IsLockEnabled() or kit:IsLockResumePending())
	local uiVisible = ui == nil or ui.Gui == nil or ui.Gui.Enabled
	local windowPosition = ui and ui.Window and ui.Window.Position or nil

	stopComponents()
	GUI_PARENT = resolveGuiParent()
	local ok, result = buildComponents(settings)
	if not ok then
		warn("[TargetKit] watchdog rebuild failed: " .. tostring(result))
		stopComponents()
		return false
	end
	if windowPosition then
		ui.Window.Position = windowPosition
	end
	ui:SetVisible(uiVisible)
	if wasLocked then
		kit:RestoreLock()
	end
	announceReady()
	warn("[TargetKit] interface was removed; watchdog rebuilt it with your settings")
	return true
end

local rebuildTimes = {}
local watchdogAccumulator = 0
local lastSavedJson = nil

local function watchdogStep(dt)
	if shuttingDown then
		return
	end
	watchdogAccumulator += dt
	if watchdogAccumulator < WATCHDOG_INTERVAL then
		return
	end
	watchdogAccumulator = 0

	ensureRuntimeMarker()
	if not componentsHealthy() then
		local now = os.clock()
		local recent = {}
		for _, stamp in rebuildTimes do
			if now - stamp < 60 then
				table.insert(recent, stamp)
			end
		end
		rebuildTimes = recent
		if #rebuildTimes >= MAX_REBUILDS_PER_MINUTE then
			warn("[TargetKit] interface keeps being removed; watchdog is stopping TargetKit")
			shutdown()
			return
		end
		table.insert(rebuildTimes, now)
		rebuildFromCurrentState()
		return
	end

	if CAN_PERSIST then
		local settings = captureSettings()
		local encoded = settings and encodeSettings(settings)
		if encoded and encoded ~= lastSavedJson then
			lastSavedJson = encoded
			pcall(writefile, SETTINGS_FILE, encoded)
		end
	end
end

-- Startup: saved settings are applied first; if they ever stop TargetKit from
-- starting, it retries once with defaults instead of failing outright.
local startSettings = defaultStartSettings()
local saved = readSavedSettings()
if saved then
	for key, value in saved.Config do
		startSettings.Config[key] = value
	end
	if typeof(saved.TeamCheck) == "boolean" then
		startSettings.TeamCheck = saved.TeamCheck
	end
	startSettings.Ignored = saved.Ignored
end

local ok, result = buildComponents(startSettings)
if not ok and saved then
	warn("[TargetKit] saved settings failed to load; retrying with defaults: " .. tostring(result))
	stopComponents()
	ok, result = buildComponents(defaultStartSettings())
end
if not ok then
	warn("[TargetKit] initialization failed; rolling back: " .. tostring(result))
	shutdown()
	return
end

announceReady()
captureSettings()
print(("[TargetKit] v%s | %s | %s | READY | %s input | diagnostics online | watchdog on"):format(
	TARGETKIT_VERSION,
	TARGETKIT_BUILD,
	TARGETKIT_CHANNEL,
	IS_PC and "PC" or (UserInputService.TouchEnabled and "MOBILE" or "OTHER")
))

watchdogConnection = RunService.Heartbeat:Connect(function(dt)
	protectedCallback("watchdog", watchdogStep, dt)
end)

-- `script` exists for a LocalScript, but is nil when this chunk is run via
-- loadstring. The PlayerGui runtime shutdown function remains available in
-- either environment.
local sourceScript = script
if typeof(sourceScript) == "Instance" then
	shutdownConnection = sourceScript.Destroying:Connect(shutdown)
end
