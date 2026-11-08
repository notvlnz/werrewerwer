-- Private worker configuration. Load before worker/cac-worker.luau.
local OUTFITY_CAC_CONFIG = {
  firebaseUrl = "https://importer-41f0d-default-rtdb.firebaseio.com/",
  apiKey = "AIzaSyC27Wj2awyQuzBjja4kd3t32E21oM6Sd3Y"
}

-- Outfity CAC worker: same v1/v2 Firebase payloads and game remotes.
-- See worker/README.md before replacing an existing worker.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local playerDeadline = os.clock() + 30
while not Player and os.clock() < playerDeadline do
	task.wait(0.1)
	Player = Players.LocalPlayer
end
assert(Player, "Run this worker in its existing Roblox client environment, not a server Script")

-- The generated file supplies a chunk-local config, with no getgenv dependency.
-- Normal indexing also supports environments exposing globals through __index.
local config = OUTFITY_CAC_CONFIG
if typeof(config) ~= "table" then
	local ok, environment = pcall(function()
		return typeof(getgenv) == "function" and getgenv() or _G
	end)
	config = ok and environment and environment.OUTFITY_CAC_CONFIG or {}
end
if typeof(config) ~= "table" then config = {} end
local FIREBASE_URL = tostring(config.firebaseUrl or ""):gsub("/+$", "") .. "/"
local API_KEY = tostring(config.apiKey or "")

local POLL_INTERVAL = 0.4
local SHOW_LOG_GUI = config.showLogGui ~= false
local FPS_CAP = 30
local DISABLE_AUDIO = true
local AUTH_REFRESH_MARGIN = 300
local MAX_LOG_LINES = 30
local CLAIM_TIMEOUT = 60
local MAX_JOB_ATTEMPTS = 4
local WORKER_VERSION = "queue-v4"
local HTTP_MAX_ATTEMPTS = 3
local HTTP_RETRY_BASE = 0.12
local HTTP_TIMEOUT = 8

local APPLY_WAIT_WINDOW = 5.0
local APPLY_POLL_STEP = 0.08
local APPLY_STABLE_POLLS = 2
local BETWEEN_OUTFITS_DELAY = 0.2
local MAX_CODES = 25
local MAX_SAFE_INTEGER = 9007199254740991
local AUTH_FAILURE_DELAY = 5
local OUTFIT_BUSY_RETRY_DELAYS = { 2, 4, 8 }

local PlayerGui = SHOW_LOG_GUI and Player:WaitForChild("PlayerGui", 8) or nil
local CommunityRemote, CatalogGuiRemote, UpdateStatusRemote
local clientId = nil
local clientIdRequested = false
local requireCharacterReset = false
local workerReadyAt = 0
local busyStreak = 0
local lastRequestId = nil

local active = true
local currentIdToken = nil
local tokenExpiresAt = 0
local refreshToken = nil
local resetNeeded = false
local lastWorkFinishedAt = 0

local MY_USER_ID = tostring(Player.UserId)
local WORKER_INSTANCE_ID = MY_USER_ID .. ":" .. HttpService:GenerateGUID(false)

local requestImpl = (syn and syn.request) or (http and http.request) or request
local log

local function responseOk(response)
	local status = tonumber(response and response.StatusCode) or 0
	return status >= 200 and status < 300
end

local function expired(data)
	return typeof(data) == "table" and tonumber(data.expiresAt) ~= nil
		and tonumber(data.expiresAt) <= DateTime.now().UnixTimestampMillis
end

local function retryableResult(result)
	if typeof(result) ~= "table" or typeof(result.error) ~= "string" then return false end
	return result.retryable == true
		or result.error == "CAC is on cooldown. Please wait before importing again."
		or result.error == "The outfit service is busy. Please try again shortly."
end

local function attemptCount(current)
	local value = tonumber(current.attempts)
	return value and value == value and value >= 0 and value < math.huge and math.floor(value) or 0
end

local function claimAvailable(current)
	if typeof(current) ~= "table" or expired(current) then
		return false
	end
	if current.result ~= nil and not (retryableResult(current.result) and attemptCount(current) < MAX_JOB_ATTEMPTS) then return false end
	local retryAfter = tonumber(current.retryAfter)
	if retryAfter and retryAfter > DateTime.now().UnixTimestampMillis then return false end
	if current.result ~= nil and current.processing ~= true then return true end
	local claimedAt = tonumber(current.claimedAt)
	if claimedAt and claimedAt > 100000000000 then
		claimedAt = claimedAt / 1000
	end
	local timedOut = claimedAt and current.claimedBy and os.time() - claimedAt >= CLAIM_TIMEOUT
	return not (current.claimedBy or current.processing) or timedOut == true
end

local function roundNumber(value, decimals)
	if typeof(value) ~= "number" or value ~= value then
		return 0
	end

	local factor = 10 ^ (decimals or 3)
	return math.floor(value * factor + 0.5) / factor
end

local function optimizeGraphics()
	local fpsCapApplied = false
	if typeof(setfpscap) == "function" then
		fpsCapApplied = pcall(setfpscap, FPS_CAP)
	end

	pcall(function()
		settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
	end)
	local renderingDisabled = pcall(function()
		RunService:Set3dRenderingEnabled(false)
	end)

	if not renderingDisabled then
		Lighting.GlobalShadows = false
		Lighting.Brightness = 1
		Lighting.Ambient = Color3.new(1, 1, 1)
		Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
		Lighting.EnvironmentDiffuseScale = 0
		Lighting.EnvironmentSpecularScale = 0
		Lighting.Technology = Enum.Technology.Compatibility

		for _, effect in ipairs(Lighting:GetChildren()) do
			if effect:IsA("PostEffect") then
				effect.Enabled = false
			end
		end

		local terrain = Workspace:FindFirstChildOfClass("Terrain")
		if terrain then
			terrain.WaterReflectance = 0
			terrain.WaterTransparency = 1
			terrain.WaterWaveSize = 0
			terrain.WaterWaveSpeed = 0
		end

		for _, obj in ipairs(Workspace:GetDescendants()) do
			if obj:IsA("Texture") or obj:IsA("Decal") then
				obj.Texture = ""
			elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") then
				obj.Enabled = false
			end
		end
	end

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	end)
	pcall(function()
		StarterGui:SetCore("ChatActive", false)
	end)

	pcall(function()
		UserInputService.MouseIconEnabled = false
	end)

	if DISABLE_AUDIO then
		pcall(function()
			UserSettings():GetService("UserGameSettings").MasterVolume = 0
		end)
		pcall(function()
			SoundService.AmbientReverb = Enum.ReverbType.NoReverb
			SoundService.DopplerScale = 0
		end)
		for _, sound in ipairs(SoundService:GetDescendants()) do
			if sound:IsA("Sound") then
				sound:Stop()
				sound.Volume = 0
			end
		end
	end

	local fpsStatus = fpsCapApplied and (tostring(FPS_CAP) .. " FPS") or "FPS cap unsupported"
	log("Headless optimizations enabled - " .. fpsStatus)
end

local function createCleanLogger()
	if not SHOW_LOG_GUI or not PlayerGui then
		return function(message)
			print("[CAC] " .. message)
		end
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "CACLogger"
	gui.ResetOnSpawn = false
	gui.Parent = PlayerGui

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(540, 320)
	frame.Position = UDim2.fromOffset(16, 16)
	frame.BackgroundColor3 = Color3.fromRGB(17, 17, 23)
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local logBox = Instance.new("TextLabel")
	logBox.Size = UDim2.fromScale(1, 1)
	logBox.BackgroundTransparency = 1
	logBox.TextColor3 = Color3.new(1, 1, 1)
	logBox.Font = Enum.Font.Code
	logBox.TextSize = 13.5
	logBox.TextXAlignment = Enum.TextXAlignment.Left
	logBox.TextYAlignment = Enum.TextYAlignment.Top
	logBox.TextWrapped = false
	logBox.Text = "[CAC] Logger started - " .. os.date("%H:%M:%S") .. " - Worker " .. MY_USER_ID
	logBox.Parent = frame

	local function addLine(message)
		print("[CAC] " .. message)
		if not logBox.Parent then
			return
		end

		logBox.Text = logBox.Text .. "\n" .. message
		local lines = string.split(logBox.Text, "\n")
		if #lines > MAX_LOG_LINES then
			logBox.Text = table.concat(lines, "\n", #lines - MAX_LOG_LINES + 1)
		end
	end

	local stopButton = Instance.new("TextButton")
	stopButton.Size = UDim2.fromOffset(86, 26)
	stopButton.Position = UDim2.new(1, -94, 0, 6)
	stopButton.BackgroundColor3 = Color3.fromRGB(210, 60, 60)
	stopButton.TextColor3 = Color3.new(1, 1, 1)
	stopButton.Font = Enum.Font.Code
	stopButton.TextSize = 13
	stopButton.Text = "STOP"
	stopButton.Parent = frame
	stopButton.MouseButton1Click:Connect(function()
		active = false
		gui:Destroy()
		warn("[CAC] Listener manually terminated")
	end)

	return addLine
end

log = createCleanLogger()
log("Starting CAC worker " .. WORKER_VERSION .. " - " .. WORKER_INSTANCE_ID)

local function initializeWorker()
	if not (FIREBASE_URL:match("^https://[^/]+/$") and API_KEY ~= "") then
		log("Startup stopped: Firebase configuration is missing. Use the generated configured file.")
		return false
	end
	log("Waiting for CAC game remotes")
	local events = ReplicatedStorage:WaitForChild("Events", 30)
	if not active then return false end
	CommunityRemote = events and events:WaitForChild("CommunityOutfitsRemote", 30)
	if not active then return false end
	-- Current client scripts use Events.CatalogGuiRemote. The root location
	-- is retained only for older deployments. Direct JSON reads do not need it.
	CatalogGuiRemote = (events and events:FindFirstChild("CatalogGuiRemote"))
		or ReplicatedStorage:FindFirstChild("CatalogGuiRemote")
	if not active then return false end
	UpdateStatusRemote = events and events:FindFirstChild("UpdatePlayerStatus")
	if not CommunityRemote then
		log("Startup stopped: CAC remotes were not found. Join the CAC game before starting this script.")
		return false
	end
	return true
end

local function performRequest(options)
	if typeof(requestImpl) == "function" then
		return requestImpl(options)
	end

	local nativeOptions = table.clone(options)
	nativeOptions.Timeout = nil -- Executor-specific; not a RequestAsync field.
	return HttpService:RequestAsync(nativeOptions)
end

local function performJsonRequest(method, url, body, extraHeaders, maxAttempts)
	local headers = {
		["Content-Type"] = "application/json",
	}
	for key, value in pairs(extraHeaders or {}) do
		headers[key] = value
	end

	local attempts = maxAttempts or HTTP_MAX_ATTEMPTS
	local encodedBody = typeof(body) == "string" and body or (body and HttpService:JSONEncode(body) or nil)
	local lastResponse = nil
	for attempt = 1, attempts do
		local success, response = pcall(function()
			return performRequest({
				Url = url,
				Method = method,
				Headers = headers,
				Body = encodedBody,
				Timeout = HTTP_TIMEOUT,
			})
		end)

		if success and response then
			lastResponse = response
			local status = tonumber(response.StatusCode) or 0
			if status >= 200 and status < 300 then
				local ok, decoded = pcall(function()
					return HttpService:JSONDecode(response.Body)
				end)
				return ok and decoded or nil, response
			end

			if (status == 401 or status == 403) and string.sub(url, 1, #FIREBASE_URL) == FIREBASE_URL then
				currentIdToken = nil
				tokenExpiresAt = 0
			end

			if status ~= 408 and status ~= 429 and status < 500 then
				break
			end
		end

		if attempt < attempts then
			task.wait(HTTP_RETRY_BASE * 2 ^ (attempt - 1) + math.random() * 0.05)
		end
	end

	return nil, lastResponse
end

local function refreshAuthToken()
	log("Refreshing Firebase token")
	local data
	if refreshToken then
		data = performJsonRequest("POST", "https://securetoken.googleapis.com/v1/token?key=" .. API_KEY,
			"grant_type=refresh_token&refresh_token=" .. HttpService:UrlEncode(refreshToken), {
				["Content-Type"] = "application/x-www-form-urlencoded",
			})
	else
		data = performJsonRequest("POST", "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=" .. API_KEY, {
			returnSecureToken = true,
		})
	end

	if typeof(data) ~= "table" or not (data.idToken or data.id_token) then
		log("Firebase auth failed")
		return false
	end

	currentIdToken = data.idToken or data.id_token
	refreshToken = data.refreshToken or data.refresh_token or refreshToken
	local lifetime = tonumber(data.expiresIn or data.expires_in) or 3600
	tokenExpiresAt = os.clock() + math.max(1, lifetime - math.min(AUTH_REFRESH_MARGIN, lifetime / 2))
	log("Token refreshed")
	return true
end

local function ensureAuthToken()
	if currentIdToken and os.clock() < tokenExpiresAt then
		return true
	end

	return refreshAuthToken()
end

local function getRequests()
	if not ensureAuthToken() then
		return nil
	end

	local data, response = performJsonRequest("GET", FIREBASE_URL .. "requests.json?auth=" .. currentIdToken)
	if not responseOk(response) then
		log("Queue unavailable (HTTP " .. tostring(response and response.StatusCode or "network error") .. ")")
		return nil
	end
	return typeof(data) == "table" and data or {}
end

local function getResponseHeader(response, wantedName)
	for name, value in pairs((response and response.Headers) or {}) do
		if string.lower(tostring(name)) == string.lower(wantedName) then
			return value
		end
	end
	return nil
end

local function tryClaimPath(relativePath, expiresAt)
	if (expiresAt and expiresAt <= DateTime.now().UnixTimestampMillis) or not ensureAuthToken() then
		return false
	end

	local url = FIREBASE_URL .. relativePath .. ".json?auth=" .. currentIdToken
	local current, getResponse = performJsonRequest("GET", url, nil, {
		["X-Firebase-ETag"] = "true",
	})
	if not claimAvailable(current) then
		return false
	end

	local claimedAt = tonumber(current.claimedAt)
	if claimedAt and claimedAt > 100000000000 then
		claimedAt = claimedAt / 1000
	end
	local timedOut = claimedAt and current.claimedBy and (os.time() - claimedAt >= CLAIM_TIMEOUT) or false

	local etag = getResponseHeader(getResponse, "ETag")
	if not etag then
		log("Claim failed (no Firebase ETag) -> " .. relativePath)
		return false
	end

	local claimId = HttpService:GenerateGUID(false)
	current.attempts = attemptCount(current) + 1
	current.claimedBy = MY_USER_ID
	current.claimId = claimId
	current.workerInstanceId = WORKER_INSTANCE_ID
	current.workerVersion = WORKER_VERSION
	current.claimedAt = { [".sv"] = "timestamp" }
	current.processing = true
	current.result = nil
	current.retryAfter = nil
	current.finishedAt = nil

	local _, putResponse = performJsonRequest("PUT", url, current, {
		["if-match"] = etag,
	}, 1)
	if not responseOk(putResponse) then
		if putResponse and putResponse.StatusCode == 412 then
			log("Claim lost race -> " .. relativePath)
		end
		return false
	end

	log((timedOut and "Reclaimed timed out -> " or "Claimed -> ") .. relativePath)
	return claimId
end

local function tryClaim(requestId, expiresAt)
	return tryClaimPath("requests/" .. requestId, expiresAt)
end

local function tryClaimJob(requestId, jobId, expiresAt)
	return tryClaimPath("requests/" .. requestId .. "/jobs/" .. jobId, expiresAt)
end

local function updateClaimPath(relativePath, claimId, expiresAt, update)
	for _ = 1, 2 do
		if expiresAt and expiresAt <= DateTime.now().UnixTimestampMillis then
			return false
		end
		if not ensureAuthToken() then
			continue
		end

		local url = FIREBASE_URL .. relativePath .. ".json?auth=" .. currentIdToken
		local current, getResponse = performJsonRequest("GET", url, nil, {
			["X-Firebase-ETag"] = "true",
		})
		if typeof(current) ~= "table" or current.claimedBy ~= MY_USER_ID
			or current.claimId ~= claimId or current.result ~= nil or expired(current) then
			return false
		end

		local etag = getResponseHeader(getResponse, "ETag")
		if not etag then
			return false
		end

		update(current)

		local _, putResponse = performJsonRequest("PUT", url, current, {
			["if-match"] = etag,
		}, 1)
		if responseOk(putResponse) then
			return true, current
		end
		if not putResponse or putResponse.StatusCode ~= 412 then
			return false
		end
	end
	return false
end

local function completeClaimPath(relativePath, payload, claimId, expiresAt)
	return updateClaimPath(relativePath, claimId, expiresAt, function(current)
		current.result = payload
		current.processing = false
		current.retryAfter = nil
		current.lastError = nil
		current.finishedAt = os.time()
	end)
end

local function deferClaimPath(relativePath, payload, claimId, expiresAt)
	local saved, current = updateClaimPath(relativePath, claimId, expiresAt, function(record)
		record.processing = false
		if attemptCount(record) >= MAX_JOB_ATTEMPTS then
			record.result = { error = "The outfit service is still busy after several attempts. Please try again shortly." }
			record.finishedAt = os.time()
			return
		end
		local delay = OUTFIT_BUSY_RETRY_DELAYS[math.max(1, attemptCount(record))] or OUTFIT_BUSY_RETRY_DELAYS[#OUTFIT_BUSY_RETRY_DELAYS]
		record.result = nil
		record.lastError = payload.error
		record.retryAfter = DateTime.now().UnixTimestampMillis + delay * 1000
		record.claimedBy, record.claimId, record.claimedAt = nil, nil, nil
		record.workerInstanceId = nil
	end)
	return saved, saved and current.result == nil
end

local function sendResult(requestId, payload, claimId, expiresAt)
	if completeClaimPath("requests/" .. requestId, payload, claimId, expiresAt) then
		log("Result sent for " .. requestId)
	else
		log("Failed to send result for " .. requestId)
	end
end

local function sendJobResult(requestId, jobId, payload, claimId, expiresAt)
	local sent = completeClaimPath("requests/" .. requestId .. "/jobs/" .. jobId, payload, claimId, expiresAt)
	log((sent and "Job result sent for " or "Failed to send job result for ") .. requestId .. "/" .. jobId)
	return sent
end

local function forceResetCharacter()
	if not CatalogGuiRemote then return end
	pcall(function()
		CatalogGuiRemote:InvokeServer({
			Action = "MorphIntoPlayer",
			UserId = Player.UserId,
			RigType = Enum.HumanoidRigType.R15,
		})
	end)
	pcall(function()
		if UpdateStatusRemote then
			UpdateStatusRemote:FireServer("None")
		end
	end)
	log("Character reset")
end

local function getCharacterHumanoid(timeoutSeconds)
	local deadline = os.clock() + (timeoutSeconds or 3)
	repeat
		local character = Player.Character
		if character and character.Parent then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return character, humanoid
			end
		end
		task.wait(0.05)
	until os.clock() >= deadline

	return nil, nil
end

local function getHumanoidDescriptionObject(humanoid, timeoutSeconds)
	local deadline = os.clock() + (timeoutSeconds or 2)
	repeat
		if not humanoid then
			break
		end

		local description = humanoid:FindFirstChild("HumanoidDescription")
		if description and description:IsA("HumanoidDescription") then
			return description
		end

		task.wait(0.05)
	until os.clock() >= deadline

	return nil
end

local function getAccessoryTypeName(accessoryType)
	if typeof(accessoryType) == "EnumItem" then
		return accessoryType.Name
	end

	return tostring(accessoryType or "Hat")
end

local function serializeAccessories(description)
	local ok, accessories = pcall(function()
		return description:GetAccessories(true)
	end)
	if not ok or typeof(accessories) ~= "table" then
		return {}
	end

	local result = {}
	for _, accessory in ipairs(accessories) do
		local entry = {
			assetId = tonumber(accessory.AssetId) or 0,
			type = getAccessoryTypeName(accessory.AccessoryType),
			isLayered = accessory.IsLayered == true,
		}

		if accessory.Order ~= nil then
			entry.order = tonumber(accessory.Order) or accessory.Order
		end
		if accessory.Puffiness ~= nil then
			entry.puffiness = roundNumber(tonumber(accessory.Puffiness) or 0, 3)
		end

		table.insert(result, entry)
	end

	table.sort(result, function(a, b)
		if a.type ~= b.type then
			return a.type < b.type
		end
		if (a.order or 0) ~= (b.order or 0) then
			return (a.order or 0) < (b.order or 0)
		end
		return (a.assetId or 0) < (b.assetId or 0)
	end)

	return result
end

local function getAccessoryFingerprint(description)
	local accessories = serializeAccessories(description)
	local parts = {}
	for _, accessory in ipairs(accessories) do
		parts[#parts + 1] = table.concat({
			tostring(accessory.assetId or 0),
			tostring(accessory.type or "Hat"),
			tostring(accessory.isLayered and true or false),
			tostring(accessory.order or 0),
			tostring(accessory.puffiness or 0),
		}, "|")
	end

	return table.concat(parts, ",")
end

local function buildDescriptionFingerprint(humanoid, description)
	if not humanoid or not description then
		return nil
	end

	return table.concat({
		humanoid.RigType.Name,
		tostring(description.Shirt or 0),
		tostring(description.Pants or 0),
		tostring(description.GraphicTShirt or 0),
		tostring(description.Head or 0),
		tostring(description.Torso or 0),
		tostring(description.LeftArm or 0),
		tostring(description.RightArm or 0),
		tostring(description.LeftLeg or 0),
		tostring(description.RightLeg or 0),
		tostring(description.Face or 0),
		description.HeadColor:ToHex(),
		description.TorsoColor:ToHex(),
		description.LeftArmColor:ToHex(),
		description.RightArmColor:ToHex(),
		description.LeftLegColor:ToHex(),
		description.RightLegColor:ToHex(),
		tostring(roundNumber(description.HeightScale or 0, 4)),
		tostring(roundNumber(description.WidthScale or 0, 4)),
		tostring(roundNumber(description.HeadScale or 0, 4)),
		tostring(roundNumber(description.DepthScale or 0, 4)),
		tostring(roundNumber(description.ProportionScale or 0, 4)),
		tostring(roundNumber(description.BodyTypeScale or 0, 4)),
		tostring(description.WalkAnimation or 0),
		tostring(description.RunAnimation or 0),
		tostring(description.JumpAnimation or 0),
		tostring(description.IdleAnimation or 0),
		tostring(description.FallAnimation or 0),
		tostring(description.SwimAnimation or 0),
		tostring(description.ClimbAnimation or 0),
		tostring(description.MoodAnimation or 0),
		getAccessoryFingerprint(description),
	}, ";")
end

local function waitForFreshDescription(beforeFingerprint, applied)
	local deadline = os.clock() + APPLY_WAIT_WINDOW
	local bestHumanoid = nil
	local bestDescription = nil
	local changedHumanoid = nil
	local changedDescription = nil
	local lastChangedFingerprint = nil
	local stablePolls = 0

	repeat
		local _, humanoid = getCharacterHumanoid(0.8)
		if humanoid then
			local description = getHumanoidDescriptionObject(humanoid, 0.25)
			if description then
				local fingerprint = buildDescriptionFingerprint(humanoid, description)
				bestHumanoid = humanoid
				bestDescription = description

				-- A confirmed application can also be the exact same outfit.
				if fingerprint ~= beforeFingerprint or (applied and applied.fingerprint == fingerprint) then
					changedHumanoid = humanoid
					changedDescription = description

					if fingerprint == lastChangedFingerprint then
						stablePolls = stablePolls + 1
					else
						lastChangedFingerprint = fingerprint
						stablePolls = 1
					end

					if stablePolls >= APPLY_STABLE_POLLS then
						task.wait(0.08)
						return changedHumanoid, changedDescription
					end
				end
			end
		end

		task.wait(APPLY_POLL_STEP)
	until os.clock() >= deadline

	if changedHumanoid and changedDescription then
		return changedHumanoid, changedDescription
	end

	return bestHumanoid, bestDescription
end

local ANIMATION_PROPERTIES = {
	{ key = "walk", property = "WalkAnimation" },
	{ key = "run", property = "RunAnimation" },
	{ key = "jump", property = "JumpAnimation" },
	{ key = "idle", property = "IdleAnimation" },
	{ key = "fall", property = "FallAnimation" },
	{ key = "swim", property = "SwimAnimation" },
	{ key = "climb", property = "ClimbAnimation" },
	{ key = "mood", property = "MoodAnimation" },
}

local function serializeAnimations(description)
	local animations = {}

	for _, animation in ipairs(ANIMATION_PROPERTIES) do
		animations[animation.key] = tonumber(description[animation.property]) or 0
	end
	return animations
end

local function descriptionToResult(humanoid, description)
	if not humanoid or not description then
		return { error = "Failed to read outfit" }
	end

	local accessories = serializeAccessories(description)
	local animations = serializeAnimations(description)

	return {
		RigType = humanoid.RigType.Name,
		Colors = {
			Head = description.HeadColor:ToHex(),
			Torso = description.TorsoColor:ToHex(),
			LeftArm = description.LeftArmColor:ToHex(),
			RightArm = description.RightArmColor:ToHex(),
			LeftLeg = description.LeftLegColor:ToHex(),
			RightLeg = description.RightLegColor:ToHex(),
		},
		Clothing = {
			Shirt = description.Shirt or 0,
			Pants = description.Pants or 0,
			TShirt = description.GraphicTShirt or 0,
		},
		Accessories = {
			Other = accessories,
		},
		Scales = {
			Height = roundNumber(description.HeightScale or 0, 4),
			Width = roundNumber(description.WidthScale or 0, 4),
			Head = roundNumber(description.HeadScale or 0, 4),
			Depth = roundNumber(description.DepthScale or 0, 4),
			Proportion = roundNumber(description.ProportionScale or 0, 4),
			BodyType = roundNumber(description.BodyTypeScale or 0, 4),
		},
		Body = {
			Head = description.Head or 0,
			Torso = description.Torso or 0,
			LeftArm = description.LeftArm or 0,
			RightArm = description.RightArm or 0,
			LeftLeg = description.LeftLeg or 0,
			RightLeg = description.RightLeg or 0,
			Face = description.Face or 0,
		},
		Animations = animations,
	}
end

-- Data-only adapter for the ordered Items array observed in CAC's client
-- serialization code. No character changes, game-module requires or asset loads.
local OUTFIT_PROPERTIES = {
	"BackAccessory", "FaceAccessory", "FrontAccessory", "HairAccessory",
	"HatAccessory", "NeckAccessory", "ShouldersAccessory", "WaistAccessory",
	"ClimbAnimation", "FallAnimation", "IdleAnimation", "JumpAnimation",
	"RunAnimation", "SwimAnimation", "WalkAnimation",
	"HeadColor", "LeftArmColor", "LeftLegColor", "RightArmColor", "RightLegColor", "TorsoColor",
	"Face", "Head", "LeftArm", "LeftLeg", "RightArm", "RightLeg", "Torso",
	"GraphicTShirt", "Pants", "Shirt", "BodyTypeScale", "DepthScale", "HeadScale",
	"HeightScale", "ProportionScale", "WidthScale", "LayeredClothing", "MoodAnimation",
}
local RIGID_TYPES = { "Back", "Face", "Front", "Hair", "Hat", "Neck", "Shoulder", "Waist" }

local function finiteNonnegative(value)
	local number = tonumber(value)
	return number and number == number and number >= 0 and number <= MAX_SAFE_INTEGER and number or nil
end

local function outfitInfoToResult(info)
	if typeof(info) ~= "table" or typeof(info.Items) ~= "table" then
		return nil, "Unrecognized outfit payload"
	end
	local rig = info.RigType or "R15"
	if rig ~= "R6" and rig ~= "R15" then return nil, "Unrecognized outfit rig" end
	local description, accessories = {}, {}
	for index, property in ipairs(OUTFIT_PROPERTIES) do
		local value = info.Items[index]
		if index <= #RIGID_TYPES then
			if typeof(value) ~= "string" then return nil, "Unrecognized accessory list" end
			for asset in value:gmatch("[^,]+") do
				local id = finiteNonnegative(asset)
				if not id or id % 1 ~= 0 then return nil, "Invalid accessory ID" end
				if id > 0 then
					accessories[#accessories + 1] = { AssetId = id, AccessoryType = RIGID_TYPES[index], IsLayered = false }
				end
			end
		elseif property:match("Color$") then
			if typeof(value) ~= "string" then return nil, "Unrecognized body colour" end
			local r, g, b = value:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
			r, g, b = tonumber(r), tonumber(g), tonumber(b)
			if not r or not g or not b or math.max(r, g, b) > 255 then return nil, "Invalid body colour" end
			description[property] = Color3.fromRGB(r, g, b)
		elseif property == "LayeredClothing" then
			if value ~= nil and typeof(value) ~= "table" then return nil, "Unrecognized layered clothing" end
			for _, item in ipairs(value or {}) do
				if typeof(item) ~= "table" then return nil, "Invalid layered clothing" end
				local id = finiteNonnegative(item.AssetId)
				if not id or id % 1 ~= 0 or typeof(item.AccessoryType) ~= "string" then
					return nil, "Invalid layered accessory"
				end
				accessories[#accessories + 1] = {
					AssetId = id, AccessoryType = item.AccessoryType, IsLayered = true,
					Order = item.Order, Puffiness = item.Puffiness,
				}
			end
		else
			-- MoodAnimation is optional in older payloads. Core fields must be
			-- present so a shifted/new schema cannot silently produce wrong JSON.
			if property == "MoodAnimation" and value == nil then value = 0 end
			local number = finiteNonnegative(value)
			if not number or (not property:match("Scale$") and number % 1 ~= 0) then
				return nil, "Unrecognized outfit property layout"
			end
			description[property] = number
		end
	end
	function description:GetAccessories() return accessories end
	return descriptionToResult({ RigType = { Name = rig } }, description)
end

local function lookupOutfitOnce(code)
	if not clientIdRequested then
		local ok, value = pcall(function()
			return CommunityRemote:InvokeServer({ Action = "GetClientId" })
		end)
		if ok and value == "OnCooldown" then
			return nil, "rate_limited"
		end
		-- The inspected client forwards this opaque value unchanged; it can
		-- be a table, not just a string/number. Do not invent or unwrap tokens.
		clientIdRequested = true
		if ok and value ~= nil and value ~= false then
			clientId = value
		else
			-- The original working worker omitted ClientId. Let the existing
			-- server decide whether that legacy request is supported.
			log("Client ID unavailable; trying the original outfit lookup")
		end
	end
	local ok, info = pcall(function()
		return CommunityRemote:InvokeServer({ Action = "GetFromOutfitCode", OutfitCode = code, ClientId = clientId })
	end)
	if not ok then
		if clientId == nil then clientIdRequested = false end
		return nil, "lookup_unavailable"
	end
	if info == "OnCooldown" then return nil, "rate_limited" end
	if typeof(info) ~= "table" then
		if clientId == nil then clientIdRequested = false end
		return nil, "Outfit code was not found"
	end
	if info.Hidden or info.Banned then return nil, "This outfit is unavailable" end
	return info
end

local function fetchOutfitInfo(code, expiresAt, deferWhenBusy)
	for attempt = 1, #OUTFIT_BUSY_RETRY_DELAYS + 1 do
		if not active then return nil, "Import stopped" end
		if expiresAt and expiresAt <= DateTime.now().UnixTimestampMillis then
			return nil, "This import expired. Please try again."
		end
		local info, failure = lookupOutfitOnce(code)
		if info or (failure ~= "rate_limited" and failure ~= "lookup_unavailable") then return info, failure end
		-- Pool jobs release their claim instead of tying up a throttled worker.
		if deferWhenBusy then
			return nil, failure == "rate_limited" and "The outfit service is busy. Please try again shortly."
				or "The outfit service could not be reached. Please try again shortly.", true
		end
		local delay = OUTFIT_BUSY_RETRY_DELAYS[attempt]
		if not delay then break end
		if expiresAt and expiresAt <= DateTime.now().UnixTimestampMillis + delay * 1000 then
			return nil, "This import expired. Please try again."
		end
		log("Outfit service temporarily busy; retrying in " .. tostring(delay) .. "s")
		task.wait(delay)
	end
	return nil, "The outfit service is busy. Please try again shortly.", true
end

local function processSingleOutfit(hexCode, requesterName, expiresAt, deferWhenBusy)
	if typeof(hexCode) ~= "string" or not hexCode:match("^[%da-fA-F]+$") then
		return { error = "Invalid outfit code" }
	end
	local code = tonumber(hexCode, 16)
	if not code or code > MAX_SAFE_INTEGER or code % 1 ~= 0 then
		return { error = "Outfit code is outside the supported numeric range" }
	end

	log("Processing - " .. requesterName .. " - code " .. tostring(code))
	local fetchStarted = os.clock()
	local outfitInfo, fetchError, retryable = fetchOutfitInfo(code, expiresAt, deferWhenBusy)
	if not outfitInfo then return { error = fetchError, retryable = retryable or nil } end
	local fetchSeconds = os.clock() - fetchStarted
	local converted, direct, conversionError = pcall(outfitInfoToResult, outfitInfo)
	if converted and direct then
		log(string.format("Outfit read directly in %.2fs; no avatar change", os.clock() - fetchStarted))
		return direct
	end
	log("Using character fallback: " .. (converted and conversionError or "outfit conversion unavailable"))
	if not CatalogGuiRemote then return { error = "This outfit requires the character fallback, but CatalogGuiRemote is unavailable" } end

	local _, humanoidBefore = getCharacterHumanoid(3)
	if not humanoidBefore then
		return { error = "Humanoid not found" }
	end

	local beforeDescription = getHumanoidDescriptionObject(humanoidBefore, 1.5)
	if not beforeDescription then
		return { error = "No HumanoidDescription" }
	end

	local beforeFingerprint = buildDescriptionFingerprint(humanoidBefore, beforeDescription)

	local applied = {}
	local appliedConnection
	-- Some game/client versions deliver this signal; others use the existing
	-- description polling fallback. Never assume the signal will be delivered.
	pcall(function()
		appliedConnection = humanoidBefore.ApplyDescriptionFinished:Connect(function(description)
			local ok, fingerprint = pcall(buildDescriptionFingerprint, humanoidBefore, description)
			if ok then applied.fingerprint = fingerprint end
		end)
	end)
	local wearStarted = os.clock()
	requireCharacterReset = true
	local wearSuccess = pcall(function()
		CommunityRemote:InvokeServer({
			Action = "WearCommunityOutfit",
			OutfitInfo = outfitInfo,
		})
	end)
	if not wearSuccess then
		if appliedConnection then appliedConnection:Disconnect() end
		return { error = "Failed to wear outfit" }
	end
	local wearSeconds = os.clock() - wearStarted

	local settleStarted = os.clock()
	task.wait(0.05)

	local readOk, humanoidAfter, descriptionAfter = pcall(waitForFreshDescription, beforeFingerprint, applied)
	if appliedConnection then appliedConnection:Disconnect() end
	if not readOk then
		return { error = "Failed to read outfit description" }
	end
	log(string.format("Outfit timing: fetch %.2fs / apply %.2fs / settle %.2fs",
		fetchSeconds, wearSeconds, os.clock() - settleStarted))
	if not humanoidAfter or not descriptionAfter then
		local _, fallbackHumanoid = getCharacterHumanoid(1.5)
		local fallbackDescription = fallbackHumanoid and getHumanoidDescriptionObject(fallbackHumanoid, 0.5) or nil
		if fallbackHumanoid and fallbackDescription then
			local fallback = descriptionToResult(fallbackHumanoid, fallbackDescription)
			log("Done - fallback read - " .. tostring(#(((fallback.Accessories or {}).Other) or {})) .. " accessories")
			return fallback
		end
		return { error = "Failed to read outfit" }
	end

	local result = descriptionToResult(humanoidAfter, descriptionAfter)
	log("Done - " .. tostring(#(((result.Accessories or {}).Other) or {})) .. " accessories")
	return result
end

local function requesterLabel(data)
	-- The label is only for logs. A Discord ID is not a Roblox user ID, so
	-- avoid a potentially slow name lookup when username is absent in v2.
	return tostring(data.username or data.userId or "unknown")
end

local function processRequest(requestId, data, claimId)
	local result = {}
	local codes = data.codes or (data.code and { data.code }) or {}
	local count = math.min(#codes, MAX_CODES)
	for index = 1, count do
		if not active or expired(data) then return end
		local ok, outfit = pcall(processSingleOutfit, codes[index], requesterLabel(data), tonumber(data.expiresAt))
		result["outfit" .. index] = ok and outfit or { error = "Failed to process outfit" }
		if index < count then task.wait(BETWEEN_OUTFITS_DELAY) end
	end
	-- Publish before resetting the character; resetting is not part of the result.
	sendResult(requestId, result, claimId, tonumber(data.expiresAt))
	lastWorkFinishedAt = os.clock()
	resetNeeded = resetNeeded or requireCharacterReset
	requireCharacterReset = false
end

local function processJob(requestId, jobId, requestData, jobData, claimId)
	if not active or expired(requestData) then return end
	local started = os.clock()
	local ok, result = pcall(processSingleOutfit, jobData.code, requesterLabel(requestData), tonumber(requestData.expiresAt), true)
	if not ok then result = { error = "Failed to process outfit" } end
	local sent, deferred
	if retryableResult(result) then
		sent, deferred = deferClaimPath("requests/" .. requestId .. "/jobs/" .. jobId, result, claimId, tonumber(requestData.expiresAt))
		-- Back off this worker across jobs, not just the individual job lease.
		-- Otherwise a large batch keeps probing the same busy server every 2s.
		busyStreak = math.min(busyStreak + 1, #OUTFIT_BUSY_RETRY_DELAYS)
		local pause = OUTFIT_BUSY_RETRY_DELAYS[busyStreak]
		workerReadyAt = os.clock() + pause
		log("Outfit service busy; worker resting for " .. tostring(pause) .. "s")
	else
		busyStreak = 0
		sent = sendJobResult(requestId, jobId, result, claimId, tonumber(requestData.expiresAt))
	end
	lastWorkFinishedAt = os.clock()
	resetNeeded = resetNeeded or requireCharacterReset
	requireCharacterReset = false
	log(string.format("Job finished in %.2fs; %s", os.clock() - started, deferred and "queued for retry" or (sent and "result saved" or "result not saved")))
end

local function sortedRequests(requests)
	local entries = {}
	for id, data in pairs(requests) do
		if typeof(id) == "string" and id:match("^[%w_-]+$") and typeof(data) == "table"
			and (data.result == nil or typeof(data.jobs) == "table") and not expired(data) then
			entries[#entries + 1] = { id = id, data = data }
		end
	end
	table.sort(entries, function(a, b)
		local left, right = tonumber(a.data.requestedAt) or 0, tonumber(b.data.requestedAt) or 0
		return left < right or (left == right and a.id < b.id)
	end)
	return entries
end

local function processQueue(requests)
	if os.clock() < workerReadyAt then return false end
	local entries = sortedRequests(requests)
	local start = 1
	for index, entry in ipairs(entries) do
		if entry.id == lastRequestId then start = index % #entries + 1; break end
	end
	for offset = 0, #entries - 1 do
		local entry = entries[(start + offset - 1) % #entries + 1]
		local requestId, data = entry.id, entry.data
		if not active then return end
		local expiresAt = tonumber(data.expiresAt)
		if typeof(data.jobs) == "table" then
			-- Claim only one job at a time. Rotate across requests on the next
			-- pass so a five-code batch cannot monopolize this worker.
			for index = 1, MAX_CODES do
				if not active or expired(data) then break end
				local jobId = "outfit" .. index
				local job = data.jobs[jobId]
				if typeof(job) == "table" and job.code and claimAvailable(job) then
					local claimId = tryClaimJob(requestId, jobId, expiresAt)
					if claimId then
						lastRequestId = requestId
						processJob(requestId, jobId, data, job, claimId)
						return true
					end
				end
			end
		else
			local codes = data.codes or (data.code and { data.code }) or {}
			if typeof(codes) == "table" and #codes > 0 and claimAvailable(data) then
				local claimId = tryClaim(requestId, expiresAt)
				if claimId then
					lastRequestId = requestId
					processRequest(requestId, data, claimId)
					return true
				end
			end
		end
	end
	return false
end

-- Start worker. Tests replace this section with isolated service mocks.
if not initializeWorker() then return end
task.spawn(function()
	local ok = pcall(optimizeGraphics)
	if not ok then log("Optional graphics optimizations were unavailable") end
end)

local idleConnection = Player.Idled:Connect(function()
	if not active then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end)

task.spawn(function()
	log("Listener active - poll " .. tostring(POLL_INTERVAL) .. "s")
	while active do
		if os.clock() < workerReadyAt then
			task.wait(math.min(POLL_INTERVAL, workerReadyAt - os.clock()))
			continue
		end
		local started = os.clock()
		local didWork = false
		local ok, requests = pcall(getRequests)
		if ok and requests then
			local processed, worked = pcall(processQueue, requests)
			didWork = processed and worked == true
			if not processed then log("Queue processing failed; retrying on the next poll") end
		else
			-- Do not hammer auth/Firebase every 400ms during an outage or denial.
			task.wait(AUTH_FAILURE_DELAY)
		end
		if active and resetNeeded and os.clock() - lastWorkFinishedAt >= 1 then
			forceResetCharacter()
			resetNeeded = false
		end
		local remaining = POLL_INTERVAL - (os.clock() - started)
		if active then task.wait(didWork and 0 or math.max(0, remaining)) end
	end
	idleConnection:Disconnect()
	log("Worker stopped")
end)

log("CAC ready - " .. WORKER_VERSION .. " - one job per worker, fair queue and retry handoffs")

