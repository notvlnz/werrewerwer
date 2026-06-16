local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui", 8)

local FIREBASE_URL = "https://importer-41f0d-default-rtdb.firebaseio.com/"
local API_KEY = "AIzaSyC27Wj2awyQuzBjja4kd3t32E21oM6Sd3Y"

local POLL_INTERVAL = 0.3
local AUTH_REFRESH_MARGIN = 300
local CLAIM_TIMEOUT = 120

-- Max wait only. Fast outfits finish much sooner.
local APPLY_WAIT_WINDOW = 9
local APPLY_POLL_STEP = 0.08
local APPLY_STABLE_SECONDS = 0.65
local APPLY_FINAL_VERIFY_DELAY = 0.15
local MIN_POST_WEAR_WAIT = 0.25

-- Keep this small. The stable wait is what matters.
local BETWEEN_OUTFITS_DELAY = 0.28

-- Only used if a new code appears to return the same outfit as the last code.
local SUSPECT_DUPLICATE_EXTRA_WAIT = 1.35

local CommunityRemote = ReplicatedStorage:WaitForChild("CommunityOutfitsRemote", 8)
local CatalogGuiRemote = ReplicatedStorage:WaitForChild("CatalogGuiRemote", 8)
local EventsFolder = ReplicatedStorage:WaitForChild("Events", 8)
local UpdateStatusRemote = EventsFolder and EventsFolder:WaitForChild("UpdatePlayerStatus", 5)

local active = true
local isProcessing = false
local currentIdToken = nil
local tokenExpiresAt = 0

local MY_USER_ID = tostring(Player.UserId)
local SESSION_ID = MY_USER_ID .. "-" .. HttpService:GenerateGUID(false)
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

local function createCleanLogger()
	local old = PlayerGui:FindFirstChild("CACLogger")
	if old then
		old:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "CACLogger"
	gui.ResetOnSpawn = false
	gui.Parent = PlayerGui

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(360, 116)
	frame.Position = UDim2.fromOffset(16, 16)
	frame.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -104, 0, 30)
	title.Position = UDim2.fromOffset(14, 10)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(245, 245, 255)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "CAC Importer"
	title.Parent = frame

	local status = Instance.new("TextLabel")
	status.Size = UDim2.new(1, -28, 0, 24)
	status.Position = UDim2.fromOffset(14, 45)
	status.BackgroundTransparency = 1
	status.TextColor3 = Color3.fromRGB(205, 210, 225)
	status.Font = Enum.Font.Gotham
	status.TextSize = 13
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextTruncate = Enum.TextTruncate.AtEnd
	status.Text = "Starting"
	status.Parent = frame

	local detail = Instance.new("TextLabel")
	detail.Size = UDim2.new(1, -28, 0, 22)
	detail.Position = UDim2.fromOffset(14, 70)
	detail.BackgroundTransparency = 1
	detail.TextColor3 = Color3.fromRGB(140, 148, 166)
	detail.Font = Enum.Font.Gotham
	detail.TextSize = 12
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextTruncate = Enum.TextTruncate.AtEnd
	detail.Text = "Worker " .. MY_USER_ID
	detail.Parent = frame

	local stopButton = Instance.new("TextButton")
	stopButton.Size = UDim2.fromOffset(74, 28)
	stopButton.Position = UDim2.new(1, -88, 0, 12)
	stopButton.BackgroundColor3 = Color3.fromRGB(210, 60, 60)
	stopButton.TextColor3 = Color3.new(1, 1, 1)
	stopButton.Font = Enum.Font.GothamBold
	stopButton.TextSize = 12
	stopButton.Text = "STOP"
	stopButton.Parent = frame

	local stopCorner = Instance.new("UICorner")
	stopCorner.CornerRadius = UDim.new(0, 8)
	stopCorner.Parent = stopButton

	stopButton.MouseButton1Click:Connect(function()
		active = false
		status.Text = "Stopped"
		detail.Text = "Listener disabled"
	end)

	return function(message, subMessage)
		if not gui.Parent then
			return
		end

		status.Text = tostring(message or "")
		if subMessage ~= nil then
			detail.Text = tostring(subMessage)
		end
	end
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
	log("Refreshing auth")
	local data = httpJson("POST", "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=" .. API_KEY, {
		returnSecureToken = true,
	})

	if not data or not data.idToken then
		log("Auth failed")
		return false
	end

	currentIdToken = data.idToken
	tokenExpiresAt = tick() + (tonumber(data.expiresIn) or 3600) - AUTH_REFRESH_MARGIN
	log("Ready", "Worker " .. MY_USER_ID)
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

local function getRequest(requestId)
	if not ensureAuthToken() then
		return nil
	end

	return httpJson("GET", FIREBASE_URL .. "requests/" .. requestId .. ".json?auth=" .. currentIdToken)
end

local function tryClaim(requestId)
	if not ensureAuthToken() then
		return false, nil
	end

	local current = getRequest(requestId)
	if not current or current.result then
		return false, current
	end

	local claimedAt = tonumber(current.claimedAt)
	local timedOut = claimedAt and current.claimedBy and (os.time() - claimedAt >= CLAIM_TIMEOUT) or false
	if not timedOut and (current.claimedBy or current.processing) then
		return false, current
	end

	local claimed = patchRequest(requestId, {
		claimedBy = MY_USER_ID,
		claimedSession = SESSION_ID,
		claimedAt = os.time(),
		processing = true,
	})
	if not claimed then
		return false, current
	end

	task.wait(0.06 + math.random() * 0.05)

	local after = getRequest(requestId)
	if not after or after.claimedBy ~= MY_USER_ID or after.claimedSession ~= SESSION_ID or after.result then
		return false, after
	end

	return true, after
end

local function heartbeatClaim(requestId, index)
	patchRequest(requestId, {
		claimedAt = os.time(),
		processing = true,
		currentIndex = index,
		claimedBy = MY_USER_ID,
		claimedSession = SESSION_ID,
	})
end

local function sendResult(requestId, payload)
	local current = getRequest(requestId)
	if not current or current.result or current.claimedBy ~= MY_USER_ID or current.claimedSession ~= SESSION_ID then
		log("Skipped stale result", requestId)
		return false
	end

	local sent = patchRequest(requestId, {
		result = payload,
		processing = false,
		finishedAt = os.time(),
		completedBy = MY_USER_ID,
		completedSession = SESSION_ID,
	})

	if sent then
		log("Result sent", requestId)
	else
		log("Failed to send result", requestId)
	end

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

local function readCurrentDescription(timeoutCharacter, timeoutDescription)
	local _, humanoid = getCharacterHumanoid(timeoutCharacter or 1)
	if not humanoid then
		return nil, nil, nil
	end

	local description = getHumanoidDescriptionObject(humanoid, timeoutDescription or 0.4)
	if not description then
		return humanoid, nil, nil
	end

	local fingerprint = buildDescriptionFingerprint(humanoid, description)
	return humanoid, description, fingerprint
end

local function waitForStableChangedDescription(beforeFingerprint, previousAcceptedFingerprint, previousCode, hexCode)
	local deadline = tick() + APPLY_WAIT_WINDOW

	local lastFingerprint = nil
	local lastChangedAt = 0
	local latestHumanoid = nil
	local latestDescription = nil
	local latestFingerprint = nil

	repeat
		local humanoid, description, fingerprint = readCurrentDescription(0.75, 0.22)

		if humanoid and description and fingerprint and fingerprint ~= beforeFingerprint then
			if fingerprint ~= lastFingerprint then
				lastFingerprint = fingerprint
				lastChangedAt = tick()
			end

			latestHumanoid = humanoid
			latestDescription = description
			latestFingerprint = fingerprint

			if tick() - lastChangedAt >= APPLY_STABLE_SECONDS then
				task.wait(APPLY_FINAL_VERIFY_DELAY)

				local finalHumanoid, finalDescription, finalFingerprint = readCurrentDescription(0.75, 0.35)
				if finalHumanoid and finalDescription and finalFingerprint == lastFingerprint then
					return finalHumanoid, finalDescription, finalFingerprint, true
				end
			end
		end

		task.wait(APPLY_POLL_STEP)
	until tick() >= deadline

	return latestHumanoid, latestDescription, latestFingerprint, false
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

local function makeError(message, hexCode)
	return {
		code = tostring(hexCode),
		error = message,
	}
end

local function processSingleOutfit(hexCode, requesterName, previousAcceptedFingerprint, previousCode)
	local code = tonumber(hexCode, 16)
	if not code then
		return makeError("Invalid outfit code", hexCode), nil
	end

	log("Processing outfit", requesterName .. " - " .. tostring(hexCode))

	local humanoidBefore, beforeDescription, beforeFingerprint = readCurrentDescription(3, 1.5)
	if not humanoidBefore then
		return makeError("Humanoid not found", hexCode), nil
	end
	if not beforeDescription or not beforeFingerprint then
		return makeError("No HumanoidDescription", hexCode), nil
	end

	log("Fetching outfit", tostring(hexCode))

	local outfitSuccess, outfitInfo = pcall(function()
		return CommunityRemote:InvokeServer({
			Action = "GetFromOutfitCode",
			OutfitCode = code,
		})
	end)

	if not outfitSuccess or not outfitInfo then
		return makeError("Failed to fetch outfit", hexCode), nil
	end

	log("Wearing outfit", tostring(hexCode))

	local wearSuccess = pcall(function()
		CommunityRemote:InvokeServer({
			Action = "WearCommunityOutfit",
			OutfitInfo = outfitInfo,
		})
	end)

	if not wearSuccess then
		return makeError("Failed to wear outfit", hexCode), nil
	end

	task.wait(MIN_POST_WEAR_WAIT)

	log("Reading outfit", tostring(hexCode))

	local humanoidAfter, descriptionAfter, finalFingerprint, confirmed =
		waitForStableChangedDescription(beforeFingerprint, previousAcceptedFingerprint, previousCode, hexCode)

	if not confirmed or not humanoidAfter or not descriptionAfter or not finalFingerprint then
		return makeError("Outfit failed to load fully. Please retry this code.", hexCode), nil
	end

	-- Different code returned the exact same avatar as the previous successful code.
	-- Usually this means we caught stale data, so wait a tiny bit longer for another change.
	if previousAcceptedFingerprint
		and finalFingerprint == previousAcceptedFingerprint
		and tostring(hexCode) ~= tostring(previousCode)
	then
		log("Possible duplicate, rechecking", tostring(hexCode))

		local oldWindow = APPLY_WAIT_WINDOW
		local retryDeadline = tick() + SUSPECT_DUPLICATE_EXTRA_WAIT

		local retryHumanoid = humanoidAfter
		local retryDescription = descriptionAfter
		local retryFingerprint = finalFingerprint
		local sawNew = false

		repeat
			local h, d, f = readCurrentDescription(0.75, 0.22)
			if h and d and f and f ~= finalFingerprint and f ~= beforeFingerprint then
				retryHumanoid = h
				retryDescription = d
				retryFingerprint = f
				sawNew = true
				break
			end
			task.wait(APPLY_POLL_STEP)
		until tick() >= retryDeadline

		if sawNew then
			task.wait(APPLY_STABLE_SECONDS)
			local h2, d2, f2 = readCurrentDescription(0.75, 0.35)
			if h2 and d2 and f2 == retryFingerprint then
				humanoidAfter = h2
				descriptionAfter = d2
				finalFingerprint = f2
			else
				return makeError("Possible stale duplicate read, outfit was not saved", hexCode), nil
			end
		else
			return makeError("Possible stale duplicate read, outfit was not saved", hexCode), nil
		end
	end

	return descriptionToResult(humanoidAfter, descriptionAfter), finalFingerprint
end

local function processRequest(requestId, data)
	isProcessing = true

	local latest = getRequest(requestId) or data
	if not latest or latest.result or latest.claimedBy ~= MY_USER_ID or latest.claimedSession ~= SESSION_ID then
		isProcessing = false
		return
	end

	local requesterName = latest.username or getUsername(tostring(latest.userId or "unknown"))
	log("Processing request", requesterName .. " - " .. requestId)

	local success, err = pcall(function()
		local result = {}
		local codes = latest.codes or (latest.code and { latest.code }) or {}

		local previousAcceptedFingerprint = nil
		local previousCode = nil

		for index, hexCode in ipairs(codes) do
			local current = getRequest(requestId)
			if not current or current.result or current.claimedBy ~= MY_USER_ID or current.claimedSession ~= SESSION_ID then
				return
			end

			heartbeatClaim(requestId, index)

			local outfitResult, acceptedFingerprint =
				processSingleOutfit(hexCode, requesterName, previousAcceptedFingerprint, previousCode)

			result["outfit" .. index] = outfitResult or makeError("Unknown outfit error", hexCode)

			if outfitResult and not outfitResult.error and acceptedFingerprint then
				previousAcceptedFingerprint = acceptedFingerprint
				previousCode = hexCode
			end

			if index < #codes then
				task.wait(BETWEEN_OUTFITS_DELAY + math.random() * 0.04)
			end
		end

		task.wait(0.2)
		forceResetCharacter()
		sendResult(requestId, result)
	end)

	if not success then
		log("Processing error", tostring(err))
		sendResult(requestId, { error = tostring(err) })
	end

	isProcessing = false
end

task.spawn(function()
	if not refreshAuthToken() then
		log("Initial auth failed")
		return
	end

	log("Ready", "Waiting for requests")

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
				local claimed, claimedData = tryClaim(requestId)
				if claimed then
					task.spawn(processRequest, requestId, claimedData or data)
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

		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)

		task.wait(285 + math.random(0, 30))
	end
end)

log("Ready", "Waiting for requests ta dah")
