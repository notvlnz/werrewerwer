local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui", 8)

local FIREBASE_URL = "https://cacc-c57bf-default-rtdb.firebaseio.com/"
local API_KEY = "AIzaSyBquxKffIm2lBtpi90GLLDdrQG_0yvlo4Y"

local POLL_INTERVAL = 0.2
local AUTH_REFRESH_MARGIN = 300
local MAX_LOG_LINES = 120
local CLAIM_TIMEOUT = 60

local APPLY_WAIT_WINDOW = 5.0
local APPLY_POLL_STEP = 0.08
local APPLY_STABLE_POLLS = 2
local BETWEEN_OUTFITS_DELAY = 0.4

local CommunityRemote = ReplicatedStorage:WaitForChild("CommunityOutfitsRemote", 8)
local CatalogGuiRemote = ReplicatedStorage:WaitForChild("CatalogGuiRemote", 8)
local EventsFolder = ReplicatedStorage:WaitForChild("Events", 8)
local UpdateStatusRemote = EventsFolder and EventsFolder:WaitForChild("UpdatePlayerStatus", 5)

local active = true
local isProcessing = false
local currentIdToken = nil
local tokenExpiresAt = 0

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
	pcall(function()
		settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
	end)
	pcall(function()
		RunService:Set3dRenderingEnabled(false)
	end)

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

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	end)
	pcall(function()
		StarterGui:SetCore("ChatActive", false)
	end)

	pcall(function()
		UserInputService.MouseIconEnabled = false
	end)

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

	log("Graphics optimized for max FPS")
end

local function createCleanLogger()
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

local function performRequest(options)
	if requestImpl then
		return requestImpl(options)
	end

	return HttpService:RequestAsync(options)
end

local function httpJson(method, url, body)
	local success, response = pcall(function()
		return performRequest({
			Url = url,
			Method = method,
			Headers = {
				["Content-Type"] = "application/json",
				["User-Agent"] = "RobloxWinInet",
			},
			Body = body and HttpService:JSONEncode(body) or nil,
		})
	end)

	if not success or not response or response.StatusCode < 200 or response.StatusCode >= 300 then
		return nil
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)

	return ok and decoded or nil
end

local function patchJson(url, body)
	local success, response = pcall(function()
		return performRequest({
			Url = url,
			Method = "PATCH",
			Headers = {
				["Content-Type"] = "application/json",
				["User-Agent"] = "RobloxWinInet",
			},
			Body = HttpService:JSONEncode(body),
		})
	end)

	return success and response and response.StatusCode >= 200 and response.StatusCode < 300
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

local function patchRequest(requestId, data)
	if not ensureAuthToken() then
		return false
	end

	return patchJson(FIREBASE_URL .. "requests/" .. requestId .. ".json?auth=" .. currentIdToken, data)
end

local function tryClaim(requestId)
	if not ensureAuthToken() then
		return false
	end

	local url = FIREBASE_URL .. "requests/" .. requestId .. ".json?auth=" .. currentIdToken
	local current = httpJson("GET", url)
	if not current or current.result then
		return false
	end

	local claimedAt = tonumber(current.claimedAt)
	local timedOut = claimedAt and current.claimedBy and (os.time() - claimedAt >= CLAIM_TIMEOUT) or false
	if not timedOut and (current.claimedBy or current.processing) then
		return false
	end

	local claimed = patchRequest(requestId, {
		claimedBy = MY_USER_ID,
		claimedAt = os.time(),
		processing = true,
	})
	if not claimed then
		return false
	end

	task.wait(0.03 + math.random() * 0.04)

	local after = httpJson("GET", url)
	if not after or after.claimedBy ~= MY_USER_ID then
		log("Claim lost race -> " .. requestId)
		return false
	end

	log((timedOut and "Reclaimed timed out -> " or "Claimed -> ") .. requestId)
	return true
end

local function sendResult(requestId, payload)
	if patchRequest(requestId, {
		result = payload,
		processing = false,
		finishedAt = os.time(),
	}) then
		log("Result sent for " .. requestId)
	else
		log("Failed to send result for " .. requestId)
	end
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

local function descriptionToResult(humanoid, description)
	if not humanoid or not description then
		return { error = "Failed to read outfit" }
	end

	local accessories = serializeAccessories(description)
	local animations = {
		walk = description.WalkAnimation or 0,
		run = description.RunAnimation or 0,
		jump = description.JumpAnimation or 0,
		idle = description.IdleAnimation or 0,
		fall = description.FallAnimation or 0,
		swim = description.SwimAnimation or 0,
		climb = description.ClimbAnimation or 0,
	}

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

local function processSingleOutfit(hexCode, requesterName)
	local code = tonumber(hexCode, 16)
	if not code then
		return { error = "Invalid outfit code" }
	end

	log("Processing - " .. requesterName .. " - code " .. tostring(code))

	local _, humanoidBefore = getCharacterHumanoid(3)
	if not humanoidBefore then
		return { error = "Humanoid not found" }
	end

	local beforeDescription = getHumanoidDescriptionObject(humanoidBefore, 1.5)
	if not beforeDescription then
		return { error = "No HumanoidDescription" }
	end

	local beforeFingerprint = buildDescriptionFingerprint(humanoidBefore, beforeDescription)
	local outfitSuccess, outfitInfo = pcall(function()
		return CommunityRemote:InvokeServer({
			Action = "GetFromOutfitCode",
			OutfitCode = code,
		})
	end)
	if not outfitSuccess or not outfitInfo then
		return { error = "Failed to fetch outfit" }
	end

	local wearSuccess = pcall(function()
		CommunityRemote:InvokeServer({
			Action = "WearCommunityOutfit",
			OutfitInfo = outfitInfo,
		})
	end)
	if not wearSuccess then
		return { error = "Failed to wear outfit" }
	end

	task.wait(0.2)

	local humanoidAfter, descriptionAfter = waitForFreshDescription(beforeFingerprint)
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

local function processRequest(requestId, data)
	isProcessing = true

	local requesterName = data.username or getUsername(tostring(data.userId or "unknown"))
	log("Processing request from - " .. requesterName .. " - " .. requestId)

	local success, err = pcall(function()
		local result = {}
		local codes = data.codes or (data.code and { data.code }) or {}

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
		log("Error in processing " .. tostring(err))
		sendResult(requestId, { error = tostring(err) })
	end

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

		local startedAt = tick()
		local requests = getRequests()

		for requestId, data in pairs(requests) do
			local codes = (data and data.codes) or (data and data.code and { data.code }) or {}
			if #codes > 0 and not data.result then
				if tryClaim(requestId) then
					task.spawn(processRequest, requestId, data)
					break
				end
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

log("CAC ready - original description reads with lighter speed tuning - 2026")
