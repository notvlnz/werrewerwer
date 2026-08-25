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

local FIREBASE_URL = "https://importer-41f0d-default-rtdb.firebaseio.com/"
local API_KEY = "AIzaSyC27Wj2awyQuzBjja4kd3t32E21oM6Sd3Y"

local POLL_INTERVAL = 0.4
local SHOW_LOG_GUI = true
local FPS_CAP = 30
local DISABLE_AUDIO = true
local AUTH_REFRESH_MARGIN = 300
local MAX_LOG_LINES = 80
local CLAIM_TIMEOUT = 60
local HTTP_MAX_ATTEMPTS = 3
local HTTP_RETRY_BASE = 0.12
local HTTP_TIMEOUT = 8

local APPLY_WAIT_WINDOW = 5.0
local APPLY_POLL_STEP = 0.08
local APPLY_STABLE_POLLS = 2
local BETWEEN_OUTFITS_DELAY = 0.2

local PlayerGui = SHOW_LOG_GUI and Player:WaitForChild("PlayerGui", 8) or nil

-- CAC moved CommunityOutfitsRemote under ReplicatedStorage.Events.
-- Use the known new path first, while retaining the resolver below as a fallback.
local EventsFolder = ReplicatedStorage:WaitForChild("Events", 15)
local CommunityRemote = EventsFolder and EventsFolder:WaitForChild("CommunityOutfitsRemote", 15) or nil
local CatalogGuiRemote = ReplicatedStorage:FindFirstChild("CatalogGuiRemote", true)
local UpdateStatusRemote = EventsFolder and EventsFolder:FindFirstChild("UpdatePlayerStatus", true) or nil

local active = true
local isProcessing = false
local currentIdToken = nil
local tokenExpiresAt = 0
local resetNeeded = false
local lastWorkFinishedAt = 0

local MY_USER_ID = tostring(Player.UserId)
local usernameCache = {}

local requestImpl = (syn and syn.request) or (http and http.request) or request
local log

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
	if not SHOW_LOG_GUI then
		return function(message)
			print("[CAC] " .. message)
		end
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "CACLogger"
	gui.ResetOnSpawn = false
	gui.Parent = PlayerGui

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(640, 500)
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
log("[BOOT] CAC IMPORTER DEBUG V5 loaded - Events/CommunityOutfitsRemote path")

local function describeRemoteCandidate(instance)
	local ok, fullName = pcall(function()
		return instance:GetFullName()
	end)
	return (ok and fullName or instance.Name) .. " [" .. instance.ClassName .. "]"
end

local function logLikelyOutfitRemotes()
	local candidates = {}
	for _, instance in ipairs(ReplicatedStorage:GetDescendants()) do
		if instance:IsA("RemoteFunction") or instance:IsA("RemoteEvent") then
			local lower = string.lower(instance.Name)
			if string.find(lower, "outfit", 1, true) or string.find(lower, "community", 1, true) then
				table.insert(candidates, instance)
			end
		end
	end

	table.sort(candidates, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)

	if #candidates == 0 then
		log("[REMOTE-SEARCH] No RemoteFunction/RemoteEvent containing 'outfit' or 'community' exists under ReplicatedStorage")
		return
	end

	log("[REMOTE-SEARCH] Found " .. tostring(#candidates) .. " likely remote(s):")
	for index, instance in ipairs(candidates) do
		if index > 20 then
			log("[REMOTE-SEARCH] ... additional candidates omitted")
			break
		end
		log("[REMOTE-SEARCH] " .. tostring(index) .. ": " .. describeRemoteCandidate(instance))
	end
end

local function resolveCommunityRemote(verbose)
	if CommunityRemote and CommunityRemote.Parent and CommunityRemote:IsA("RemoteFunction") then
		return CommunityRemote
	end

	CommunityRemote = nil

	-- First: CAC's current known path: ReplicatedStorage.Events.CommunityOutfitsRemote.
	if not EventsFolder or not EventsFolder.Parent then
		EventsFolder = ReplicatedStorage:FindFirstChild("Events") or ReplicatedStorage:FindFirstChild("Events", true)
	end

	local eventsExact = EventsFolder and EventsFolder:FindFirstChild("CommunityOutfitsRemote") or nil
	if eventsExact and eventsExact:IsA("RemoteFunction") then
		CommunityRemote = eventsExact
		if verbose then
			log("[REMOTE-SEARCH] Using current CAC path -> " .. describeRemoteCandidate(eventsExact))
		end
		return CommunityRemote
	end

	-- Fallback: same exact name anywhere under ReplicatedStorage in case it moves again.
	local exact = ReplicatedStorage:FindFirstChild("CommunityOutfitsRemote", true)
	if exact and exact:IsA("RemoteFunction") then
		CommunityRemote = exact
		if verbose then
			log("[REMOTE-SEARCH] Fallback exact CommunityOutfitsRemote found -> " .. describeRemoteCandidate(exact))
		end
		return CommunityRemote
	end

	-- Common naming variants in case CAC renamed it slightly.
	local aliases = {
		"CommunityOutfitRemote",
		"CommunityOutfits",
		"CommunityOutfit",
		"OutfitCommunityRemote",
	}
	for _, alias in ipairs(aliases) do
		local candidate = ReplicatedStorage:FindFirstChild(alias, true)
		if candidate and candidate:IsA("RemoteFunction") then
			CommunityRemote = candidate
			log("[REMOTE-SEARCH] Using renamed candidate '" .. alias .. "' -> " .. describeRemoteCandidate(candidate))
			return CommunityRemote
		end
	end

	-- Last safe automatic fallback: a RemoteFunction whose name contains BOTH words.
	local fuzzy = {}
	for _, instance in ipairs(ReplicatedStorage:GetDescendants()) do
		if instance:IsA("RemoteFunction") then
			local lower = string.lower(instance.Name)
			if string.find(lower, "community", 1, true) and string.find(lower, "outfit", 1, true) then
				table.insert(fuzzy, instance)
			end
		end
	end

	if #fuzzy == 1 then
		CommunityRemote = fuzzy[1]
		log("[REMOTE-SEARCH] Auto-selected fuzzy Community/Outfit RemoteFunction -> " .. describeRemoteCandidate(CommunityRemote))
		return CommunityRemote
	elseif #fuzzy > 1 then
		log("[REMOTE-SEARCH] Multiple Community/Outfit RemoteFunctions found; refusing to guess")
	end

	if verbose then
		log("[REMOTE-SEARCH] CommunityOutfitsRemote NOT FOUND")
		logLikelyOutfitRemotes()
	end
	return nil
end

local bootCommunityRemote = resolveCommunityRemote(true)
if bootCommunityRemote then
	log("[BOOT] CommunityOutfitsRemote READY -> " .. describeRemoteCandidate(bootCommunityRemote))
else
	log("[BOOT] WARNING: CommunityOutfitsRemote still missing")
end

local function performRequest(options)
	if requestImpl then
		return requestImpl(options)
	end

	return HttpService:RequestAsync(options)
end

local function performJsonRequest(method, url, body, extraHeaders, maxAttempts)
	local headers = {
		["Content-Type"] = "application/json",
		["User-Agent"] = "RobloxWinInet",
	}
	for key, value in pairs(extraHeaders or {}) do
		headers[key] = value
	end

	local attempts = maxAttempts or HTTP_MAX_ATTEMPTS
	local lastResponse = nil
	for attempt = 1, attempts do
		local success, response = pcall(function()
			return performRequest({
				Url = url,
				Method = method,
				Headers = headers,
				Body = body and HttpService:JSONEncode(body) or nil,
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
			task.wait(HTTP_RETRY_BASE * attempt + math.random() * 0.05)
		end
	end

	return nil, lastResponse
end

local function httpJson(method, url, body)
	local decoded = performJsonRequest(method, url, body)
	return decoded
end

local function refreshAuthToken()
	log("Refreshing Firebase token")
	local data = httpJson("POST", "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=" .. API_KEY, {
		returnSecureToken = true,
	})

	if not data or not data.idToken then
		log("Firebase auth failed")
		return false
	end

	currentIdToken = data.idToken
	tokenExpiresAt = tick() + (tonumber(data.expiresIn) or 3600) - AUTH_REFRESH_MARGIN
	log("Token refreshed")
	return true
end

local function ensureAuthToken()
	if currentIdToken and tick() < tokenExpiresAt then
		return true
	end

	return refreshAuthToken()
end

local function getRequests()
	if not ensureAuthToken() then
		return {}
	end

	return httpJson("GET", FIREBASE_URL .. "requests.json?auth=" .. currentIdToken) or {}
end

local function getResponseHeader(response, wantedName)
	for name, value in pairs((response and response.Headers) or {}) do
		if string.lower(tostring(name)) == string.lower(wantedName) then
			return value
		end
	end
	return nil
end

local function tryClaimPath(relativePath)
	if not ensureAuthToken() then
		return false
	end

	local url = FIREBASE_URL .. relativePath .. ".json?auth=" .. currentIdToken
	local current, getResponse = performJsonRequest("GET", url, nil, {
		["X-Firebase-ETag"] = "true",
	})
	if not current or current.result then
		return false
	end

	local claimedAt = tonumber(current.claimedAt)
	if claimedAt and claimedAt > 100000000000 then
		claimedAt = claimedAt / 1000
	end
	local timedOut = claimedAt and current.claimedBy and (os.time() - claimedAt >= CLAIM_TIMEOUT) or false
	if not timedOut and (current.claimedBy or current.processing) then
		return false
	end

	local etag = getResponseHeader(getResponse, "ETag")
	if not etag then
		log("Claim failed (no Firebase ETag) -> " .. relativePath)
		return false
	end

	current.claimedBy = MY_USER_ID
	current.claimedAt = { [".sv"] = "timestamp" }
	current.processing = true

	local _, putResponse = performJsonRequest("PUT", url, current, {
		["if-match"] = etag,
	}, 1)
	if not putResponse or putResponse.StatusCode < 200 or putResponse.StatusCode >= 300 then
		if putResponse and putResponse.StatusCode == 412 then
			log("Claim lost race -> " .. relativePath)
		end
		return false
	end

	log((timedOut and "Reclaimed timed out -> " or "Claimed -> ") .. relativePath)
	return true
end

local function tryClaim(requestId)
	return tryClaimPath("requests/" .. requestId)
end

local function tryClaimJob(requestId, jobId)
	return tryClaimPath("requests/" .. requestId .. "/jobs/" .. jobId)
end

local function completeClaimPath(relativePath, payload)
	for _ = 1, 2 do
		if not ensureAuthToken() then
			continue
		end

		local url = FIREBASE_URL .. relativePath .. ".json?auth=" .. currentIdToken
		local current, getResponse = performJsonRequest("GET", url, nil, {
			["X-Firebase-ETag"] = "true",
		})
		if not current or current.claimedBy ~= MY_USER_ID then
			return false
		end

		local etag = getResponseHeader(getResponse, "ETag")
		if not etag then
			return false
		end

		current.result = payload
		current.processing = false
		current.finishedAt = os.time()

		local _, putResponse = performJsonRequest("PUT", url, current, {
			["if-match"] = etag,
		}, 1)
		if putResponse and putResponse.StatusCode >= 200 and putResponse.StatusCode < 300 then
			return true
		end
		if not putResponse or putResponse.StatusCode ~= 412 then
			return false
		end
	end
	return false
end

local function sendResult(requestId, payload)
	if completeClaimPath("requests/" .. requestId, payload) then
		log("Result sent for " .. requestId)
	else
		log("Failed to send result for " .. requestId)
	end
end

local function sendJobResult(requestId, jobId, payload)
	local sent = completeClaimPath("requests/" .. requestId .. "/jobs/" .. jobId, payload)
	log((sent and "Job result sent for " or "Failed to send job result for ") .. requestId .. "/" .. jobId)
	return sent
end

local function forceResetCharacter()
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

local function getUsername(userIdStr)
	if usernameCache[userIdStr] then
		return usernameCache[userIdStr]
	end

	local success, result = pcall(function()
		return Players:GetNameFromUserIdAsync(tonumber(userIdStr))
	end)

	usernameCache[userIdStr] = success and result or userIdStr
	return usernameCache[userIdStr]
end

local function getCharacterHumanoid(timeoutSeconds)
	local deadline = tick() + (timeoutSeconds or 3)
	repeat
		local character = Player.Character
		if character and character.Parent then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return character, humanoid
			end
		end
		task.wait(0.05)
	until tick() >= deadline

	return nil, nil
end

local function getHumanoidDescriptionObject(humanoid, timeoutSeconds)
	local deadline = tick() + (timeoutSeconds or 2)
	repeat
		if not humanoid then
			break
		end

		local description = humanoid:FindFirstChild("HumanoidDescription")
		if description and description:IsA("HumanoidDescription") then
			return description
		end

		task.wait(0.05)
	until tick() >= deadline

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

local function waitForFreshDescription(beforeFingerprint)
	local deadline = tick() + APPLY_WAIT_WINDOW
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

				if fingerprint ~= beforeFingerprint then
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
	until tick() >= deadline

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

local function truncateLogText(value, maxLength)
	local text = tostring(value)
	local limit = maxLength or 220
	if #text > limit then
		return string.sub(text, 1, limit) .. "..."
	end
	return text
end

local function summarizeForLog(value, depth, seen)
	depth = depth or 0
	seen = seen or {}

	local valueType = typeof(value)
	if valueType == "nil" then
		return "nil"
	elseif valueType == "string" then
		return string.format("%q", truncateLogText(value, 180))
	elseif valueType == "number" or valueType == "boolean" then
		return tostring(value)
	elseif valueType == "Instance" then
		local ok, fullName = pcall(function()
			return value:GetFullName()
		end)
		return ok and (value.ClassName .. "<" .. fullName .. ">") or tostring(value)
	elseif valueType ~= "table" then
		return truncateLogText(value, 180)
	end

	if seen[value] then
		return "<cycle>"
	end
	if depth >= 2 then
		return "{...}"
	end

	seen[value] = true
	local parts = {}
	local count = 0
	for key, item in pairs(value) do
		count = count + 1
		if count > 12 then
			parts[#parts + 1] = "..."
			break
		end
		parts[#parts + 1] = truncateLogText(key, 60) .. "=" .. summarizeForLog(item, depth + 1, seen)
	end
	seen[value] = nil

	return "{" .. table.concat(parts, ", ") .. "}"
end

local function invokeCommunityRemoteDebug(action, payload, attemptLabel)
	local remote = resolveCommunityRemote(false)
	if not remote then
		log("[REMOTE] " .. tostring(action) .. " aborted -> CommunityOutfits RemoteFunction is missing")
		logLikelyOutfitRemotes()
		return false, nil, "CommunityOutfits RemoteFunction not found"
	end

	local startedAt = tick()
	local success, result = pcall(function()
		return remote:InvokeServer(payload)
	end)
	local elapsed = tick() - startedAt
	local prefix = "[REMOTE] " .. action .. (attemptLabel and (" [" .. attemptLabel .. "]") or "")

	if not success then
		log(prefix .. " ERROR after " .. tostring(roundNumber(elapsed, 3)) .. "s -> " .. truncateLogText(result, 320))
		return false, nil, tostring(result)
	end

	log(prefix .. " returned in " .. tostring(roundNumber(elapsed, 3)) .. "s -> type=" .. typeof(result) .. " value=" .. summarizeForLog(result))
	return true, result, nil
end

local function buildOutfitCodeCandidates(hexCode)
	local rawCode = tostring(hexCode or "")
	rawCode = string.gsub(rawCode, "^%s+", "")
	rawCode = string.gsub(rawCode, "%s+$", "")

	local candidates = {}
	local seen = {}
	local function add(label, value)
		if value == nil then
			return
		end
		local key = typeof(value) .. ":" .. tostring(value)
		if seen[key] then
			return
		end
		seen[key] = true
		candidates[#candidates + 1] = {
			label = label,
			value = value,
		}
	end

	-- Preserve the format this script used before first.
	add("hex-number", tonumber(rawCode, 16))

	-- Also try the visible code itself in case CAC changed the remote contract.
	if rawCode ~= "" then
		add("raw-string", rawCode)
		add("uppercase-string", string.upper(rawCode))
	end

	-- Useful for requests that may already contain a decimal outfit id.
	add("decimal-number", tonumber(rawCode))

	return rawCode, candidates
end

local function processSingleOutfit(hexCode, requesterName)
	local rawCode, codeCandidates = buildOutfitCodeCandidates(hexCode)
	if rawCode == "" or #codeCandidates == 0 then
		log("[FETCH] Invalid/empty outfit code received -> " .. summarizeForLog(hexCode))
		return { error = "Invalid outfit code" }
	end

	log("Processing - " .. requesterName .. " - input code " .. rawCode)
	local resolvedRemote = resolveCommunityRemote(true)
	if not resolvedRemote then
		log("[FETCH] STOPPED before outfit lookup -> Community outfit RemoteFunction is unavailable")
		return { error = "Failed to fetch outfit" }
	end
	log("[FETCH] Community remote -> " .. describeRemoteCandidate(resolvedRemote))
	log("[FETCH] Will try " .. tostring(#codeCandidates) .. " code representation(s)")

	local _, humanoidBefore = getCharacterHumanoid(3)
	if not humanoidBefore then
		log("[FETCH] Aborted -> local Humanoid was not found within 3s")
		return { error = "Humanoid not found" }
	end

	local beforeDescription = getHumanoidDescriptionObject(humanoidBefore, 1.5)
	if not beforeDescription then
		log("[FETCH] Aborted -> HumanoidDescription was not found within 1.5s")
		return { error = "No HumanoidDescription" }
	end

	local beforeFingerprint = buildDescriptionFingerprint(humanoidBefore, beforeDescription)
	log("[FETCH] Current avatar captured -> rig=" .. humanoidBefore.RigType.Name .. ", fingerprintLength=" .. tostring(beforeFingerprint and #beforeFingerprint or 0))

	local outfitInfo = nil
	local successfulFormat = nil
	local lastRemoteError = nil

	for attemptIndex, candidate in ipairs(codeCandidates) do
		local attemptLabel = tostring(attemptIndex) .. "/" .. tostring(#codeCandidates) .. " " .. candidate.label .. "=" .. tostring(candidate.value)
		log("[FETCH] Trying " .. attemptLabel)

		local remoteSuccess, remoteResult, remoteError = invokeCommunityRemoteDebug("GetFromOutfitCode", {
			Action = "GetFromOutfitCode",
			OutfitCode = candidate.value,
		}, attemptLabel)

		if remoteSuccess and remoteResult ~= nil and remoteResult ~= false then
			outfitInfo = remoteResult
			successfulFormat = candidate.label
			log("[FETCH] SUCCESS using " .. candidate.label .. " -> responseType=" .. typeof(outfitInfo))
			break
		end

		if remoteError then
			lastRemoteError = remoteError
		end

		if remoteSuccess then
			log("[FETCH] Server call succeeded but returned " .. tostring(remoteResult) .. " for " .. candidate.label)
		end

		-- One small retry for actual remote exceptions/timeouts before moving formats.
		if not remoteSuccess then
			task.wait(0.2)
			log("[FETCH] Retrying same format once -> " .. candidate.label)
			local retrySuccess, retryResult, retryError = invokeCommunityRemoteDebug("GetFromOutfitCode", {
				Action = "GetFromOutfitCode",
				OutfitCode = candidate.value,
			}, attemptLabel .. " retry")

			if retrySuccess and retryResult ~= nil and retryResult ~= false then
				outfitInfo = retryResult
				successfulFormat = candidate.label
				log("[FETCH] SUCCESS on retry using " .. candidate.label)
				break
			end

			if retryError then
				lastRemoteError = retryError
			elseif retrySuccess then
				log("[FETCH] Retry returned " .. tostring(retryResult) .. " instead of outfit data")
			end
		end

		task.wait(0.08)
	end

	if not outfitInfo then
		log("[FETCH] FAILED for code " .. rawCode .. " -> every representation failed")
		if lastRemoteError then
			log("[FETCH] Last thrown remote error -> " .. truncateLogText(lastRemoteError, 320))
		else
			log("[FETCH] No Lua exception was thrown; CAC returned nil/false for every attempt. This usually points to an invalid/deleted code or a changed server-side remote contract.")
		end
		-- Keep the result sent to Firebase/embed clean. Detailed diagnostics stay in this logger.
		return { error = "Failed to fetch outfit" }
	end

	log("[WEAR] Applying fetched outfit -> format=" .. tostring(successfulFormat) .. ", info=" .. summarizeForLog(outfitInfo))
	local wearSuccess, wearResult, wearError = invokeCommunityRemoteDebug("WearCommunityOutfit", {
		Action = "WearCommunityOutfit",
		OutfitInfo = outfitInfo,
	}, "format=" .. tostring(successfulFormat))

	if not wearSuccess then
		log("[WEAR] FAILED -> " .. truncateLogText(wearError or "unknown InvokeServer error", 320))
		return { error = "Failed to wear outfit" }
	end

	if wearResult == false then
		log("[WEAR] WARNING -> remote explicitly returned false")
	else
		log("[WEAR] Remote accepted call -> returned " .. summarizeForLog(wearResult))
	end

	task.wait(0.05)

	local humanoidAfter, descriptionAfter = waitForFreshDescription(beforeFingerprint)
	if not humanoidAfter or not descriptionAfter then
		log("[READ] Fresh HumanoidDescription was not available inside " .. tostring(APPLY_WAIT_WINDOW) .. "s; trying fallback read")
		local _, fallbackHumanoid = getCharacterHumanoid(1.5)
		local fallbackDescription = fallbackHumanoid and getHumanoidDescriptionObject(fallbackHumanoid, 0.5) or nil
		if fallbackHumanoid and fallbackDescription then
			local fallbackFingerprint = buildDescriptionFingerprint(fallbackHumanoid, fallbackDescription)
			local fallback = descriptionToResult(fallbackHumanoid, fallbackDescription)
			log("[READ] Fallback fingerprint changed=" .. tostring(fallbackFingerprint ~= beforeFingerprint))
			log("Done - fallback read - " .. tostring(#(((fallback.Accessories or {}).Other) or {})) .. " accessories")
			return fallback
		end
		log("[READ] FAILED -> no readable HumanoidDescription after wear")
		return { error = "Failed to read outfit" }
	end

	local afterFingerprint = buildDescriptionFingerprint(humanoidAfter, descriptionAfter)
	log("[READ] Avatar description acquired -> changed=" .. tostring(afterFingerprint ~= beforeFingerprint) .. ", rig=" .. humanoidAfter.RigType.Name)

	local result = descriptionToResult(humanoidAfter, descriptionAfter)
	log("Done - " .. tostring(#(((result.Accessories or {}).Other) or {})) .. " accessories")
	return result
end

local function processRequest(requestId, data)
	isProcessing = true

	local requesterName = data.username or getUsername(tostring(data.userId or "unknown"))
	log("Processing request from - " .. requesterName .. " - " .. requestId)
	log("[REQUEST] raw data -> " .. summarizeForLog(data))

	local success, err = pcall(function()
		local result = {}
		local codes = data.codes or (data.code and { data.code }) or {}
		log("[REQUEST] resolved code count=" .. tostring(#codes))
		for i, c in ipairs(codes) do
			log("[REQUEST] code[" .. tostring(i) .. "] -> type=" .. typeof(c) .. " value=" .. tostring(c))
		end

		for index, hexCode in ipairs(codes) do
			result["outfit" .. index] = processSingleOutfit(hexCode, requesterName)
			if index < #codes then
				task.wait(BETWEEN_OUTFITS_DELAY + math.random() * 0.06)
			end
		end

		task.wait(0.18)
		forceResetCharacter()
		sendResult(requestId, result)
	end)

	if not success then
		log("[PROCESS] UNCAUGHT ERROR -> " .. truncateLogText(err, 500))
		-- Do not leak debug/stack details into the result payload.
		sendResult(requestId, { error = "Internal processing error" })
	end

	isProcessing = false
end

local function processJob(requestId, jobId, requestData, jobData)
	isProcessing = true

	local requesterName = requestData.username or getUsername(tostring(requestData.userId or "unknown"))
	log("Processing job from - " .. requesterName .. " - " .. requestId .. "/" .. jobId)
	log("[JOB] raw jobData -> " .. summarizeForLog(jobData))

	local incomingCode = jobData and jobData.code
	log("[JOB] code field -> type=" .. typeof(incomingCode) .. " value=" .. tostring(incomingCode))

	local codeText = tostring(incomingCode or "")
	if #codeText <= 2 then
		log("[JOB] WARNING: received a very short outfit code (" .. codeText .. "). If you expected a CAC code such as 6 hex characters, the sender/Firebase job is probably writing the outfit INDEX instead of the actual code.")
	end

	log("[JOB] handing code to outfit fetcher NOW")
	local success, result = pcall(processSingleOutfit, incomingCode, requesterName)
	if not success then
		log("[JOB] UNCAUGHT ERROR -> " .. truncateLogText(result, 500))
		-- Do not leak debug/stack details into the result payload.
		result = { error = "Internal processing error" }
	end

	sendJobResult(requestId, jobId, result)
	lastWorkFinishedAt = tick()
	resetNeeded = true
	isProcessing = false
end

task.spawn(optimizeGraphics)

task.spawn(function()
	if not refreshAuthToken() then
		log("Initial auth failed -> stopping")
		return
	end

	log("Listener active - poll " .. tostring(POLL_INTERVAL) .. "s - optimized CAC importer")

	while active do
		if isProcessing then
			task.wait(0.05)
			continue
		end

		if resetNeeded and tick() - lastWorkFinishedAt >= 1 then
			forceResetCharacter()
			resetNeeded = false
		end

		local startedAt = tick()
		local requests = getRequests()
		local workStarted = false

		for requestId, data in pairs(requests) do
			if data and data.jobs and not data.result then
				for jobId, jobData in pairs(data.jobs) do
					if jobData and jobData.code and not jobData.result and tryClaimJob(requestId, jobId) then
						task.spawn(processJob, requestId, jobId, data, jobData)
						workStarted = true
						break
					end
				end
			elseif data then
				local codes = data.codes or (data.code and { data.code }) or {}
				if #codes > 0 and not data.result and tryClaim(requestId) then
					task.spawn(processRequest, requestId, data)
					workStarted = true
				end
			end

			if workStarted then
				break
			end
		end

		local elapsed = tick() - startedAt
		if elapsed < POLL_INTERVAL then
			task.wait(POLL_INTERVAL - elapsed)
		end
	end
end)

task.spawn(function()
	while active do
		Player.Idled:Wait()
		if not active then
			break
		end

		log("Anti-AFK triggered")
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
		task.wait(285 + math.random(0, 30))
	end
end)

log("[BOOT] CAC ready - DEBUG V5 - Events remote + raw job/code diagnostics")
