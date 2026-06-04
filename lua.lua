--// CAC Firebase Worker - Optimized + Styled GUI
--// Drop-in replacement for the pasted script.
--// Main fixes:
--// 1) No full database scan every 0.2s. Fetches a tiny pending batch.
--// 2) Adaptive polling/backoff to reduce Firebase/network lag and rate pressure.
--// 3) Safer nil checks for remotes/gui to prevent random crashes.
--// 4) Styled lightweight GUI using capped TextLabels instead of rebuilding one huge string.
--// 5) Request retry wrapper with timeout-ish backoff.
--// 6) Less aggressive graphics changes by default; full 3D disable can crash some clients.

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
local PlayerGui = Player:WaitForChild("PlayerGui", 10)

--// Firebase config from original script
local FIREBASE_URL = "https://cacc-c57bf-default-rtdb.firebaseio.com/"
local API_KEY = "AIzaSyBquxKffIm2lBtpi90GLLDdrQG_0yvlo4Y"

--// Tuning
local MIN_POLL_INTERVAL = 0.55
local MAX_IDLE_POLL_INTERVAL = 2.25
local ACTIVE_POLL_INTERVAL = 0.25
local PENDING_BATCH_LIMIT = 8
local AUTH_REFRESH_MARGIN = 300
local MAX_LOG_LINES = 80
local CLAIM_TIMEOUT = 75
local HTTP_RETRIES = 2
local HTTP_RETRY_DELAY = 0.18

local APPLY_WAIT_WINDOW = 4.2
local APPLY_POLL_STEP = 0.10
local APPLY_STABLE_POLLS = 2
local BETWEEN_OUTFITS_DELAY = 0.18

local DISABLE_3D_RENDERING = false
local LOW_GRAPHICS = true

local active = true
local isProcessing = false
local currentIdToken = nil
local tokenExpiresAt = 0
local currentPollInterval = MIN_POLL_INTERVAL
local processedCount = 0
local failedCount = 0
local lastRequestId = "None"
local statusText = "Starting"

local MY_USER_ID = tostring(Player.UserId)
local usernameCache = {}
local requestImpl = (syn and syn.request) or (http and http.request) or request

local guiApi = {}
local log

--// ---------- helpers ----------

local function safeCall(fn)
	local ok, result = pcall(fn)
	if ok then
		return result
	end
	return nil
end

local function trimFirebaseUrl(url)
	return (url:gsub("/+$", ""))
end

FIREBASE_URL = trimFirebaseUrl(FIREBASE_URL) .. "/"

local function roundNumber(value, decimals)
	if typeof(value) ~= "number" or value ~= value then
		return 0
	end
	local factor = 10 ^ (decimals or 3)
	return math.floor(value * factor + 0.5) / factor
end

local function jsonEncode(value)
	return HttpService:JSONEncode(value)
end

local function jsonDecode(text)
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(text)
	end)
	return ok and decoded or nil
end

local function setStatus(text)
	statusText = text
	if guiApi.setStatus then
		guiApi.setStatus(text)
	end
end

local function updateStats()
	if guiApi.setStats then
		guiApi.setStats({
			processed = processedCount,
			failed = failedCount,
			poll = currentPollInterval,
			last = lastRequestId,
			token = currentIdToken and "OK" or "None",
		})
	end
end

local function performRequest(options)
	if requestImpl then
		return requestImpl(options)
	end
	return HttpService:RequestAsync(options)
end

local function httpRaw(method, url, body, extraHeaders)
	local headers = {
		["Content-Type"] = "application/json",
		["User-Agent"] = "RobloxWinInet",
	}

	if extraHeaders then
		for k, v in pairs(extraHeaders) do
			headers[k] = v
		end
	end

	for attempt = 1, HTTP_RETRIES + 1 do
		local ok, response = pcall(function()
			return performRequest({
				Url = url,
				Method = method,
				Headers = headers,
				Body = body and jsonEncode(body) or nil,
			})
		end)

		if ok and response and response.StatusCode and response.StatusCode >= 200 and response.StatusCode < 300 then
			return response
		end

		if attempt <= HTTP_RETRIES then
			task.wait(HTTP_RETRY_DELAY * attempt)
		end
	end

	return nil
end

local function httpJson(method, url, body, headers)
	local response = httpRaw(method, url, body, headers)
	if not response or not response.Body or response.Body == "" then
		return nil
	end
	return jsonDecode(response.Body)
end

local function patchJson(url, body)
	return httpRaw("PATCH", url, body) ~= nil
end

local function encodeFirebaseOrderBy(child)
	return HttpService:UrlEncode('"' .. child .. '"')
end

--// ---------- GUI ----------

local function createStyledGui()
	local existing = PlayerGui and PlayerGui:FindFirstChild("CACOptimizedWorker")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "CACOptimizedWorker"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = PlayerGui

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromOffset(620, 390)
	root.Position = UDim2.fromOffset(18, 18)
	root.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
	root.BorderSizePixel = 0
	root.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = root

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(78, 115, 255)
	stroke.Thickness = 1.4
	stroke.Transparency = 0.25
	stroke.Parent = root

	local header = Instance.new("Frame")
	header.BackgroundColor3 = Color3.fromRGB(22, 26, 40)
	header.BorderSizePixel = 0
	header.Size = UDim2.new(1, 0, 0, 62)
	header.Parent = root

	local hCorner = Instance.new("UICorner")
	hCorner.CornerRadius = UDim.new(0, 16)
	hCorner.Parent = header

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(18, 8)
	title.Size = UDim2.new(1, -150, 0, 28)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(245, 247, 255)
	title.Text = "CAC Firebase Worker"
	title.Parent = header

	local subtitle = Instance.new("TextLabel")
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromOffset(18, 35)
	subtitle.Size = UDim2.new(1, -150, 0, 20)
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextSize = 12
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.TextColor3 = Color3.fromRGB(150, 161, 190)
	subtitle.Text = "Worker " .. MY_USER_ID .. "  •  Optimized polling"
	subtitle.Parent = header

	local statusPill = Instance.new("TextLabel")
	statusPill.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
	statusPill.Position = UDim2.new(1, -190, 0, 18)
	statusPill.Size = UDim2.fromOffset(95, 28)
	statusPill.Font = Enum.Font.GothamBold
	statusPill.TextSize = 12
	statusPill.TextColor3 = Color3.fromRGB(8, 20, 12)
	statusPill.Text = "STARTING"
	statusPill.Parent = header
	Instance.new("UICorner", statusPill).CornerRadius = UDim.new(1, 0)

	local stopButton = Instance.new("TextButton")
	stopButton.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
	stopButton.Position = UDim2.new(1, -85, 0, 18)
	stopButton.Size = UDim2.fromOffset(67, 28)
	stopButton.Font = Enum.Font.GothamBold
	stopButton.TextSize = 12
	stopButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	stopButton.Text = "STOP"
	stopButton.AutoButtonColor = true
	stopButton.Parent = header
	Instance.new("UICorner", stopButton).CornerRadius = UDim.new(1, 0)

	local cards = Instance.new("Frame")
	cards.BackgroundTransparency = 1
	cards.Position = UDim2.fromOffset(14, 76)
	cards.Size = UDim2.new(1, -28, 0, 74)
	cards.Parent = root

	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(10, 8)
	grid.CellSize = UDim2.fromOffset(140, 66)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = cards

	local statLabels = {}

	local function makeCard(name, value)
		local card = Instance.new("Frame")
		card.BackgroundColor3 = Color3.fromRGB(18, 22, 34)
		card.BorderSizePixel = 0
		card.Parent = cards
		Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromOffset(12, 9)
		label.Size = UDim2.new(1, -24, 0, 17)
		label.Font = Enum.Font.GothamMedium
		label.TextSize = 11
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = Color3.fromRGB(136, 148, 178)
		label.Text = name
		label.Parent = card

		local number = Instance.new("TextLabel")
		number.BackgroundTransparency = 1
		number.Position = UDim2.fromOffset(12, 28)
		number.Size = UDim2.new(1, -24, 0, 26)
		number.Font = Enum.Font.GothamBold
		number.TextSize = 17
		number.TextXAlignment = Enum.TextXAlignment.Left
		number.TextColor3 = Color3.fromRGB(242, 245, 255)
		number.Text = tostring(value)
		number.Parent = card

		return number
	end

	statLabels.processed = makeCard("PROCESSED", "0")
	statLabels.failed = makeCard("FAILED", "0")
	statLabels.poll = makeCard("POLL", "0.55s")
	statLabels.token = makeCard("AUTH", "None")

	local logFrame = Instance.new("Frame")
	logFrame.BackgroundColor3 = Color3.fromRGB(7, 9, 15)
	logFrame.BorderSizePixel = 0
	logFrame.Position = UDim2.fromOffset(14, 162)
	logFrame.Size = UDim2.new(1, -28, 1, -176)
	logFrame.Parent = root
	Instance.new("UICorner", logFrame).CornerRadius = UDim.new(0, 12)

	local logTitle = Instance.new("TextLabel")
	logTitle.BackgroundTransparency = 1
	logTitle.Position = UDim2.fromOffset(12, 7)
	logTitle.Size = UDim2.new(1, -24, 0, 18)
	logTitle.Font = Enum.Font.GothamBold
	logTitle.TextSize = 12
	logTitle.TextXAlignment = Enum.TextXAlignment.Left
	logTitle.TextColor3 = Color3.fromRGB(151, 167, 220)
	logTitle.Text = "LIVE LOG"
	logTitle.Parent = logFrame

	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(12, 30)
	scroll.Size = UDim2.new(1, -24, 1, -42)
	scroll.ScrollBarThickness = 4
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = logFrame

	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 3)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = scroll

	local logRows = {}

	local function addLine(message)
		print("[CAC] " .. tostring(message))

		if not gui.Parent then
			return
		end

		local row = Instance.new("TextLabel")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -4, 0, 17)
		row.Font = Enum.Font.Code
		row.TextSize = 12
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextColor3 = Color3.fromRGB(216, 222, 238)
		row.Text = os.date("%H:%M:%S") .. "  " .. tostring(message)
		row.Parent = scroll

		table.insert(logRows, row)

		while #logRows > MAX_LOG_LINES do
			local old = table.remove(logRows, 1)
			if old then
				old:Destroy()
			end
		end

		task.defer(function()
			if scroll.Parent then
				scroll.CanvasPosition = Vector2.new(0, math.max(0, scroll.AbsoluteCanvasSize.Y))
			end
		end)
	end

	stopButton.MouseButton1Click:Connect(function()
		active = false
		setStatus("Stopped")
		addLine("Listener manually stopped")
	end)

	--// draggable header
	local dragging = false
	local dragStart
	local startPos

	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = root.Position
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			root.Position = UDim2.new(
				startPos.X.Scale,
				startPos.X.Offset + delta.X,
				startPos.Y.Scale,
				startPos.Y.Offset + delta.Y
			)
		end
	end)

	guiApi.setStatus = function(text)
		if not statusPill.Parent then
			return
		end

		statusPill.Text = string.upper(tostring(text))

		if text == "Ready" or text == "Idle" then
			statusPill.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
			statusPill.TextColor3 = Color3.fromRGB(8, 20, 12)
		elseif text == "Working" or text == "Claiming" then
			statusPill.BackgroundColor3 = Color3.fromRGB(251, 191, 36)
			statusPill.TextColor3 = Color3.fromRGB(28, 20, 4)
		elseif text == "Error" or text == "Stopped" then
			statusPill.BackgroundColor3 = Color3.fromRGB(239, 68, 68)
			statusPill.TextColor3 = Color3.fromRGB(255, 255, 255)
		else
			statusPill.BackgroundColor3 = Color3.fromRGB(96, 165, 250)
			statusPill.TextColor3 = Color3.fromRGB(5, 17, 30)
		end
	end

	guiApi.setStats = function(stats)
		statLabels.processed.Text = tostring(stats.processed or 0)
		statLabels.failed.Text = tostring(stats.failed or 0)
		statLabels.poll.Text = tostring(roundNumber(stats.poll or 0, 2)) .. "s"
		statLabels.token.Text = tostring(stats.token or "None")
	end

	return addLine
end

log = createStyledGui()

--// ---------- optimization ----------

local function optimizeGraphics()
	if not LOW_GRAPHICS then
		return
	end

	safeCall(function()
		settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
	end)

	if DISABLE_3D_RENDERING then
		safeCall(function()
			RunService:Set3dRenderingEnabled(false)
		end)
	end

	safeCall(function()
		Lighting.GlobalShadows = false
		Lighting.Brightness = 1
		Lighting.Ambient = Color3.fromRGB(255, 255, 255)
		Lighting.OutdoorAmbient = Color3.fromRGB(255, 255, 255)
		Lighting.EnvironmentDiffuseScale = 0
		Lighting.EnvironmentSpecularScale = 0
		Lighting.Technology = Enum.Technology.Compatibility
	end)

	for _, effect in ipairs(Lighting:GetChildren()) do
		if effect:IsA("PostEffect") then
			safeCall(function()
				effect.Enabled = false
			end)
		end
	end

	safeCall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	end)

	safeCall(function()
		StarterGui:SetCore("ChatActive", false)
	end)

	safeCall(function()
		UserInputService.MouseIconEnabled = false
	end)

	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		safeCall(function()
			terrain.WaterReflectance = 0
			terrain.WaterTransparency = 1
			terrain.WaterWaveSize = 0
			terrain.WaterWaveSpeed = 0
		end)
	end

	for _, obj in ipairs(Workspace:GetDescendants()) do
		if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam") then
			safeCall(function()
				obj.Enabled = false
			end)
		elseif obj:IsA("Texture") or obj:IsA("Decal") then
			safeCall(function()
				obj.Transparency = 1
			end)
		end
	end

	log("Graphics tuned without forced 3D shutdown")
end

--// ---------- remotes ----------

local CommunityRemote = ReplicatedStorage:WaitForChild("CommunityOutfitsRemote", 12)
local CatalogGuiRemote = ReplicatedStorage:WaitForChild("CatalogGuiRemote", 12)
local EventsFolder = ReplicatedStorage:WaitForChild("Events", 8)
local UpdateStatusRemote = EventsFolder and EventsFolder:FindFirstChild("UpdatePlayerStatus")

local function remotesReady()
	if not CommunityRemote then
		log("Missing CommunityOutfitsRemote")
		return false
	end

	if not CatalogGuiRemote then
		log("Missing CatalogGuiRemote")
		return false
	end

	return true
end

--// ---------- firebase ----------

local function refreshAuthToken()
	setStatus("Auth")
	log("Refreshing Firebase token")

	local data = httpJson("POST", "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=" .. API_KEY, {
		returnSecureToken = true,
	})

	if not data or not data.idToken then
		log("Firebase auth failed")
		setStatus("Error")
		return false
	end

	currentIdToken = data.idToken
	tokenExpiresAt = tick() + (tonumber(data.expiresIn) or 3600) - AUTH_REFRESH_MARGIN

	log("Token refreshed")
	updateStats()

	return true
end

local function ensureAuthToken()
	if currentIdToken and tick() < tokenExpiresAt then
		return true
	end

	return refreshAuthToken()
end

local function authedUrl(pathAndQuery)
	local join = string.find(pathAndQuery, "?", 1, true) and "&" or "?"
	return FIREBASE_URL .. pathAndQuery .. join .. "auth=" .. currentIdToken
end

local function getPendingRequests()
	if not ensureAuthToken() then
		return {}
	end

	--// Big Firebase speed fix:
	--// Original script downloaded /requests.json every poll.
	--// This requests only a few entries where result is null/missing.
	--// For best speed, add Firebase rule:
	--// ".indexOn": ["result", "claimedAt"]
	local query = "requests.json?orderBy=" .. encodeFirebaseOrderBy("result") .. "&equalTo=null&limitToFirst=" .. tostring(PENDING_BATCH_LIMIT)

	return httpJson("GET", authedUrl(query)) or {}
end

local function getRequest(requestId)
	if not ensureAuthToken() then
		return nil
	end

	return httpJson("GET", authedUrl("requests/" .. requestId .. ".json"))
end

local function patchRequest(requestId, data)
	if not ensureAuthToken() then
		return false
	end

	return patchJson(authedUrl("requests/" .. requestId .. ".json"), data)
end

local function tryClaim(requestId)
	setStatus("Claiming")

	local current = getRequest(requestId)
	if not current or current.result then
		return false
	end

	local claimedAt = tonumber(current.claimedAt)
	local timedOut = claimedAt and current.claimedBy and (os.time() - claimedAt >= CLAIM_TIMEOUT) or false

	if not timedOut and (current.claimedBy or current.processing) then
		return false
	end

	local claimStamp = os.time()

	local claimed = patchRequest(requestId, {
		claimedBy = MY_USER_ID,
		claimedAt = claimStamp,
		processing = true,
		workerStatus = "claimed",
	})

	if not claimed then
		return false
	end

	--// Verify claim. This is not fully atomic, but much safer than blindly processing.
	task.wait(0.05 + math.random() * 0.05)

	local after = getRequest(requestId)
	if not after or tostring(after.claimedBy) ~= MY_USER_ID or tonumber(after.claimedAt) ~= claimStamp then
		log("Claim race lost -> " .. requestId)
		return false
	end

	log((timedOut and "Reclaimed timed out -> " or "Claimed -> ") .. requestId)
	return true
end

local function sendResult(requestId, payload)
	local ok = patchRequest(requestId, {
		result = payload,
		processing = false,
		workerStatus = "finished",
		finishedAt = os.time(),
	})

	if ok then
		processedCount += 1
		log("Result sent -> " .. requestId)
	else
		failedCount += 1
		log("Failed to send result -> " .. requestId)
	end

	updateStats()
end

--// ---------- outfit logic ----------

local function forceResetCharacter()
	if CatalogGuiRemote then
		safeCall(function()
			CatalogGuiRemote:InvokeServer({
				Action = "MorphIntoPlayer",
				UserId = Player.UserId,
				RigType = Enum.HumanoidRigType.R15,
			})
		end)
	end

	if UpdateStatusRemote then
		safeCall(function()
			UpdateStatusRemote:FireServer("None")
		end)
	end

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
		if not humanoid or not humanoid.Parent then
			break
		end

		local description = humanoid:FindFirstChildOfClass("HumanoidDescription") or humanoid:FindFirstChild("HumanoidDescription")

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
	local bestHumanoid
	local bestDescription
	local changedHumanoid
	local changedDescription
	local lastChangedFingerprint
	local stablePolls = 0

	repeat
		local _, humanoid = getCharacterHumanoid(0.65)

		if humanoid then
			local description = getHumanoidDescriptionObject(humanoid, 0.2)

			if description then
				local fingerprint = buildDescriptionFingerprint(humanoid, description)

				bestHumanoid = humanoid
				bestDescription = description

				if fingerprint and fingerprint ~= beforeFingerprint then
					changedHumanoid = humanoid
					changedDescription = description

					if fingerprint == lastChangedFingerprint then
						stablePolls += 1
					else
						lastChangedFingerprint = fingerprint
						stablePolls = 1
					end

					if stablePolls >= APPLY_STABLE_POLLS then
						task.wait(0.05)
						return changedHumanoid, changedDescription
					end
				end
			end
		end

		task.wait(APPLY_POLL_STEP)
	until tick() >= deadline

	return changedHumanoid or bestHumanoid, changedDescription or bestDescription
end

local function descriptionToResult(humanoid, description)
	if not humanoid or not description then
		return {
			error = "Failed to read outfit"
		}
	end

	local accessories = serializeAccessories(description)

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

		Animations = {
			walk = description.WalkAnimation or 0,
			run = description.RunAnimation or 0,
			jump = description.JumpAnimation or 0,
			idle = description.IdleAnimation or 0,
			fall = description.FallAnimation or 0,
			swim = description.SwimAnimation or 0,
			climb = description.ClimbAnimation or 0,
		},
	}
end

local function processSingleOutfit(hexCode, requesterName)
	local code = tonumber(hexCode, 16)

	if not code then
		return {
			error = "Invalid outfit code"
		}
	end

	log("Processing " .. requesterName .. " / code " .. tostring(code))

	local _, humanoidBefore = getCharacterHumanoid(3)

	if not humanoidBefore then
		return {
			error = "Humanoid not found"
		}
	end

	local beforeDescription = getHumanoidDescriptionObject(humanoidBefore, 1.5)

	if not beforeDescription then
		return {
			error = "No HumanoidDescription"
		}
	end

	local beforeFingerprint = buildDescriptionFingerprint(humanoidBefore, beforeDescription)

	local outfitSuccess, outfitInfo = pcall(function()
		return CommunityRemote:InvokeServer({
			Action = "GetFromOutfitCode",
			OutfitCode = code,
		})
	end)

	if not outfitSuccess or not outfitInfo then
		return {
			error = "Failed to fetch outfit"
		}
	end

	local wearSuccess = pcall(function()
		CommunityRemote:InvokeServer({
			Action = "WearCommunityOutfit",
			OutfitInfo = outfitInfo,
		})
	end)

	if not wearSuccess then
		return {
			error = "Failed to wear outfit"
		}
	end

	local humanoidAfter, descriptionAfter = waitForFreshDescription(beforeFingerprint)

	if not humanoidAfter or not descriptionAfter then
		return {
			error = "Failed to read outfit"
		}
	end

	local result = descriptionToResult(humanoidAfter, descriptionAfter)

	log("Done / accessories " .. tostring(#(((result.Accessories or {}).Other) or {})))

	return result
end

local function processRequest(requestId, data)
	isProcessing = true
	setStatus("Working")

	lastRequestId = requestId
	updateStats()

	local requesterName = tostring(data.username or getUsername(tostring(data.userId or "unknown")))

	log("Processing request from " .. requesterName .. " -> " .. requestId)

	local ok, err = pcall(function()
		local result = {}
		local codes = data.codes or (data.code and { data.code }) or {}

		if #codes == 0 then
			result.error = "No codes supplied"
		else
			for index, hexCode in ipairs(codes) do
				result["outfit" .. index] = processSingleOutfit(hexCode, requesterName)

				if index < #codes then
					task.wait(BETWEEN_OUTFITS_DELAY + math.random() * 0.04)
				end
			end
		end

		forceResetCharacter()
		sendResult(requestId, result)
	end)

	if not ok then
		failedCount += 1

		log("Error processing -> " .. tostring(err))

		patchRequest(requestId, {
			result = {
				error = tostring(err)
			},
			processing = false,
			workerStatus = "error",
			finishedAt = os.time(),
		})

		updateStats()
	end

	isProcessing = false
	setStatus("Ready")
end

--// ---------- main loops ----------

task.spawn(optimizeGraphics)

if not remotesReady() then
	active = false
	setStatus("Error")
	log("Stopped because required remotes are missing")
else
	task.spawn(function()
		if not refreshAuthToken() then
			log("Initial auth failed -> stopping")
			active = false
			return
		end

		setStatus("Ready")
		log("Listener active / optimized Firebase batch polling")
		updateStats()

		while active do
			if isProcessing then
				task.wait(0.08)
				continue
			end

			local startedAt = tick()
			local didWork = false
			local pending = getPendingRequests()

			for requestId, data in pairs(pending) do
				if typeof(data) == "table" then
					local codes = data.codes or (data.code and { data.code }) or {}

					if #codes > 0 and not data.result then
						if tryClaim(requestId) then
							didWork = true
							task.spawn(processRequest, requestId, data)
							break
						end
					end
				end
			end

			if didWork then
				currentPollInterval = ACTIVE_POLL_INTERVAL
			else
				setStatus("Idle")
				currentPollInterval = math.min(MAX_IDLE_POLL_INTERVAL, currentPollInterval + 0.20)
			end

			updateStats()

			local elapsed = tick() - startedAt

			if elapsed < currentPollInterval then
				task.wait(currentPollInterval - elapsed)
			end
		end
	end)
end

task.spawn(function()
	while active do
		Player.Idled:Wait()

		if not active then
			break
		end

		log("Anti-AFK triggered")

		safeCall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)

		task.wait(285 + math.random(0, 30))
	end
end)

log("CAC ready / optimized GUI build / 2026")
