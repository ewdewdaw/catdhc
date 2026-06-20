-- CatAlt v5.0 — CatBase + HexaHub Hybrid
-- CatBase cloud communication for cross-server alt control
-- Chat command listener for same-server control (HexaHub-style)
-- Bot indexing for formations (circle, arch, align, tower, worm)
-- 6 orbit variants, stalk, spin, and all HexaHub commands
-- Two-panel GUI with search, selection, and dynamic params

-- ════════ CONFIG ════════
local OWNER_USER_ID = 11134728653
local SESSION_KEY = "default"
local API_KEY = "8c646cec71e445488221775e87f9230af841d3d6e7af8c906dc276d66af76af8"
local CATBASE_URL = "https://catbase.catapis.uk/db/altcontrol"
local FIREBASE_URL = "https://randomer-5cfca-default-rtdb.europe-west1.firebasedatabase.app"
local POLL_INTERVAL = 2.5
local PREFIX = ";"
local VERSION = "1.0"
local IY_URL = "https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source"
local IY_LOGO_IMAGE = "rbxassetid://1352543873"
local AUTO_LOAD_IY = true
-- Prevent duplicate injection (no return — Delta persists env across rejoins, return would exit chunk with nil)
if _G.CatAlt_Running then warn("[CatAlt] Already running (re-inject on reconnect)") end
_G.CatAlt_Running = true

-- ════════ SERVICES ════════
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local TextChatService = game:GetService("TextChatService")
local LocalPlayer = Players.LocalPlayer
local Owner = LocalPlayer.UserId == OWNER_USER_ID
local renderStatus = "Rendering: N/A (owner)"
if not Owner then
    local ok = pcall(function() RunService:Set3dRenderingEnabled(false) end)
    if ok then
        renderStatus = "Rendering: OFF (native)"
    else
        pcall(function() game:GetService("RenderSettings").QualityLevel = 1 end)
        pcall(function()
            local c = game.Workspace.CurrentCamera
            if c then c.CameraType = Enum.CameraType.Scriptable; c.CFrame = CFrame.new(0, 9999, 0) end
        end)
        renderStatus = "Rendering: OFF (fallback)"
    end
end

-- Early overlay for alts (shows immediately, before startup)
if not Owner then
    task.spawn(function()
        local ok, pg = pcall(function() return LocalPlayer:WaitForChild("PlayerGui", 10) end)
        if not ok or not pg then return end
        local scr = Instance.new("ScreenGui")
        scr.Name = "CatAltLoading"; scr.ResetOnSpawn = false; scr.Parent = pg; scr.IgnoreGuiInset = true
        local bg = Instance.new("Frame")
        bg.Size = UDim2.new(1, 0, 1, 0); bg.BackgroundColor3 = Color3.new(0, 0, 0)
        bg.BackgroundTransparency = 0; bg.BorderSizePixel = 0; bg.Parent = scr
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, 0, 0, 30); lbl.Position = UDim2.new(0, 0, 0.5, -15)
        lbl.Text = "CatAlt v" .. VERSION .. " — Loading..."; lbl.TextColor3 = Color3.fromRGB(150, 150, 150)
        lbl.Font = Enum.Font.Gotham; lbl.TextSize = 18
        lbl.TextXAlignment = Enum.TextXAlignment.Center; lbl.BackgroundTransparency = 1
        lbl.Parent = scr
    end)
end

-- HTTP detection
local http = (K and K.Request) or (syn and syn.request) or http_request or request
if not http then warn("[CatAlt] No HTTP function found"); return end

-- JSON helpers
local function jsonEncode(t) return HttpService:JSONEncode(t) end
local function jsonDecode(s)
    if not s or s == "" then return nil end
    local ok, r = pcall(HttpService.JSONDecode, HttpService, s)
    return ok and r or nil
end

-- ════════ STATE ════════
local MY_ID = tostring(LocalPlayer.UserId)
local MNAME = LocalPlayer.Name
local isRunning = true
task.spawn(function()
    while isRunning do
        task.wait(1)
        local ok, p = pcall(function() return LocalPlayer and LocalPlayer.Parent end)
        if not ok or not p then isRunning = false end
    end
end)

local botList = {} -- array of {userId, name, displayName, isOwner}, sorted by userId
local OWNER_NAME = nil -- discovered from botList
local botIndex = nil
local botNumber = nil -- fixed index from alts.json (1,2,3...), never changes
local totalAlts = 0 -- total alts in alts.json (for orbit spacing)
-- Returns totalOnline, myIndex, spacingRadians, angleOffsetRadians
-- Uses botList (same-server) when available, else totalAlts (global)
-- Guaranteed to return total >= 1, myIdx >= 1
local function getSpacing()
    local total, myIdx
    if #botList > 0 then
        total = #botList; myIdx = botIndex or 1
    elseif totalAlts > 0 then
        total = totalAlts; myIdx = botNumber or 1
    else
        total = 1; myIdx = 1
    end
    total = math.max(total, 1)
    myIdx = math.max(myIdx, 1)
    local spacing = math.pi * 2 / total
    return total, myIdx, spacing, (myIdx - 1) * spacing
end
local swordBool = false
local explodeBool = false
local meteorBool = false
local orbitBool = false
local flingOrbitBool = false
local missileBool = false
local showcaseBool = false
local walkflingBool = false
local walkflingConn = nil
local flingMode = false
local platformBool = false
local platformMaxY = nil
local platformConn = nil
local platformActive = false
local flingChams = {}
local flingConnection = nil
local flingPlayerAdded = nil
local currentAction = "Idle"

local UI -- forward declaration (assigned in UI section below)
local IY_ACTIONS = {} -- populated by parsing IY source at startup
local IY_ACTIONS_INITIALIZED = false
local execIYCommand -- forward declaration

-- Returns {totalOnline, onlineIds} from UI.Alts (excluding owner), or nil,nil
local function getOnlineIds()
    if not UI or not UI.Alts then return nil, nil end
    local ids = {}
    for id, st in pairs(UI.Alts) do
        if id ~= MY_ID and (os.time() - (st.lastPing or 0)) <= 10 then
            table.insert(ids, id)
        end
    end
    if #ids == 0 then return nil, nil end
    table.sort(ids)
    return #ids, ids
end

-- ════════ CATBASE CLIENT + FIREBASE FALLBACK ════════
local function catbase(method, path, body)
    local function try(url, headers)
        local opts = { Url = url, Method = method, Headers = headers }
        if body ~= nil then
            opts.Headers["Content-Type"] = "application/json"
            opts.Body = jsonEncode(body)
        end
        local ok, res = pcall(http, opts)
        if ok and res and res.StatusCode >= 200 and res.StatusCode < 300 then
            return true, jsonDecode(res.Body)
        end
        return false, nil
    end
    local ok, data = try(CATBASE_URL .. path, { ["X-API-Key"] = API_KEY, ["Accept"] = "application/json" })
    if ok then return true, data end
    -- Fallback to Firebase (no auth key needed)
    local fbPath = path:gsub("%.json$", "")
    return try(FIREBASE_URL .. fbPath .. ".json", { ["Accept"] = "application/json" })
end

local function catbasePut(p, d) return catbase("PUT", p, d) end
local function catbaseGet(p) return catbase("GET", p) end

-- ════════ HELPERS ════════
local function getChar() return LocalPlayer.Character end
local function getRoot()
    local c = getChar()
    return c and c:FindFirstChild("HumanoidRootPart") or nil
end
local function getPos()
    local r = getRoot()
    return r and r.Position or Vector3.new(0, 0, 0)
end
local function waitForCharacter()
    if getChar() then return true end
    for _ = 1, 60 do task.wait(0.5); if getChar() then return true end end
    return false
end

local function copyErr(msg)
    local full = "[CatAlt] " .. tostring(msg)
    pcall(setclipboard, full); pcall(syn.write_clipboard, full); pcall(function() getgenv().lastError = full end)
end

local function findPlayerByName(partialName)
    if type(partialName) ~= "string" or partialName == "" then return nil end
    local lower = partialName:lower()
    if lower == "me" and OWNER_NAME then return Players:FindFirstChild(OWNER_NAME) end
    local best, bestScore = nil, 0
    for _, plr in ipairs(Players:GetPlayers()) do
        local nm = plr.Name:lower()
        local dn = plr.DisplayName:lower()
        local nPos, dPos = nm:find(lower, 1, true), dn:find(lower, 1, true)
        local score = (nPos and #nm or 0) + (dPos and #dn or 0)
        if score > bestScore then bestScore = score; best = plr end
    end
    return best
end

local function findPlayerByPart(part)
    if not part then return nil end
    local p = part
    while p do
        if p:IsA("Model") then
            local plr = Players:GetPlayerFromCharacter(p)
            if plr then return plr end
        end
        p = p.Parent
    end
    return nil
end

local noclipOn = false
task.spawn(function()
    while isRunning do
        local c = getChar()
        if noclipOn and c then
            for _, p in ipairs(c:GetDescendants()) do
                if p:IsA("BasePart") then p.CanCollide = false; p.CanTouch = false; p.CanQuery = false end
            end
        end
        RunService.Heartbeat:Wait()
    end
end)

local function sineEase(t) return 0.5 - 0.5 * math.cos(math.pi * math.min(t, 1)) end

local function moveBot(root, targetPos, lookAt, syncTarget)
    if not root then return end
    if not Owner then noclipOn = true end
    local target = syncTarget or root
    pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", target) end)
    local hum = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
    if hum then hum.AutoRotate = false end
    local dir = targetPos - root.Position
    local vel = dir.Magnitude > 0.5 and dir.Unit * math.clamp(dir.Magnitude * 10, 5, 200) or Vector3.zero
    root.CFrame = lookAt and CFrame.lookAt(targetPos, lookAt) or CFrame.new(targetPos)
    root.Velocity = vel
    pcall(function() root.AssemblyLinearVelocity = vel end)
end

local ANIMS = {
    run  = "rbxassetid://7078549298",
    walk = "rbxassetid://7078538757",
    idle = "rbxassetid://7078551220",
}
local animTrack = nil
local function playAnim(root, animId, speed)
    if not root then return end
    local hum = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    if animTrack then pcall(function() animTrack:Stop() end); animTrack = nil end
    local animator = hum:FindFirstChild("Animator")
    if not animator then animator = Instance.new("Animator", hum) end
    local anim = Instance.new("Animation")
    anim.AnimationId = animId
    local ok, track = pcall(animator.LoadAnimation, animator, anim)
    if ok and track then
        animTrack = track; track.Priority = Enum.AnimationPriority.Action4
        track.Looped = true; track:Play(0, speed or 1, 0)
        if speed then track:AdjustSpeed(speed) end
        local total, _, _, _ = getSpacing()
        if total > 1 then
            local stagger = ((botIndex or botNumber or 1) - 1) / total
            pcall(function() track.TimePosition = (track.Length or 2) * stagger end)
        end
    end
end
local function stopAnim()
    if animTrack then pcall(function() animTrack:Stop() end); animTrack = nil end
end

local function removeVelocity()
    local c = getChar()
    if not c then return end
    for _, v in ipairs(c:GetDescendants()) do
        if v:IsA("BasePart") then
            v.Velocity = Vector3.zero
            v.RotVelocity = Vector3.zero
        elseif v:IsA("BodyVelocity") then v.Velocity = Vector3.zero
        elseif v:IsA("BodyAngularVelocity") then v.AngularVelocity = Vector3.zero
        end
    end
end

local function disableBools()
    swordBool = false; explodeBool = false; meteorBool = false; orbitBool = false; flingOrbitBool = false; missileBool = false; showcaseBool = false; walkflingBool = false; flingMode = false; platformBool = false; if platformConn then platformConn:Disconnect(); platformConn = nil end; for _, hl in ipairs(flingChams) do pcall(function() hl:Destroy() end) end; flingChams = {}; if flingConnection then flingConnection:Disconnect(); flingConnection = nil end;     if flingPlayerAdded then flingPlayerAdded:Disconnect(); flingPlayerAdded = nil end; currentAction = "Idle"
    stopAnim()
    noclipOn = false; pcall(function() game.Workspace.Gravity = 196.2 end)
    local c = getChar()
    if c then
        for _, p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = true end
        end
        local r = getRoot()
        if r then r.Velocity = Vector3.new(0, -30, 0) end
    end
end

local chatEnabled = false

local function chatMessage(str)
    pcall(function()
        if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
            TextChatService.TextChannels.RBXGeneral:SendAsync(tostring(str))
        else
            game.ReplicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(tostring(str), "All")
        end
    end)
end

-- Register this account in CatBase bot list
local function registerBot()
    catbasePut("/" .. SESSION_KEY .. "/bots/" .. MY_ID .. ".json", {
        name = MNAME,
        displayName = LocalPlayer.DisplayName,
        isOwner = Owner,
        joinedAt = os.time()
    })
end

-- Discover all registered bots from CatBase, compute index and owner name
local function discoverBots()
    local ok, data = catbaseGet("/" .. SESSION_KEY .. "/bots.json")
    if not ok or type(data) ~= "table" then return end
    -- Get online alts to filter out bots that left AND to assign botNumber
    local okAlt, altData = catbaseGet("/" .. SESSION_KEY .. "/alts.json")
    local sameServer = {}
    local altNumbers = {} -- id -> botNumber (stable index in alts.json)
    if okAlt and type(altData) == "table" then
        -- Sort alt keys for stable numbering
        local altKeys = {}
        for id in pairs(altData) do table.insert(altKeys, id) end
        table.sort(altKeys)
        for i, id in ipairs(altKeys) do
            local st = altData[id]
            if (os.time() - (st.lastPing or 0)) <= 10 and st.jobId == game.JobId then
                sameServer[id] = true
            end
            altNumbers[id] = i -- 1-based position
        end
    end
    local ids = {}
    for id in pairs(data) do table.insert(ids, id) end
    table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
    botList = {}
    OWNER_NAME = nil
    for _, id in ipairs(ids) do
        local entry = data[id]
        -- Only include bots that are in the same server AND online
        if sameServer[id] then
            entry._id = id
            entry.botNumber = altNumbers[id] or 999
            table.insert(botList, entry)
            if entry.isOwner then OWNER_NAME = entry.name end
        end
    end
    -- Sort by botNumber so online order = alts.json order
    table.sort(botList, function(a, b) return (a.botNumber or 999) < (b.botNumber or 999) end)
    botIndex = nil
    for i, entry in ipairs(botList) do
        if entry.name == MNAME then botIndex = i; break end
    end
    if botIndex and #botList > 0 then end
end

-- ════════ ANTI-AFK ════════
local function startAntiAfk()
    task.spawn(function()
        local actions = {
            function(h, r)
                h:ChangeState(Enum.HumanoidStateType.GettingUp)
                r.CFrame = r.CFrame * CFrame.new(0.5, 0, 0)
            end,
            function(h, r)
                h:ChangeState(Enum.HumanoidStateType.Jumping)
                r.CFrame = r.CFrame * CFrame.Angles(0, math.rad(math.random(-30, 30)), 0)
            end,
            function(h, r)
                h:ChangeState(Enum.HumanoidStateType.Running)
                r.CFrame = r.CFrame * CFrame.new(-0.5, 0, 0.5)
            end,
            function(h, r)
                h:ChangeState(Enum.HumanoidStateType.Running)
                r.CFrame = r.CFrame * CFrame.new(0, 0, -0.8)
            end,
            function(h, r)
                h:ChangeState(Enum.HumanoidStateType.GettingUp)
                r.CFrame = r.CFrame * CFrame.Angles(0, math.rad(90), 0)
            end,
        }
        while isRunning do
            task.wait(math.random(840, 960))
            pcall(function()
                local c = getChar()
                if c then
                    local h = c:FindFirstChild("Humanoid")
                    local r = c:FindFirstChild("HumanoidRootPart")
                    if h and r then
                        local fn = actions[math.random(#actions)]
                        fn(h, r)
                    end
                end
            end)
        end
    end)
end

-- ════════ COMMAND HANDLERS ════════
local CMD = {}

-- Movement prediction: tracks positions with timestamps to calculate real velocity
-- Predicts 300ms ahead to account for ping + server reconciliation delay
-- This puts the alt INTO the target's path instead of trailing behind
function CMD.tp(data)
    local pos = data.position
    local root = getRoot()
    if root and pos then
        removeVelocity()
        root.CFrame = CFrame.new(pos[1], pos[2], pos[3])
    end
end

function CMD.rejoin(data)
    pcall(function() game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer) end)
end

function CMD.joinmaster(data)
    task.spawn(function()
        local ok, alts = catbaseGet("/" .. SESSION_KEY .. "/alts.json")
        if ok and type(alts) == "table" then
            for _, st in pairs(alts) do
                if st.isOwner and st.jobId and st.placeId then
                    pcall(function() TeleportService:TeleportToPlaceInstance(st.placeId, st.jobId, LocalPlayer) end)
                    return
                end
            end
        end
    end)
end

function CMD.reload(data)
    pcall(CMD.stop)
    _G.CatAlt_Running = false
    task.spawn(function()
        task.wait(0.5)
        local f = (syn and syn.reload) or reload or reloadscript or reloadscripts
        if f then pcall(f) end
    end)
end

function CMD.execute(data)
    local code = data.code
    if code and code ~= "" then
        currentAction = "Executing..."
        task.spawn(function()
            local fn, err = loadstring(code)
            if fn then
                local ok, result = pcall(fn)
                if not ok then warn("[CatAlt] Execute error:", tostring(result)) end
            else
                warn("[CatAlt] Execute compile error:", tostring(err))
            end
        end)
    end
end

function CMD.leave(data)
    pcall(function() game:GetService("TeleportService"):Teleport(0, LocalPlayer) end)
end

function CMD.jump(data)
    currentAction = "Jumping"
    local root = getRoot()
    if root then
        pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", root) end)
        root.Velocity = Vector3.new(0, 50, 0)
        local c = getChar()
        if c then
            local h = c:FindFirstChildOfClass("Humanoid")
            if h then pcall(function() h:ChangeState(Enum.HumanoidStateType.Jumping) end) end
        end
    end
end

function CMD.stop(data)
    swordBool = false; explodeBool = false; meteorBool = false; orbitBool = false; flingOrbitBool = false; walkflingBool = false; flingMode = false; platformBool = false; if platformConn then platformConn:Disconnect(); platformConn = nil end; for _, hl in ipairs(flingChams) do pcall(function() hl:Destroy() end) end; flingChams = {}; if flingConnection then flingConnection:Disconnect(); flingConnection = nil end; if flingPlayerAdded then flingPlayerAdded:Disconnect(); flingPlayerAdded = nil end;     if walkflingConn then walkflingConn:Disconnect(); walkflingConn = nil end; currentAction = "Idle"
    disableBools()
    local c = getChar()
    local root = getRoot()
    if root then
        for _, name in ipairs({"ExplodeSpin"}) do
            local m = root:FindFirstChild(name)
            if m then m:Destroy() end
        end
        removeVelocity()
        if root then pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", root) end) end
    end
    pcall(function() game.Workspace.Gravity = 196.2 end)
    -- Kill all IY effects: movement, toggle loops, goto, fly, etc.
    if _G.CatAlt_IY_Loaded then
        execIYCommand("unwalkfling")
        execIYCommand("unfly")
        execIYCommand("unwalkto")
        execIYCommand("unfollow")
        execIYCommand("unspin")
        execIYCommand("unjump")
        execIYCommand("unloop")
        execIYCommand("ungoto")
        execIYCommand("unorbit")
        execIYCommand("breakloops")
    end
end

-- Removed all extra CMD functions. Keeping only sword, explode, meteor.
function CMD.sword(data)
    local targetName, distance, velocity, offset = data.target, data.distance or 5, data.velocity or -50, data.offset or 2
    if not targetName then return end
    swordBool = true; currentAction = "Sword (" .. targetName .. ")"
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not swordBool or not isRunning then
            conn:Disconnect()
            local r = getRoot()
            if r then pcall(function() sethiddenproperty(r, "PhysicsRepRootPart", r) end) end
            return
        end
        local tgt = findPlayerByName(targetName)
        local root = getRoot()
        if tgt and tgt.Character and root then
            local tgtRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
            local tgtHum = tgt.Character:FindFirstChild("Humanoid")
            if tgtRoot and tgtHum and tgtHum.Health > 0 then
                local total, myIdx = getSpacing()
                local adjustedDist = distance + (myIdx - 1) * offset
                pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", tgtRoot) end)
                local forwardVec = tgtRoot.CFrame.LookVector * adjustedDist
                local desiredPos = tgtRoot.Position + forwardVec
                root.CFrame = CFrame.lookAt(desiredPos, tgtRoot.Position) * CFrame.Angles(math.rad(90), 0, 0)
                root.Velocity = (tgtRoot.Position - root.Position).Unit * velocity
            end
        end
    end)
end

function CMD.explode(data)
    local targetName, velocity = data.target, data.velocity or -50
    explodeBool = true; currentAction = "Explode (" .. targetName .. ")"
    local char = getChar()
    local root = getRoot()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum then return end
    hum:ChangeState(Enum.HumanoidStateType.Physics)
    local spin = Instance.new("BodyAngularVelocity")
    spin.Name = "ExplodeSpin"
    spin.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
    spin.Parent = root
    local conn
    conn = RunService.Heartbeat:Connect(function()
        local cr = getRoot()
        if not explodeBool or not isRunning or not cr then
            conn:Disconnect(); if spin and spin.Parent then spin:Destroy() end
            pcall(function() sethiddenproperty(cr or root, "PhysicsRepRootPart", cr or root) end)
            return
        end
        root = cr
        local tgt = targetName and findPlayerByName(targetName)
        local tr = tgt and tgt.Character and tgt.Character:FindFirstChild("HumanoidRootPart")
        local targetPos = tr and tr.Position or root.Position
        if tr then pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", tr) end) end
        root.CFrame = CFrame.lookAt(targetPos + Vector3.new(0, 0.5, 0), targetPos) * CFrame.Angles(math.rad(90), 0, 0)
        spin.AngularVelocity = Vector3.new(
            velocity * (math.random(0, 1) == 1 and 1 or -1),
            velocity * (math.random(0, 1) == 1 and 1 or -1),
            velocity * (math.random(0, 1) == 1 and 1 or -1)
        )
        root.Velocity = (targetPos - root.Position).Unit * velocity
    end)
    task.delay(0.25, function() if explodeBool then local c = getChar(); if c then local h = c:FindFirstChild("Humanoid"); if h then h.Health = 0 end end end end)
end

function CMD.meteor(data)
    local targetName, spawnHeight, diveSpeed = data.target, tonumber(data.spawnHeight) or 90, tonumber(data.diveSpeed) or 150
    if not targetName then return end
    meteorBool = true; currentAction = "Meteor (" .. targetName .. ")"
    local root = getRoot()
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum then meteorBool = false; return end
    hum.PlatformStand = true
    playAnim(getRoot(), ANIMS.run, 3)
    local horizDist = 110
    pcall(function()
        if sethiddenproperty then
            sethiddenproperty(Players.LocalPlayer, "MaximumSimulationRadius", math.huge)
            sethiddenproperty(Players.LocalPlayer, "SimulationRadius", math.huge)
        end
    end)
    local pos = root.Position
    local vel = Vector3.zero
    local phase = "charge"
    local phaseT = 0
    local diveT = 0
    local spinA = math.random() * math.pi * 2
    local spinB = math.random() * math.pi * 2
    local spinRate = 6
    local detonated = false
    local initialized = false
    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not meteorBool or not isRunning then
            conn:Disconnect()
            if hum then hum.PlatformStand = false end
            stopAnim()
            local r = getRoot()
            if r then pcall(function() sethiddenproperty(r, "PhysicsRepRootPart", r) end) end
            return
        end
        local tgt = findPlayerByName(targetName)
        root = getRoot()
        if not tgt or not tgt.Character or not root then return end
        local tgtRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
        local tgtHum = tgt.Character:FindFirstChildOfClass("Humanoid")
        if not tgtRoot or not tgtHum or tgtHum.Health <= 0 then return end
        if not initialized then
            initialized = true
            local _, myIdx, _, angleOffset = getSpacing()
            pos = tgtRoot.Position + Vector3.new(math.cos(angleOffset) * horizDist, spawnHeight, math.sin(angleOffset) * horizDist)
            root.CFrame = CFrame.new(pos)
        end
        dt = math.min(dt, 1 / 30)
        phaseT = phaseT + dt
        local goalDir = Vector3.yAxis
        if phase == "charge" then
            local tp = tgtRoot.Position
            local hover = pos
            local accel = (hover - pos) * 8 - vel * 6
            vel = vel + accel * dt
            pos = pos + vel * dt
            goalDir = (tp - pos).Magnitude > 0.1 and (tp - pos).Unit or Vector3.yAxis
            spinRate = math.min(spinRate + dt * 14, 20)
            if phaseT > 0.9 then phase = "streak"; phaseT = 0; diveT = 0; vel = Vector3.zero end
        elseif phase == "streak" then
            diveT = diveT + dt
            local tp = tgtRoot.Position
            local ramp = math.clamp(diveT / 1, 0, 1)
            local harmonic = (1 - math.cos(ramp * math.pi)) * 0.5
            local speed = 35 + (diveSpeed - 35) * harmonic
            local predicted = tp + tgtRoot.AssemblyLinearVelocity * 0.07
            local aimPoint = predicted + Vector3.new(0, 1, 0)
            local toTarget = aimPoint - pos
            local dist = toTarget.Magnitude
            if diveT > 0.15 and dist <= 5 then
                pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", tgtRoot) end)
            end
            if diveT > 0.15 and dist <= 1 then
                pos = aimPoint
                root.CFrame = CFrame.new(pos)
                root.AssemblyLinearVelocity = Vector3.zero
                detonated = true
                meteorBool = false
                conn:Disconnect()
                stopAnim()
                if hum then hum.PlatformStand = false end
                pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", root) end)
                task.defer(function() pcall(CMD.explode, {target = targetName, velocity = 120}) end)
                return
            end
            local dir = toTarget.Magnitude > 0.01 and toTarget.Unit or Vector3.yAxis
            local desiredVel = dir * speed
            local accel = (desiredVel - vel) * (13 + harmonic * 30)
            vel = vel + accel * dt
            pos = pos + vel * dt
            goalDir = vel.Magnitude > 1 and vel.Unit or dir
            spinRate = math.min(spinRate + dt * 6, 26)
            if diveT > 6 then
                detonated = true
                meteorBool = false
                conn:Disconnect()
                stopAnim()
                if hum then hum.PlatformStand = false end
                pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", root) end)
                return
            end
        end
        spinA = spinA + dt * spinRate
        spinB = spinB + dt * spinRate * 0.6
        root.CFrame = CFrame.new(pos) * CFrame.Angles(spinB, spinA, spinA * 0.4)
        root.AssemblyLinearVelocity = vel
        root.AssemblyAngularVelocity = Vector3.zero
    end)
end

function CMD.missile(data)
    local targetName, liftHeight, diveSpeed = data.target, tonumber(data.liftHeight) or 45, tonumber(data.diveSpeed) or 130
    if not targetName then return end
    missileBool = true; currentAction = "Missile (" .. targetName .. ")"
    local root = getRoot()
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum then missileBool = false; return end
    pcall(function()
        if sethiddenproperty then
            sethiddenproperty(Players.LocalPlayer, "MaximumSimulationRadius", math.huge)
            sethiddenproperty(Players.LocalPlayer, "SimulationRadius", math.huge)
        end
    end)
    local missileTrack
    pcall(function()
        local anim = Instance.new("Animation")
        anim.AnimationId = "rbxassetid://116732690818367"
        local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
        missileTrack = animator:LoadAnimation(anim)
        missileTrack.Priority = Enum.AnimationPriority.Action4
        missileTrack:Play(0, 1, 1)
        task.defer(function()
            if missileTrack then
                missileTrack.TimePosition = 0.1
                missileTrack:AdjustSpeed(0)
            end
        end)
    end)
    local pos = root.Position
    local vel = Vector3.zero
    local launchPos = pos
    local launchY = pos.Y
    local phase = "lift"
    local phaseT = 0
    local roamAng = math.random() * math.pi * 2
    local roamDir = math.random(0, 1) == 0 and 1 or -1
    local roamRadius = 14 + math.random() * 6
    local wob1, wob2, wob3 = math.random()*10, math.random()*10, math.random()*10
    local lockPos = nil
    local diveT = 0
    local bank = 0
    local roll = 0
    local detonated = false
    local initialized = false
    if hum then hum.PlatformStand = true end

    local function detonate()
        if detonated then return end
        detonated = true
        if missileTrack then pcall(function() missileTrack:Stop(0) end) missileTrack = nil end
        missileBool = false
        currentAction = "Idle"
        local r = getRoot()
        local h = hum
        local tgt = findPlayerByName(targetName)
        local tr = tgt and tgt.Character and tgt.Character:FindFirstChild("HumanoidRootPart")
        if r then
            pcall(function()
                for _, v in pairs(r:GetChildren()) do
                    if v:IsA("BodyVelocity") or v:IsA("BodyAngularVelocity") or v:IsA("BodyGyro") then v:Destroy() end
                end
                r.Anchored = false
                r.AssemblyLinearVelocity = Vector3.zero
            end)
        end
        if h then h.PlatformStand = true end
        if r and tr then
            local weldCF = CFrame.new(0, 0, -0.1)
            local weldConn
            weldConn = RunService.Heartbeat:Connect(function()
                local rr = getRoot()
                local trr = tgt and tgt.Character and tgt.Character:FindFirstChild("HumanoidRootPart")
                if rr and trr then
                    pcall(function() sethiddenproperty(rr, "PhysicsRepRootPart", trr) end)
                    rr.CFrame = trr.CFrame * weldCF
                    rr.AssemblyLinearVelocity = Vector3.zero
                end
            end)
            task.delay(0.12, function()
                if weldConn then weldConn:Disconnect() end
                local rr = getRoot()
                if rr then pcall(function() sethiddenproperty(rr, "PhysicsRepRootPart", rr) end) end
                if h then h.PlatformStand = false end
                task.defer(function() pcall(CMD.explode, {target = targetName, velocity = 120}) end)
            end)
        else
            local rr = getRoot()
            if rr then pcall(function() sethiddenproperty(rr, "PhysicsRepRootPart", rr) end) end
            if h then h.PlatformStand = false end
            task.defer(function() pcall(CMD.explode, {target = targetName, velocity = 120}) end)
        end
    end

    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not missileBool or not isRunning then
            conn:Disconnect()
            if missileTrack then pcall(function() missileTrack:Stop(0) end) missileTrack = nil end
            local r = getRoot()
            if r then pcall(function() sethiddenproperty(r, "PhysicsRepRootPart", r) end) end
            if hum then hum.PlatformStand = false end
            return
        end
        local tgt = findPlayerByName(targetName)
        root = getRoot()
        if not tgt or not tgt.Character or not root then return end
        local tgtRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
        local tgtHum = tgt.Character:FindFirstChildOfClass("Humanoid")
        if not tgtRoot or not tgtHum or tgtHum.Health <= 0 then
            conn:Disconnect()
            if missileTrack then pcall(function() missileTrack:Stop(0) end) missileTrack = nil end
            missileBool = false
            local r = getRoot()
            if r then pcall(function() sethiddenproperty(r, "PhysicsRepRootPart", r) end) end
            if hum then hum.PlatformStand = false end
            return
        end
        if not initialized then
            initialized = true
            pcall(function()
                for _, v in pairs(root:GetChildren()) do
                    if v:IsA("BodyVelocity") or v:IsA("BodyAngularVelocity") or v:IsA("BodyGyro") then v:Destroy() end
                end
                root.Anchored = false
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end)
            pos = root.Position
            launchPos = pos
            launchY = pos.Y
        end
        pcall(function() root.Anchored = false end)
        if hum and hum:GetState() ~= Enum.HumanoidStateType.Physics then
            hum:ChangeState(Enum.HumanoidStateType.Physics)
        end
        if hum then hum.PlatformStand = true end
        if missileTrack and not missileTrack.IsPlaying then
            pcall(function()
                missileTrack:Play(0, 1, 1)
                missileTrack.TimePosition = 0.1
                missileTrack:AdjustSpeed(0)
            end)
        end
        dt = math.min(dt, 1/30)
        phaseT = phaseT + dt
        wob1 = wob1 + dt * 2.1; wob2 = wob2 + dt * 3.3; wob3 = wob3 + dt * 1.6
        local goalDir = Vector3.yAxis
        local spinRoll = false
        if phase == "lift" then
            spinRoll = true
            local climbDur = 1.9
            local alpha = math.clamp(phaseT / climbDur, 0, 1)
            local ease = alpha * alpha * (3 - 2 * alpha)
            local newY = launchY + liftHeight * ease + math.sin(alpha * math.pi) * 3.5
            local newPos = Vector3.new(launchPos.X, newY, launchPos.Z)
            vel = (newPos - pos) / math.max(dt, 0.001)
            pos = newPos
            goalDir = Vector3.yAxis
            if alpha >= 1 then phase = "roam"; phaseT = 0 end
        elseif phase == "roam" then
            local tp = tgtRoot.Position
            roamAng = roamAng + dt * (1.3 + math.sin(wob3) * 0.3) * roamDir
            local desiredRadius = 14 + math.sin(wob1 * 0.7) * 3 + math.cos(wob2 * 0.5) * 2
            roamRadius = roamRadius + (desiredRadius - roamRadius) * math.min(1, dt * 2)
            local bobH = liftHeight + math.sin(wob2) * 4 + math.sin(wob3 * 0.6) * 2
            local hover = tp + Vector3.new(math.cos(roamAng) * roamRadius, bobH, math.sin(roamAng) * roamRadius)
            local accel = (hover - pos) * 15 - vel * 7.5
            vel = vel + accel * dt
            pos = pos + vel * dt
            goalDir = vel.Magnitude > 1 and vel.Unit or Vector3.yAxis
            if phaseT > 3.4 then phase = "lock"; phaseT = 0; lockPos = pos end
        elseif phase == "lock" then
            local tp = tgtRoot.Position
            local intensity = math.min(phaseT * 1.6, 2.2)
            local shake = Vector3.new(math.sin(wob1 * 9), math.sin(wob2 * 12), math.cos(wob1 * 10)) * intensity
            local toT = tp - lockPos
            local pull = toT.Magnitude > 0.1 and toT.Unit * intensity * 2.5 or Vector3.zero
            local goal = lockPos + shake + pull
            local accel = (goal - pos) * 32 - vel * 11
            vel = vel + accel * dt
            pos = pos + vel * dt
            local gd = tp - pos
            goalDir = gd.Magnitude > 0.1 and gd.Unit or Vector3.yAxis
            if (phaseT > 1.1 and (tp - pos).Magnitude > 8) or phaseT > 2.2 then
                phase = "dive"; phaseT = 0; diveT = 0
            end
        elseif phase == "dive" then
            diveT = diveT + dt
            local tp = tgtRoot.Position
            local ramp = math.clamp(diveT / 1.2, 0, 1)
            local harmonic = (1 - math.cos(ramp * math.pi)) * 0.5
            local speed = 22 + (diveSpeed - 22) * harmonic
            local predicted = tp + tgtRoot.AssemblyLinearVelocity * 0.08
            local aimPoint = predicted + Vector3.new(0, 1, 0)
            local toTarget = aimPoint - pos
            local dist = toTarget.Magnitude
            if diveT > 0.2 and dist <= 5 then
                pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", tgtRoot) end)
            end
            if diveT > 0.2 and dist <= 1 then
                pos = aimPoint
                root.CFrame = CFrame.new(pos)
                root.AssemblyLinearVelocity = Vector3.zero
                detonate()
                return
            end
            local dir = toTarget.Magnitude > 0.01 and toTarget.Unit or Vector3.yAxis
            local desiredVel = dir * speed
            local accel = (desiredVel - vel) * (11 + harmonic * 26)
            vel = vel + accel * dt
            pos = pos + vel * dt
            goalDir = vel.Magnitude > 1 and vel.Unit or dir
            if diveT > 6 then detonate() return end
        end
        local lookTarget = (phase == "lift") and (pos + Vector3.new(math.sin(wob1) * 0.2, 1, math.cos(wob1) * 0.2)) or (pos + goalDir)
        if (lookTarget - pos).Magnitude < 0.05 then lookTarget = pos + Vector3.new(0, 0, -1) end
        local flatVel = Vector3.new(vel.X, 0, vel.Z)
        local targetBank = 0
        if flatVel.Magnitude > 2 and goalDir.Magnitude > 0.1 then
            local right = goalDir:Cross(Vector3.yAxis)
            if right.Magnitude > 0.05 then
                targetBank = math.clamp(-vel.Unit:Dot(right.Unit) * 0.7, -0.7, 0.7)
            end
        end
        bank = bank + (targetBank - bank) * math.min(1, dt * 5)
        if spinRoll then roll = roll + dt * 8 else roll = roll + (0 - roll) * math.min(1, dt * 4) end
        root.CFrame = CFrame.new(pos, lookTarget) * CFrame.Angles(math.rad(90), roll, bank)
        root.AssemblyLinearVelocity = vel
        root.AssemblyAngularVelocity = Vector3.zero
    end)
end

local SHOWCASE_PATTERNS = {
    "Orbit", "Zigzag", "Wave", "Figure8", "Spiral",
    "Bounce", "Drift", "Starburst", "Triangle", "Pendulum"
}

function CMD.showcase(data)
    local targetName = data.target
    local radius = data.radius or 22
    local speed = (data.speed or 20) * math.pi / 180
    local heightOffset = data.height or 0
    local followSpeed = tonumber(data.followSpeed) or 3
    if not targetName then return end
    showcaseBool = true; currentAction = "Showcase (" .. targetName .. ")"
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = getRoot()
    if not root or not hum then showcaseBool = false; return end
    hum.PlatformStand = true
    local total, myIdx
    if data.totalOnline and data.onlineIds and #data.onlineIds > 0 then
        total = data.totalOnline
        for i, id in ipairs(data.onlineIds) do
            if id == MY_ID then myIdx = i; break end
        end
        myIdx = myIdx or 1
    else
        if #botList > 0 then
            total = #botList; myIdx = botIndex or 1
        elseif totalAlts > 0 then
            total = totalAlts; myIdx = botNumber or 1
        else
            total = 1; myIdx = 1
        end
    end
    total = math.max(total, 1)
    myIdx = math.max(myIdx, 1)
    local autoSpacing = 2 * math.pi / total
    local angleOffset = (myIdx - 1) * autoSpacing
    local tgt = total > 1
    local altRadius = radius * (0.35 + 0.65 * (tgt and math.sqrt((myIdx - 1) / (total - 1)) or 0))
    local altYBase = heightOffset + (tgt and math.sin((myIdx - 1) * 1.7) * 5 or 0)
    local wob1, wob2 = math.random()*10, math.random()*10
    local pos = root.Position
    local accumulatedTime = 0
    local PATTERN_DURATION = 4
    local TOTAL_PATTERNS = #SHOWCASE_PATTERNS
    local SHOWCASE_DURATION = PATTERN_DURATION * TOTAL_PATTERNS
    local SMILEY_DURATION = 8
    local TOTAL_DURATION = SHOWCASE_DURATION + SMILEY_DURATION
    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not showcaseBool or not isRunning then
            conn:Disconnect()
            local r = getRoot()
            if r then pcall(function() sethiddenproperty(r, "PhysicsRepRootPart", r) end) end
            if hum then hum.PlatformStand = false end
            return
        end
        local tgt = findPlayerByName(targetName)
        root = getRoot()
        if not tgt or not tgt.Character or not root then return end
        local tgtRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
        local tgtHum = tgt.Character:FindFirstChildOfClass("Humanoid")
        if not tgtRoot or not tgtHum or tgtHum.Health <= 0 then return end
        dt = math.min(dt, 1 / 30)
        accumulatedTime = accumulatedTime + dt
        local t = accumulatedTime
        local tp = tgtRoot.Position
        local xOff, yOff, zOff
        if t < SHOWCASE_DURATION then
            wob1 = wob1 + dt * 0.5; wob2 = wob2 + dt * 0.7
            local patternIdx = (math.floor(t / PATTERN_DURATION) % TOTAL_PATTERNS) + 1
            local pattern = SHOWCASE_PATTERNS[patternIdx]
            local angle = (t * speed + angleOffset)
            local dist = altRadius
            xOff, yOff, zOff = 0, altYBase, 0
            if pattern == "Orbit" then
                local a = angle % (2 * math.pi)
                xOff = math.cos(a) * dist; zOff = math.sin(a) * dist
                yOff = altYBase + math.sin(t * 1.5) * 2
            elseif pattern == "Zigzag" then
                local a = (t * speed * 0.3) % (2 * math.pi)
                local zig = math.sin(t * 3 + wob1) * dist * 0.6
                xOff = math.cos(a) * dist * 0.5 + zig * math.cos(a + 1.57)
                zOff = math.sin(a) * dist * 0.5 + zig * math.sin(a + 1.57)
                yOff = altYBase + math.sin(t * 2) * 3
            elseif pattern == "Wave" then
                local a = (t * speed * 0.5) % (2 * math.pi)
                local wave = math.sin(t * 2.5 + wob1) * dist * 0.5
                xOff = (dist + wave) * math.cos(a); zOff = (dist + wave) * math.sin(a)
                yOff = altYBase + math.sin(t * 2 + wob2) * 4
            elseif pattern == "Figure8" then
                local a = t * speed * 0.6
                local s = math.sin(a) * dist * 0.5
                local c = math.sin(a * 0.5) * dist * 0.7
                local dir = math.cos(a * 0.5) > 0 and 1 or -1
                xOff = c * math.cos(angle) - s * dir * math.sin(angle)
                zOff = c * math.sin(angle) + s * dir * math.cos(angle)
                yOff = altYBase + math.sin(t * 1.5) * 2
            elseif pattern == "Spiral" then
                local a = t * speed * 0.8
                local spiralR = dist * (0.3 + 0.7 * (1 + math.sin(t * 0.5)) * 0.5)
                xOff = math.cos(a) * spiralR; zOff = math.sin(a) * spiralR
                yOff = altYBase + math.sin(t * 1.2) * 3
            elseif pattern == "Bounce" then
                local a = (t * speed * 0.4) % (2 * math.pi)
                local bounce = math.abs(math.sin(t * 3)) * dist * 0.4
                xOff = math.cos(a) * dist * 0.8; zOff = math.sin(a) * dist * 0.8
                yOff = altYBase + bounce + math.sin(t * 0.5) * 2
            elseif pattern == "Drift" then
                local a1 = t * 0.5 + wob1; local a2 = t * 0.7 + wob2
                xOff = math.sin(a1) * dist * 0.6 + math.sin(t * 1.3) * 4
                zOff = math.cos(a2) * dist * 0.6 + math.cos(t * 0.9) * 4
                yOff = altYBase + math.sin(t * 0.6) * 3
            elseif pattern == "Starburst" then
                local a = (t * speed * 0.3) % (2 * math.pi)
                local pulse = 0.4 + 0.6 * (1 + math.sin(t * 2.5)) * 0.5
                xOff = math.cos(a) * dist * pulse; zOff = math.sin(a) * dist * pulse
                yOff = altYBase + math.sin(t * 0.5) * 5
            elseif pattern == "Triangle" then
                local a = t * speed * 0.4
                local tri = (a % (2 * math.pi)) / (2 * math.pi) * 3
                local corner = math.floor(tri)
                local localT = tri - corner
                local c1 = {math.cos(corner * 2.094 + angleOffset), math.sin(corner * 2.094 + angleOffset)}
                local c2 = {math.cos((corner + 1) * 2.094 + angleOffset), math.sin((corner + 1) * 2.094 + angleOffset)}
                xOff = (c1[1] * (1 - localT) + c2[1] * localT) * dist
                zOff = (c1[2] * (1 - localT) + c2[2] * localT) * dist
                yOff = altYBase + math.sin(t * 2) * 2
            elseif pattern == "Pendulum" then
                local swing = math.sin(t * 1.5 + wob1) * dist * 0.8
                local a = (t * 0.3 + angleOffset) % (2 * math.pi)
                xOff = math.cos(a) * dist * 0.3 + swing * math.cos(a + 1.57)
                zOff = math.sin(a) * dist * 0.3 + swing * math.sin(a + 1.57)
                yOff = altYBase + math.sin(t * 1.2) * 3
            end
            if patternIdx ~= math.floor((t - dt) / PATTERN_DURATION) % TOTAL_PATTERNS + 1 then
                currentAction = "Showcase (" .. targetName .. ") [" .. pattern .. "]"
            end
        elseif t < TOTAL_DURATION then
            -- Smiley face formation (supports any num alts)
            currentAction = "Showcase (" .. targetName .. ") [:) Smiley!]"
            local perEye = math.max(1, math.floor(total / 5))
            local eyeR = 1.5
            local smileyT = (t - SHOWCASE_DURATION) / SMILEY_DURATION
            local ease = smileyT < 0.5 and 2 * smileyT * smileyT or 1 - (-2 * smileyT + 2) * (-2 * smileyT + 2) / 2
            local arrived = smileyT > 0.5
            if myIdx <= perEye then
                -- Left eye circle
                local a = (myIdx - 1) / perEye * math.pi * 2
                xOff = -4 + math.cos(a) * eyeR
                zOff = math.sin(a) * eyeR
                yOff = 8
            elseif myIdx <= perEye * 2 then
                -- Right eye circle
                local a = (myIdx - perEye - 1) / perEye * math.pi * 2
                xOff = 4 + math.cos(a) * eyeR
                zOff = math.sin(a) * eyeR
                yOff = 8
            else
                -- Smile arc
                local smileAlts = total - perEye * 2
                local smileIdx = myIdx - perEye * 2
                local smileStart, smileEnd = 200, 340
                local smileAngle = (smileStart + (smileIdx - 1) * (smileEnd - smileStart) / math.max(smileAlts - 1, 1)) * math.pi / 180
                local smileR = 5.5
                xOff = math.cos(smileAngle) * smileR
                zOff = 0
                yOff = 3 + math.sin(smileAngle) * smileR
            end
            xOff = xOff * (arrived and 1 or ease)
            yOff = yOff * (arrived and 1 or ease)
            zOff = zOff * (arrived and 1 or ease)
            if not arrived then
                xOff = xOff + math.sin(t * 6 + angleOffset) * 2 * (1 - ease)
                yOff = yOff + math.cos(t * 5 + wob1) * 2 * (1 - ease)
                zOff = zOff + math.sin(t * 7 + wob2) * 2 * (1 - ease)
            end
            yOff = yOff + heightOffset
        else
            -- Finished: stop
            showcaseBool = false
            return
        end
        local targetPos = tp + Vector3.new(xOff, yOff, zOff)
        local lerpFactor = math.min(1, dt * followSpeed)
        pos = pos + (targetPos - pos) * lerpFactor
        root.CFrame = CFrame.lookAt(pos, tp + Vector3.new(0, 1, 0))
        root.Velocity = Vector3.zero
        pcall(function() root.AssemblyLinearVelocity = Vector3.zero end)
    end)
end

function CMD.platform(data)
    local targetName = data.ownerName or (data.target and type(data.target) == "string" and data.target)
    if not targetName then return end
    platformBool = true; platformMaxY = nil; currentAction = "Platform Alt"
    -- Freeze: no animations, stand straight
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum.PlatformStand = true; hum.AutoRotate = false
        local animator = hum:FindFirstChildOfClass("Animator")
        if animator then for _, t in pairs(animator:GetPlayingAnimationTracks()) do t:Stop() end end
    end
    -- Enable collision + zero all velocities so alt is a solid, still platform
    if char then
        for _, v in pairs(char:GetDescendants()) do
            if v:IsA("BasePart") then
                v.CanCollide = true; v.Velocity = Vector3.zero; v.RotVelocity = Vector3.zero
            end
        end
    end
    -- Init max Y from current target position, start low so rescue lifts player up
    local tgt = findPlayerByName(targetName)
    local tgtRoot = tgt and tgt.Character and tgt.Character:FindFirstChild("HumanoidRootPart")
    if tgtRoot and not platformMaxY then
        platformMaxY = tgtRoot.Position.Y - 8
        rescueActive = true
        rescueTargetY = tgtRoot.Position.Y + 10
        rescueLastT = nil
    end
    -- Grid position offset
    local total = data.total or 1
    local idx = data.idx or 1
    local cols = math.max(1, math.ceil(math.sqrt(total)))
    local rows = math.max(1, math.ceil(total / cols))
    local col = (idx - 1) % cols
    local row = math.floor((idx - 1) / cols)
    local spacing = 3
    local xOff = (col - (cols - 1) / 2) * spacing
    local zOff = (row - (rows - 1) / 2) * spacing
    -- Movement prediction state (configurable via Prediction param, default 0.25)
    local predMul = tonumber(data.prediction) or 0.25
    local predLastX, predLastZ, predLastT
    local predVx, predVz = 0, 0
    local rescueActive, rescueTargetY, rescueLastT = false, nil, nil
    if platformConn then platformConn:Disconnect() end
    platformConn = RunService.Heartbeat:Connect(function()
        if not platformBool or not isRunning then
            if platformConn then platformConn:Disconnect(); platformConn = nil end
            return
        end
        local tgt = findPlayerByName(targetName)
        local root = getRoot()
        if tgt and tgt.Character and root then
            local tgtRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
            if tgtRoot then
                if tgtRoot.Position.Y > platformMaxY then platformMaxY = tgtRoot.Position.Y end
                -- Movement prediction: track velocity, predict ahead
                local now = tick()
                if predLastT then
                    local dt = now - predLastT
                    if dt > 0 and dt < 0.5 then
                        predVx = (tgtRoot.Position.X - predLastX) / dt * predMul
                        predVz = (tgtRoot.Position.Z - predLastZ) / dt * predMul
                    end
                end
                predLastX, predLastZ, predLastT = tgtRoot.Position.X, tgtRoot.Position.Z, now
                -- Rescue: detect fall, drop alts under player, lift back up
                if not rescueActive then
                    if tgtRoot.Position.Y < platformMaxY - 9 then
                        rescueActive = true
                        rescueTargetY = tgtRoot.Position.Y + 10
                        platformMaxY = tgtRoot.Position.Y
                        rescueLastT = nil
                    end
                else
                    local rescueNow = tick()
                    local rescueDt = rescueLastT and (rescueNow - rescueLastT) or 0.016
                    rescueLastT = rescueNow
                    platformMaxY = platformMaxY + 3 * math.min(rescueDt, 0.1)
                    if platformMaxY >= rescueTargetY then
                        platformMaxY = rescueTargetY
                        rescueActive = false
                    end
                end
                -- Shift grid forward in movement direction so alts stay ahead
                local moveSpeed = math.sqrt(predVx * predVx + predVz * predVz)
                local fwdShiftX, fwdShiftZ = 0, 0
                if moveSpeed > 0.5 then
                    local mdx, mdz = predVx / moveSpeed, predVz / moveSpeed
                    fwdShiftX, fwdShiftZ = mdx * 6, mdz * 6
                end
                local desiredPos = Vector3.new(tgtRoot.Position.X + xOff + predVx + fwdShiftX, platformMaxY - 6, tgtRoot.Position.Z + zOff + predVz + fwdShiftZ)
                root.CFrame = CFrame.lookAt(desiredPos, desiredPos - Vector3.new(0, 1, 0))
                root.Velocity = Vector3.zero
                pcall(function() root.AssemblyLinearVelocity = Vector3.zero end)
                if char then
                    for _, v in pairs(char:GetDescendants()) do
                        if v:IsA("BasePart") and v ~= root then v.Velocity = Vector3.zero; v.RotVelocity = Vector3.zero end
                    end
                end
            end
        end
    end)
end

function CMD.orbit(data)
    local targetName = data.target
    local radius = data.radius or 15
    local speed = (data.speed or 45) * math.pi / 180
    local heightOffset = data.height or 0
    local userSpacing = data.spacing and tonumber(data.spacing)
    local selfSpin = (data.spin or 0) * 2 * math.pi / 60
    local wobble = data.wobble or 0
    if not targetName then return end
    orbitBool = true; currentAction = "Orbit (" .. targetName .. ")"
    -- Dynamic spacing: owner-provided count (cross-server) or local botList
    local total, myIdx, _, angleOffset
    if data.totalOnline and data.onlineIds and #data.onlineIds > 0 then
        total = data.totalOnline
        for i, id in ipairs(data.onlineIds) do
            if id == MY_ID then myIdx = i; break end
        end
        myIdx = myIdx or 1
    else
        if #botList > 0 then
            total = #botList; myIdx = botIndex or 1
        elseif totalAlts > 0 then
            total = totalAlts; myIdx = botNumber or 1
        else
            total = 1; myIdx = 1
        end
    end
    total = math.max(total, 1)
    myIdx = math.max(myIdx, 1)
    local autoSpacing = 2 * math.pi / total
    angleOffset = (myIdx - 1) * (userSpacing or autoSpacing)
    -- Diagnostic: write computed spacing values to CatBase
    task.spawn(function()
        catbasePut("/" .. SESSION_KEY .. "/orbit_diag/" .. MY_ID .. ".json", {
            myIdx = myIdx, total = total, angleOffset = angleOffset,
            userSpacing = userSpacing, autoSpacing = autoSpacing,
            botNumber = botNumber, botIndex = botIndex, totalAlts = totalAlts,
            botListCount = #botList, target = targetName
        })
    end)
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum.PlatformStand = true end
    -- Use accumulated dt instead of tick() so all alts start at same phase
    local accumulatedTime = 0
    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not orbitBool or not isRunning then
            conn:Disconnect()
            local r = getRoot()
            if r then pcall(function() sethiddenproperty(r, "PhysicsRepRootPart", r) end) end
            if hum then hum.PlatformStand = false end
            return
        end
        local tgt = findPlayerByName(targetName)
        local root = getRoot()
        if not tgt or not tgt.Character or not root then return end
        local tgtRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
        local tgtHum = tgt.Character:FindFirstChildOfClass("Humanoid")
        if not tgtRoot or not tgtHum or tgtHum.Health <= 0 then return end
        dt = math.min(dt, 1 / 30)
        accumulatedTime = accumulatedTime + dt
        local angle = (accumulatedTime * speed + angleOffset) % (math.pi * 2)
        local yOff = heightOffset + wobble * math.sin(accumulatedTime * 2 + angle)
        local pos = tgtRoot.Position + Vector3.new(radius * math.cos(angle), yOff, radius * math.sin(angle))
        pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", tgtRoot) end)
        local lookDir = tgtRoot.Position - pos
        if lookDir.Magnitude > 0.01 then
            local cf = CFrame.lookAt(pos, tgtRoot.Position)
            if selfSpin > 0 then
                cf = cf * CFrame.Angles(0, accumulatedTime * selfSpin, 0)
            end
            root.CFrame = cf
        end
        local tangentDir = Vector3.new(-math.sin(angle), 0, math.cos(angle))
        local vel = tangentDir * math.min(radius * speed, 200)
        root.Velocity = vel
        pcall(function() root.AssemblyLinearVelocity = vel end)
    end)
end

function CMD.orbitfling(data)
    local targetName = data.target
    local radius = data.radius or 15
    local innerRadius = tonumber(data.innerRadius) or 8
    local speed = (data.speed or 45) * math.pi / 180
    local heightOffset = data.height or 0
    local userSpacing = data.spacing and tonumber(data.spacing)
    local selfSpin = (data.spin or 0) * 2 * math.pi / 60
    local wobble = data.wobble or 0
    if not targetName then return end
    flingOrbitBool = true; currentAction = "Orbit Fling (" .. targetName .. ")"
    local total, myIdx, _, angleOffset
    if data.totalOnline and data.onlineIds and #data.onlineIds > 0 then
        total = data.totalOnline
        for i, id in ipairs(data.onlineIds) do
            if id == MY_ID then myIdx = i; break end
        end
        myIdx = myIdx or 1
    else
        if #botList > 0 then
            total = #botList; myIdx = botIndex or 1
        elseif totalAlts > 0 then
            total = totalAlts; myIdx = botNumber or 1
        else
            total = 1; myIdx = 1
        end
    end
    total = math.max(total, 1)
    myIdx = math.max(myIdx, 1)
    local autoSpacing = 2 * math.pi / total
    angleOffset = (myIdx - 1) * (userSpacing or autoSpacing)
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum.PlatformStand = true end
    local accumulatedTime = 0
    local flingCD = {}
    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not isRunning then
            conn:Disconnect()
            if hum then hum.PlatformStand = false end
            return
        end
        if not flingOrbitBool then return end
        local tgt = findPlayerByName(targetName)
        local root = getRoot()
        if not tgt or not tgt.Character or not root then return end
        local tgtRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
        local tgtHum = tgt.Character:FindFirstChildOfClass("Humanoid")
        if not tgtRoot or not tgtHum or tgtHum.Health <= 0 then return end
        dt = math.min(dt, 1 / 30)
        accumulatedTime = accumulatedTime + dt
        local angle = (accumulatedTime * speed + angleOffset) % (math.pi * 2)
        local yOff = heightOffset + wobble * math.sin(accumulatedTime * 2 + angle)
        local pos = tgtRoot.Position + Vector3.new(radius * math.cos(angle), yOff, radius * math.sin(angle))
        local lookDir = tgtRoot.Position - pos
        if lookDir.Magnitude > 0.01 then
            local cf = CFrame.lookAt(pos, tgtRoot.Position)
            if selfSpin > 0 then cf = cf * CFrame.Angles(0, accumulatedTime * selfSpin, 0) end
            root.CFrame = cf
        end
        root.Velocity = Vector3.zero
        pcall(function() root.AssemblyLinearVelocity = Vector3.zero end)
        -- Fling anyone who enters the inner radius (except owner and orbit target)
        local now = tick()
        local altIds = data.onlineIds or {}
        local altSet = {}
        for _, id in ipairs(altIds) do altSet[id] = true end
        altSet[MY_ID] = true
        for _, plr in pairs(game.Players:GetPlayers()) do
            if plr.Character and plr.Name ~= targetName and (not OWNER_NAME or plr.Name ~= OWNER_NAME) and not altSet[tostring(plr.UserId)] then
                local pr = plr.Character:FindFirstChild("HumanoidRootPart")
                if pr then
                    local dist = (pr.Position - tgtRoot.Position).Magnitude
                    if dist < innerRadius then
                        local last = flingCD[plr.UserId]
                        if not last or now - last > 2 then
                            flingCD[plr.UserId] = now
                            task.spawn(function()
                                flingOrbitBool = false
                                pcall(CMD.fling, {target = plr.Name})
                                task.wait(1)
                                walkflingBool = false
                                pcall(execIYCommand, "unwalkfling")
                                if isRunning and not flingOrbitBool then
                                    flingOrbitBool = true
                                    currentAction = "Orbit Fling (" .. targetName .. ")"
                                end
                            end)
                        end
                    end
                end
            end
        end
    end)
end

function CMD.test_sync(data)
    local rounds = tonumber(data.rounds) or 5
    local interval = tonumber(data.interval) or 2
    local ownerPos = data.ownerPos
    local char = getChar()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = getRoot()
    if not root or not hum then return end
    local total, myIdx
    if data.totalOnline and data.onlineIds and #data.onlineIds > 0 then
        total = data.totalOnline
        for i, id in ipairs(data.onlineIds) do
            if id == MY_ID then myIdx = i; break end
        end
        myIdx = myIdx or 1
    else
        if #botList > 0 then
            total = #botList; myIdx = botIndex or 1
        elseif totalAlts > 0 then
            total = totalAlts; myIdx = botNumber or 1
        else
            total = 1; myIdx = 1
        end
    end
    total = math.max(total, 1)
    myIdx = math.max(myIdx, 1)
    if ownerPos then
        local lineSpacing = 8
        local xOff = (myIdx - 1 - (total - 1) / 2) * lineSpacing
        root.CFrame = CFrame.new(Vector3.new(ownerPos[1] + xOff, ownerPos[2], ownerPos[3]))
        pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", root) end)
    end
    task.wait(0.5)
    local results = {}
    for r = 1, rounds do
        task.wait(interval)
        local jumpTick = tick()
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
        root.Velocity = Vector3.new(0, 50, 0)
        table.insert(results, {round = r, tick = jumpTick})
    end
    local resultPath = "/" .. SESSION_KEY .. "/sync_results/" .. MY_ID .. ".json"
    catbasePut(resultPath, {altId = MY_ID, botNumber = botNumber, botIndex = botIndex, results = results})
end

function CMD.fling(data)
    local targetName = data.target
    if not targetName or targetName == "" then return end
    walkflingBool = true; currentAction = "Fling: " .. targetName
    -- Save original position to return to when fling finishes
    local originalPos = getPos()
    local originalRoot = getRoot()
    -- Enable IY walkfling so alt clips inside the target
    CMD.iycmd({command = "walkfling"})
    -- 1:1 sync inside target with jitter
    local tgtInitialPos = nil
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not walkflingBool or not isRunning then
            conn:Disconnect(); walkflingConn = nil
            local r = getRoot()
            if r then pcall(function() sethiddenproperty(r, "PhysicsRepRootPart", r) end) end
            return
        end
        local tgt = findPlayerByName(targetName)
        local root = getRoot()
        if tgt and tgt.Character and root then
            local tgtRoot = tgt.Character:FindFirstChild("HumanoidRootPart")
            local tgtHum = tgt.Character:FindFirstChild("Humanoid")
            if tgtRoot and tgtHum and tgtHum.Health > 0 then
                if not tgtInitialPos then tgtInitialPos = tgtRoot.Position end
                -- Detect if target was flung (moved far from initial position)
                if (tgtRoot.Position - tgtInitialPos).Magnitude > 50 then
                    walkflingBool = false; conn:Disconnect(); walkflingConn = nil
                    if originalRoot then
                        pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", root) end)
                        root.CFrame = CFrame.new(originalPos)
                        root.Velocity = Vector3.zero
                    end
                    currentAction = "Fling done (flung)"
                    return
                end
                pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", tgtRoot) end)
                root.CFrame = tgtRoot.CFrame * CFrame.Angles(math.rad(90), 0, 0)
                root.Velocity = Vector3.new(math.random(-500, 500), math.random(-300, 800), math.random(-500, 500))
                root.AngularVelocity = Vector3.new(math.random(-500, 500), math.random(-500, 500), math.random(-500, 500))
            else
                walkflingBool = false; conn:Disconnect(); walkflingConn = nil
                if root then
                    pcall(function() sethiddenproperty(root, "PhysicsRepRootPart", root) end)
                    root.CFrame = CFrame.new(originalPos)
                    root.Velocity = Vector3.zero
                end
                currentAction = "Fling done (target dead)"
            end
        end
    end)
    walkflingConn = conn
end

local function addChamForChar(char)
    if not char then return end
    local hl = Instance.new("Highlight")
    hl.Name = "CatAlt_FlingCham"
    hl.Adornee = char
    hl.FillColor = Color3.fromRGB(255, 50, 50)
    hl.FillTransparency = 0.5
    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = char
    table.insert(flingChams, hl)
end

local function enableChams()
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then
            addChamForChar(plr.Character)
        end
    end
    if not flingPlayerAdded then
        flingPlayerAdded = Players.PlayerAdded:Connect(function(plr)
            plr.CharacterAdded:Connect(function(char)
                if not flingMode then return end
                task.wait(0.5)
                addChamForChar(char)
            end)
        end)
    end
end

local function disableChams()
    for _, hl in ipairs(flingChams) do
        pcall(function() hl:Destroy() end)
    end
    flingChams = {}
end

local function toggleFlingMode()
    flingMode = not flingMode
    if flingMode then
        enableChams()
        if not flingConnection then
            local mbDebounce = false
            flingConnection = RunService.RenderStepped:Connect(function()
                if not flingMode then return end
                if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton3) and not mbDebounce then
                    mbDebounce = true
                    local cam = game.Workspace.CurrentCamera
                    if cam then
                        local mPos = UserInputService:GetMouseLocation()
                        local unitRay = cam:ViewportPointToRay(mPos.X, mPos.Y)
                        local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * 1000)
                        if result and result.Instance then
                            local plr = findPlayerByPart(result.Instance)
                            if plr then
                                local targetName = plr.Name
                                for id, checked in pairs(UI.Checked) do
                                    if checked then pushCommand(id, {type = "fling", data = {target = targetName}}) end
                                end
                            end
                        end
                    end
                    task.spawn(function() task.wait(0.3) mbDebounce = false end)
                end
            end)
        end
        currentAction = "Fling Mode: ON"
    else
        disableChams()
        if flingConnection then
            flingConnection:Disconnect()
            flingConnection = nil
        end
        if flingPlayerAdded then
            flingPlayerAdded:Disconnect()
            flingPlayerAdded = nil
        end
        currentAction = "Fling Mode: OFF"
    end
end

-- Parse IY source to extract command definitions from addcmd() and CMDs[] entries
-- IY uses: addcmd('name',{aliases},function(args,speaker)...)
-- Display info: CMDs[#CMDs+1] = {NAME='fly [speed]', DESC='Toggles fly'}
local function parseIYCommandsFromSource(source)
    local cmdsByName = {} -- name -> {Name, Aliases}
    local cmdsDisplay = {} -- indexed by bare name -> {Desc, ArgHints}

    -- Pass 1: extract from addcmd('name',{aliases},function(...))
    for name, aliasesStr in source:gmatch("addcmd%s*%(%s*'([^']+)'%s*,%s*{(.-)}%s*,%s*function%s*%(") do
        local aliases = {}
        for alias in aliasesStr:gmatch("'([^']+)'") do
            table.insert(aliases, alias)
        end
        cmdsByName[name:lower()] = {Name = name, Aliases = aliases}
    end
    -- Also match double-quoted strings
    for name, aliasesStr in source:gmatch('addcmd%s*%(%s*"([^"]+)"%s*,%s*{(.-)}%s*,%s*function%s*%(') do
        local aliases = {}
        for alias in aliasesStr:gmatch('"([^"]+)"') do
            table.insert(aliases, alias)
        end
        if not cmdsByName[name:lower()] then
            cmdsByName[name:lower()] = {Name = name, Aliases = aliases}
        end
    end

    -- Pass 2: extract display info from CMDs[#CMDs+1] = {NAME='...', DESC='...'}
    for displayName, desc in source:gmatch("CMDs%[#CMDs%s*%+%s*1%]%s*=%s*{.-NAME%s*=%s*'([^']+)'.-DESC%s*=%s*'([^']*)'.-}") do
        -- Extract the bare command name (before any alias / or [bracket)
        local bareName = displayName:match("^([^%[/]+)")
        if bareName then
            bareName = bareName:gsub("%s+$", "")
            local key = bareName:lower()
            if not cmdsDisplay[key] then
                -- Parse argument hints from brackets in displayName
                local argHints = {}
                for hint in displayName:gmatch("%[([^%]]+)%]") do
                    table.insert(argHints, hint)
                end
                cmdsDisplay[key] = {Name = bareName, Description = desc, ArgHints = argHints, DisplayName = displayName}
            end
        end
    end
    -- Also match with double quotes
    for displayName, desc in source:gmatch('CMDs%[#CMDs%s*%+%s*1%]%s*=%s*{.-NAME%s*=%s*"([^"]+)".-DESC%s*=%s*"([^"]*)".-}') do
        local bareName = displayName:match("^([^%[/]+)")
        if bareName then
            bareName = bareName:gsub("%s+$", "")
            local key = bareName:lower()
            if not cmdsDisplay[key] then
                local argHints = {}
                for hint in displayName:gmatch("%[([^%]]+)%]") do
                    table.insert(argHints, hint)
                end
                cmdsDisplay[key] = {Name = bareName, Description = desc, ArgHints = argHints, DisplayName = displayName}
            end
        end
    end

    -- Merge: use addcmd names as authoritative, enrich with display info
    local merged = {}
    local seen = {}
    for key, entry in pairs(cmdsByName) do
        local display = cmdsDisplay[key]
        local args = {}
        if display and #display.ArgHints > 0 then
            for _, hint in ipairs(display.ArgHints) do
                local argType = "string"
                local argName = hint
                if hint:lower() == "player" or hint:lower() == "players" then
                    argType = "player"
                end
                table.insert(args, {Name = argName, Type = argType})
            end
        end
        table.insert(merged, {
            Name = entry.Name,
            Description = (display and display.Description) or "",
            Args = args,
        })
        seen[key] = true
    end
    -- Add display-only entries (not found in addcmd)
    for key, display in pairs(cmdsDisplay) do
        if not seen[key] then
            local args = {}
            for _, hint in ipairs(display.ArgHints) do
                local argType = "string"
                if hint:lower() == "player" or hint:lower() == "players" then argType = "player" end
                table.insert(args, {Name = hint, Type = argType})
            end
            table.insert(merged, {
                Name = display.Name,
                Description = display.Description,
                Args = args,
            })
        end
    end

    return merged
end

-- Fetch IY source from URL and populate IY_ACTIONS table with parsed commands
local function fetchAndPopulateIYCommands()
    if not Owner then return end
    if IY_ACTIONS_INITIALIZED then return end
    task.spawn(function()
        local ok, src = pcall(function() return game:HttpGet(IY_URL) end)
        if not ok or not src or src == "" then
            local ok2, src2 = pcall(function() return game:HttpGetAsync(IY_URL) end)
            if not ok2 or not src2 or src2 == "" then
                warn("[CatAlt] Could not fetch IY source for command list"); return
            end
            src = src2
        end
        local parsed = parseIYCommandsFromSource(src)
        if #parsed == 0 then warn("[CatAlt] No IY commands found in source"); return end
        for _, cmd in ipairs(parsed) do
            local params = {}
            for _, arg in ipairs(cmd.Args) do
                local label = arg.Name:sub(1,1):upper() .. arg.Name:sub(2)
                local autofill = (arg.Type == "player" or arg.Type == "players")
                table.insert(params, {label, arg.Name, "", autofill})
            end
            table.insert(IY_ACTIONS, {
                name = cmd.Name,
                key = "iycmd",
                iyCommand = true,
                iyName = cmd.Name,
                description = cmd.Description or "",
                params = #params > 0 and params or nil,
            })
        end
        table.sort(IY_ACTIONS, function(a, b) return a.name:lower() < b.name:lower() end)
        IY_ACTIONS_INITIALIZED = true
        print("[CatAlt] Parsed " .. #parsed .. " IY commands from source")
        if UI.Rerender then UI.Rerender() end
    end)
end


-- Bridge BindableFunction: captures execCmd ref from getgenv and routes through it.
-- A closure ref retains IY's sandbox environment, so calls always work.
local function createBridge()
    local b = Instance.new("BindableFunction")
    b.Name = "CatAlt_IY_Exec"
    b.Parent = game:GetService("ReplicatedStorage")
    local execCmd_ref
    if type(getgenv) == "function" then
        local ok, g = pcall(getgenv)
        if ok and type(g) == "table" then
            execCmd_ref = g.execCmd
        end
    end
    if not execCmd_ref then execCmd_ref = execCmd end
    b.OnInvoke = function(cmdStr)
        if execCmd_ref then
            pcall(execCmd_ref, cmdStr, LocalPlayer, true)
        end
        return true
    end
    -- Update notification relay BindableFunction with real CatBase push logic
    local notifyBf = game:GetService("ReplicatedStorage"):FindFirstChild("CatAlt_NotifyRelay")
    if notifyBf and notifyBf:IsA("BindableFunction") then
        notifyBf.OnInvoke = function(title, text)
            pcall(function()
                local ok2, q = catbaseGet("/" .. SESSION_KEY .. "/notifq.json")
                local queue = ok2 and type(q) == "table" and q or {}
                table.insert(queue, {title = tostring(title or ""), text = tostring(text or ""), t = os.time(), altId = MY_ID})
                if #queue > 100 then for i = 1, #queue - 100 do table.remove(queue, 1) end end
                catbasePut("/" .. SESSION_KEY .. "/notifq.json", queue)
            end)
            return true
        end
    end
end

function CMD.loadiy(data)
    currentAction = "Loading IY..."
    if _G.CatAlt_IY_Loaded then currentAction = "IY Already Loaded"; return end
    -- Re-injection: BindableFunction exists → IY still running
    local ext = game:GetService("ReplicatedStorage"):FindFirstChild("CatAlt_IY_Exec")
    if ext and ext:IsA("BindableFunction") then
        _G.CatAlt_IY_Loaded = true
        currentAction = "IY Already Loaded"
        return
    end
    task.spawn(function()
        pcall(function()
            if type(getgenv) == "function" then getgenv().IY_LOADED = nil end
            IY_LOADED = nil
        end)
        local NOTIFY_INJECT = [[
do
    local n = notify
    if n then
        notify = function(...)
            local a = {...}; n(...)
            local bf = game:GetService("ReplicatedStorage"):FindFirstChild("CatAlt_NotifyRelay")
            if bf and bf:IsA("BindableFunction") then bf:Invoke(a[1], a[2]) end
        end
    end
end
]]
        local ok, src = pcall(function() return game:HttpGet(IY_URL) end)
        if ok and src and src ~= "" then
            local fn, err = loadstring(src .. "\n" .. NOTIFY_INJECT)
            if fn then
                local notifyBf = Instance.new("BindableFunction")
                notifyBf.Name = "CatAlt_NotifyRelay"
                notifyBf.Parent = game:GetService("ReplicatedStorage")
                notifyBf.OnInvoke = function() return true end
                local ok2 = pcall(fn)
                if ok2 then
                    _G.CatAlt_IY_Loaded = true
                    createBridge()
                    currentAction = "IY Loaded"
                else
                    warn("[CatAlt] IY execute failed"); currentAction = "IY Error"
                end
            else
                warn("[CatAlt] IY compile error:", tostring(err)); currentAction = "IY Compile Error"
            end
        else
            pcall(function()
                if type(getgenv) == "function" then getgenv().IY_LOADED = nil end
                IY_LOADED = nil
            end)
            local ok3, src2 = pcall(function() return game:HttpGetAsync(IY_URL) end)
            if ok3 and src2 and src2 ~= "" then
                local fn, err = loadstring(src2 .. "\n" .. NOTIFY_INJECT)
                if fn then
                    local notifyBf = Instance.new("BindableFunction")
                    notifyBf.Name = "CatAlt_NotifyRelay"
                    notifyBf.Parent = game:GetService("ReplicatedStorage")
                    notifyBf.OnInvoke = function() return true end
                    local ok4 = pcall(fn)
                    if ok4 then
                        _G.CatAlt_IY_Loaded = true
                        createBridge()
                        currentAction = "IY Loaded"
                    else
                        warn("[CatAlt] IY execute error"); currentAction = "IY Error"
                    end
                else
                    warn("[CatAlt] IY compile error:", tostring(err)); currentAction = "IY Compile Error"
                end
            else
                warn("[CatAlt] IY fetch failed"); currentAction = "IY Fetch Failed"
            end
        end
    end)
end

execIYCommand = function(cmdStr)
    if not _G.CatAlt_IY_Loaded then return false end
    local bf = game:GetService("ReplicatedStorage"):FindFirstChild("CatAlt_IY_Exec")
    if bf and bf:IsA("BindableFunction") then
        local ok = pcall(function() bf:Invoke(cmdStr) end)
        return ok
    end
    return false
end

function CMD.iycmd(data)
    local cmd = data.command
    if not cmd or cmd == "" then return end
    if not _G.CatAlt_IY_Loaded then currentAction = "IY Not Loaded"; return end
    currentAction = "IY: " .. cmd
    local ok = execIYCommand(cmd)
    if ok then
        currentAction = "IY OK: " .. cmd
    else
        currentAction = "IY FAIL: " .. cmd
        task.spawn(function()
            pcall(function()
                if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
                    TextChatService.TextChannels.RBXGeneral:SendAsync(";" .. cmd)
                else
                    game.ReplicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(";" .. cmd, "All")
                end
            end)
        end)
    end
end

function CMD.unloadiy(data)
    if not _G.CatAlt_IY_Loaded then currentAction = "No IY Loaded"; return end
    currentAction = "Unloading IY..."
    task.spawn(function()
        pcall(function()
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            if pg then
                for _, v in ipairs(pg:GetChildren()) do
                    if v:IsA("ScreenGui") and (v.Name:lower():find("infinite") or v.Name:lower():find("iy") or v.Name:lower():find("yield")) then
                        v:Destroy()
                    end
                end
            end
            local cg = game:FindFirstChild("CoreGui")
            if cg then
                for _, v in ipairs(cg:GetChildren()) do
                    if v:IsA("ScreenGui") and (v.Name:lower():find("infinite") or v.Name:lower():find("iy") or v.Name:lower():find("yield")) then
                        v:Destroy()
                    end
                end
            end
        end)
        pcall(function()
            for _, v in pairs(getgenv() or _G) do
                if type(v) == "table" and type(v.Name) == "string" and v.Name:lower():find("infinite") then
                    _G[v.Name] = nil
                end
            end
        end)
        pcall(function()
            if _G.InfiniteYield then _G.InfiniteYield = nil end
            if _G.IY then _G.IY = nil end
        end)
        pcall(function()
            local bf = game:GetService("ReplicatedStorage"):FindFirstChild("CatAlt_IY_Exec")
            if bf then bf:Destroy() end
        end)
        _G.CatAlt_IY_Loaded = nil
        currentAction = "Idle"
    end)
end

-- ════════ COMMUNICATION ════════
local function pushCommand(altId, cmd)
    if not cmd.totalOnline and Owner and UI.Alts then
        pcall(function()
            local ids = {}
            for id, st in pairs(UI.Alts) do
                if id ~= MY_ID and (os.time() - (st.lastPing or 0)) <= 10 then
                    table.insert(ids, id)
                end
            end
            table.sort(ids)
            cmd.totalOnline = #ids
            cmd.onlineIds = ids
        end)
    end
    task.spawn(function()
        local path = "/" .. SESSION_KEY .. "/cmds/" .. altId .. ".json"
        local ok, existing = catbaseGet(path)
        if not ok or type(existing) ~= "table" then existing = {} end
        table.insert(existing, cmd)
        catbasePut(path, existing)
    end)
end

local function publishState()
    local root = getRoot()
    if not root then return end
    catbasePut("/" .. SESSION_KEY .. "/alts/" .. MY_ID .. ".json", {
        name = MNAME, pos = {root.Position.X, root.Position.Y, root.Position.Z},
        status = "online", lastPing = os.time(), jobId = game.JobId,
        isOwner = Owner, placeId = game.PlaceId
    })
end

local function pollCommands()
    local path = "/" .. SESSION_KEY .. "/cmds/" .. MY_ID .. ".json"
    local ok, data = catbaseGet(path)
    if not ok or type(data) ~= "table" or #data == 0 then return end
    catbasePut(path, {})
    for _, cmd in ipairs(data) do
        local handler = CMD[cmd.type]
        if handler then
            cmd.data = cmd.data or {}
            cmd.data._altId = MY_ID
            if cmd.totalOnline then cmd.data.totalOnline = cmd.totalOnline; cmd.data.onlineIds = cmd.onlineIds end
            task.spawn(function()
                pcall(handler, cmd.data)
            end)
        end
    end
end

-- ════════ CHAT LISTENER ════════
local function connectChatListener(plr)
    if not plr then return end
    plr.Chatted:Connect(function(message)
        if not botIndex then return end
        if plr.Name ~= OWNER_NAME then return end
        if message:sub(1, #PREFIX) ~= PREFIX then return end
        local cmd = message:sub(#PREFIX + 1)
        local args = cmd:split(" ")
        local commandName = args[1]

        if commandName == "sword" and args[2] then
            pcall(CMD.sword, {target = args[2], distance = tonumber(args[3]) or 5, velocity = tonumber(args[4]) or -50, offset = tonumber(args[5]) or 2})
        end
        if commandName == "explode" and args[2] then
            pcall(CMD.explode, {target = args[2], velocity = tonumber(args[3]) or -50})
        end
        if commandName == "meteor" and args[2] then
            pcall(CMD.meteor, {target = args[2], spawnHeight = tonumber(args[3]) or 90, diveSpeed = tonumber(args[4]) or 150})
        end
        if commandName == "stop" then pcall(CMD.stop) end
        if commandName == "missile" and args[2] then
            pcall(CMD.missile, {target = args[2], liftHeight = tonumber(args[3]) or 45, diveSpeed = tonumber(args[4]) or 130})
        end
        if commandName == "showcase" and args[2] then
            pcall(CMD.showcase, {target = args[2], radius = tonumber(args[3]) or 22, speed = tonumber(args[4]) or 20, height = tonumber(args[5]) or 0, followSpeed = tonumber(args[6]) or 2.5})
        end
        if commandName == "fling" then
            pcall(CMD.fling, {target = args[2]})
        end
        if commandName == "orbit" and args[2] then
            pcall(CMD.orbit, {target = args[2], radius = tonumber(args[3]) or 15, speed = tonumber(args[4]) or 45, height = tonumber(args[5]) or 0, spacing = args[6], spin = tonumber(args[7]) or 0, wobble = tonumber(args[8]) or 0})
        end
        if commandName == "tp" and args[2] and args[3] and args[4] then
            pcall(CMD.tp, {position = {tonumber(args[2]) or 0, tonumber(args[3]) or 0, tonumber(args[4]) or 0}})
        end
        if commandName == "rejoin" then pcall(CMD.rejoin) end
        if commandName == "joinmaster" then pcall(CMD.joinmaster) end
        if commandName == "reload" then pcall(CMD.reload) end
        if commandName == "execute" and args[2] then
            local parts = {}
            for i = 2, #args do table.insert(parts, args[i]) end
            pcall(CMD.execute, {code = table.concat(parts, " ")})
        end
        if commandName == "leave" then pcall(CMD.leave) end
        if commandName == "jump" then pcall(CMD.jump) end
        if commandName == "loadiy" then pcall(CMD.loadiy) end
        if commandName == "unloadiy" then pcall(CMD.unloadiy) end
        if commandName == "iycmd" and args[2] then
            local parts = {}
            for i = 2, #args do table.insert(parts, args[i]) end
            pcall(CMD.iycmd, {command = table.concat(parts, " ")})
        end
    end)
end

-- ════════ UI FRAMEWORK ════════
UI = { Actions = {}, Alts = {}, SelectedAction = 1, Checked = {} }

local ACTIONS = {
    { name = "Sword", key = "sword", params = {{"Target", "target", MNAME, true}, {"Distance", "distance", "5"}, {"Velocity", "velocity", "-50"}, {"Alt Offset", "offset", "2"}} },
    { name = "Explode", key = "explode", params = {{"Target", "target", "", true}, {"Velocity", "velocity", "-50"}} },
    { name = "Meteor", key = "meteor", params = {{"Target Name", "target", "", true}, {"Spawn Height", "spawnHeight", "90"}, {"Dive Speed", "diveSpeed", "150"}} },
    { name = "Missile", key = "missile", params = {{"Target", "target", "", true}, {"Lift Height", "liftHeight", "45"}, {"Dive Speed", "diveSpeed", "130"}} },
    { name = "Showcase", key = "showcase", params = {
        {"Target", "target", "", true},
        {"Radius", "radius", "22"},
        {"Speed (deg/s)", "speed", "20"},
        {"Height", "height", "0"},
        {"Follow Speed", "followSpeed", "2.5"},
    } },
    { name = "Orbit", key = "orbit", params = {
        {"Target", "target", "", true},
        {"Radius", "radius", "15"},
        {"Speed (deg/s)", "speed", "45"},
        {"Height Offset", "height", "0"},
        {"Alt Spacing (deg)", "spacing", ""},
        {"Self Spin (RPM)", "spin", "0"},
        {"Wobble", "wobble", "0"},
    } },
    { name = "Orbit Fling", key = "orbitfling", params = {
        {"Target", "target", "", true},
        {"Radius", "radius", "15"},
        {"Inner Radius", "innerRadius", "8"},
        {"Speed (deg/s)", "speed", "45"},
        {"Height Offset", "height", "0"},
        {"Alt Spacing (deg)", "spacing", ""},
        {"Spin (RPM)", "spin", "0"},
        {"Wobble", "wobble", "0"},
    } },
    { name = "Rejoin", key = "rejoin" },
    { name = "Join Master", key = "joinmaster" },
    { name = "Reload", key = "reload" },
    { name = "Execute", key = "execute", params = {{"Lua Code", "code", "", true}} },
    { name = "Jump", key = "jump" },
    { name = "Leave", key = "leave" },
    { name = "Stop Actions", key = "stop" },
    { name = "Fling", key = "fling", params = {{"Target", "target", "", true}} },
    { name = "Platform", key = "platform", params = {{"Target", "target", MNAME, true}, {"Prediction", "prediction", "0.25"}} },
    { name = "Test Sync", key = "test_sync", params = {{"Rounds", "rounds", "5"}, {"Interval (s)", "interval", "2"}} },
    { name = "Test Notification", key = "test_notif" },
    { name = "IY Command", key = "iycmd", params = {{"Command", "command", "", true}} },
    { name = "Load IY", key = "loadiy" },
    { name = "Unload IY", key = "unloadiy" },
}

local function create(className, props)
    local inst = Instance.new(className)
    for k, v in pairs(props or {}) do inst[k] = v end
    return inst
end

local function makeButton(parent, text, size, pos, bgColor)
    local btn = create("TextButton", {
        Parent = parent, Size = size, Position = pos, Text = text,
        BackgroundColor3 = bgColor or Color3.fromRGB(45, 45, 45),
        TextColor3 = Color3.fromRGB(240, 240, 240), Font = Enum.Font.GothamBold,
        TextSize = 13, AutoButtonColor = false, BorderSizePixel = 0
    })
    create("UICorner", {Parent = btn, CornerRadius = UDim.new(0, 6)})
    btn.MouseEnter:Connect(function() TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(math.min(bgColor.R*255 + 20, 255), math.min(bgColor.G*255 + 20, 255), math.min(bgColor.B*255 + 20, 255))}):Play() end)
    btn.MouseLeave:Connect(function() TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = bgColor}):Play() end)
    return btn
end

local function makeDraggable(topbar, window)
    local dragging, dragInput, dragStart, startPos
    topbar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = window.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    topbar.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement then dragInput = input end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

local function attachAutofill(textBox, parentFrame)
    local suggestionFrame = create("ScrollingFrame", {
        Parent = parentFrame, Size = UDim2.new(1, 0, 0, 80), Position = UDim2.new(0, 0, 1, 2),
        BackgroundColor3 = Color3.fromRGB(30, 30, 30), BorderSizePixel = 0, Visible = false, ZIndex = 10,
        ScrollBarThickness = 3
    })
    create("UIListLayout", {Parent = suggestionFrame, SortOrder = Enum.SortOrder.LayoutOrder})
    create("UICorner", {Parent = suggestionFrame, CornerRadius = UDim.new(0, 4)})
    textBox:GetPropertyChangedSignal("Text"):Connect(function()
        for _, c in pairs(suggestionFrame:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
        local txt = textBox.Text:lower()
        if txt == "" then suggestionFrame.Visible = false return end
        local matches = 0
        for _, p in ipairs(Players:GetPlayers()) do
            if p.Name:lower():find(txt, 1, true) or p.DisplayName:lower():find(txt, 1, true) then
                matches = matches + 1
                local btn = create("TextButton", {
                    Parent = suggestionFrame, Size = UDim2.new(1, 0, 0, 25), BackgroundTransparency = 1,
                    Text = "  " .. p.DisplayName .. " (@" .. p.Name .. ")", TextColor3 = Color3.fromRGB(200, 200, 200),
                    Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 11
                })
                btn.MouseButton1Click:Connect(function()
                    textBox.Text = p.Name
                    suggestionFrame.Visible = false
                end)
            end
        end
        suggestionFrame.Visible = (matches > 0)
        suggestionFrame.CanvasSize = UDim2.new(0, 0, 0, matches * 25)
    end)
    textBox.FocusLost:Connect(function()
        task.delay(0.2, function() suggestionFrame.Visible = false end)
    end)
end

local function notifyFadeRemove(frame)
    if not frame then return end
    task.spawn(function()
        local TS = game:GetService("TweenService")
        local t = TS:Create(frame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 1})
        for _, c in pairs(frame:GetChildren()) do
            if c:IsA("TextLabel") or c:IsA("TextButton") then
                TS:Create(c, TweenInfo.new(0.25), {TextTransparency = 1}):Play()
            end
        end
        t:Play(); t.Completed:Wait()
        frame:Destroy()
    end)
end

function UI.ShowNotification(title, text, altId, count)
    if not Owner then return end
    if not UI.NotifContainer then
        local pg = LocalPlayer:WaitForChild("PlayerGui")
        local sg = Instance.new("ScreenGui")
        sg.Name = "CatAltNotifs"; sg.ResetOnSpawn = false; sg.Parent = pg; sg.IgnoreGuiInset = true; sg.DisplayOrder = 10
        local c = Instance.new("Frame")
        c.Size = UDim2.new(0, 420, 0, 300)
        c.Position = UDim2.new(1, -430, 1, -310)
        c.BackgroundTransparency = 1; c.Parent = sg
        local gl = Instance.new("UIGridLayout")
        gl.FillDirection = Enum.FillDirection.Horizontal
        gl.FillDirectionMaxCells = 2
        gl.CellSize = UDim2.new(0.5, -2, 0, 60)
        gl.CellPadding = UDim2.new(0, 4, 0, 4)
        gl.HorizontalAlignment = Enum.HorizontalAlignment.Right
        gl.VerticalAlignment = Enum.VerticalAlignment.Bottom
        gl.Parent = c
        UI.NotifContainer = c; UI.NotifGui = sg
    end
    local key = (text or "") .. "|" .. (title or "")
    for _, child in pairs(UI.NotifContainer:GetChildren()) do
        if child:IsA("Frame") and child:GetAttribute("notifKey") == key then
            local ac = (child:GetAttribute("altCount") or 1) + 1
            child:SetAttribute("altCount", ac)
            local cl = child:FindFirstChild("AltCountLabel")
            if cl then cl.Text = ac .. " alt" .. (ac > 1 and "s" or "") end
            if child:GetAttribute("closeTask") then task.cancel(child:GetAttribute("closeTask")) end
            child:SetAttribute("closeTask", task.delay(3, function() notifyFadeRemove(child) end))
            return
        end
    end
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 1, 0); f.BackgroundColor3 = Color3.fromRGB(30, 32, 30)
    f.BorderSizePixel = 0; f.Parent = UI.NotifContainer
    local uc = Instance.new("UICorner"); uc.CornerRadius = UDim.new(0, 6); uc.Parent = f
    local us = Instance.new("UIStroke"); us.Color = Color3.fromRGB(50, 60, 50); us.Thickness = 1; us.Parent = f
    local PIXEL; local ok, ff = pcall(Font.fromId, 11766871432); if ok then PIXEL = ff end
    local function pix(e) if PIXEL then pcall(function() e.TextFont = PIXEL end) end end
    local ac = count or 1
    local al = Instance.new("TextLabel")
    al.Name = "AltCountLabel"
    al.Size = UDim2.new(1, -20, 0, 12); al.Position = UDim2.new(0, 4, 0, 2)
    al.Text = ac > 1 and (ac .. " alts") or ""; al.TextColor3 = Color3.fromRGB(76, 175, 80)
    al.Font = Enum.Font.GothamBlack; al.TextSize = 8; al.BackgroundTransparency = 1
    al.TextXAlignment = Enum.TextXAlignment.Left; al.Parent = f; pix(al)
    local tl = Instance.new("TextLabel")
    tl.Size = UDim2.new(1, -20, 0, 14); tl.Position = UDim2.new(0, 4, 0, ac > 1 and 14 or 3)
    tl.Text = title or ""; tl.TextColor3 = Color3.fromRGB(210, 210, 210)
    tl.Font = Enum.Font.GothamBlack; tl.TextSize = 10; tl.BackgroundTransparency = 1
    tl.TextXAlignment = Enum.TextXAlignment.Left; tl.TextTruncate = Enum.TextTruncate.AtEnd; tl.Parent = f; pix(tl)
    local tx = Instance.new("TextLabel")
    tx.Size = UDim2.new(1, -20, 0, 16); tx.Position = UDim2.new(0, 4, 0, ac > 1 and 30 or 19)
    tx.Text = text or ""; tx.TextColor3 = Color3.fromRGB(150, 150, 150)
    tx.Font = Enum.Font.Gotham; tx.TextSize = 9; tx.BackgroundTransparency = 1
    tx.TextXAlignment = Enum.TextXAlignment.Left; tx.TextTruncate = Enum.TextTruncate.AtEnd; tx.Parent = f; pix(tx)
    local x = Instance.new("TextButton")
    x.Size = UDim2.new(0, 14, 0, 14); x.Position = UDim2.new(1, -17, 0, 2)
    x.Text = "x"; x.TextColor3 = Color3.fromRGB(120, 120, 120); x.Font = Enum.Font.Gotham; x.TextSize = 10
    x.BackgroundTransparency = 1; x.BorderSizePixel = 0; x.Parent = f
    x.MouseButton1Click:Connect(function() notifyFadeRemove(f) end)
    f:SetAttribute("notifKey", key); f:SetAttribute("altCount", ac)
    f:SetAttribute("closeTask", task.delay(3, function() notifyFadeRemove(f) end))
    -- Animate in: fade from transparent
    f.BackgroundTransparency = 1
    task.spawn(function()
        task.wait()
        local TS = game:GetService("TweenService")
        local t = TS:Create(f, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundTransparency = 0})
        for _, c in pairs(f:GetChildren()) do
            if c:IsA("TextLabel") or c:IsA("TextButton") then
                c.TextTransparency = 1
                TS:Create(c, TweenInfo.new(0.3), {TextTransparency = 0}):Play()
            end
        end
        t:Play()
    end)
end

function UI.Build()
    for _, name in ipairs({"CatAltModern", "CatAltAltSel"}) do
        local g = LocalPlayer.PlayerGui:FindFirstChild(name)
        if g then g:Destroy() end
    end

    -- Pixel font (Minecraft-style)
    local PIXEL
    local ok, f = pcall(Font.fromId, 11766871432)
    if ok then PIXEL = f end
    local FONT = Enum.Font.GothamBlack
    local function pix(elem)
        if PIXEL then pcall(function() elem.TextFont = PIXEL end) end
        return elem
    end

    -- Mint color scheme
    local BG = Color3.fromRGB(26, 28, 26)
    local PANEL = Color3.fromRGB(38, 40, 38)
    local INPUT = Color3.fromRGB(40, 42, 40)
    local ACCENT = Color3.fromRGB(76, 175, 80)
    local TEXT = Color3.fromRGB(210, 210, 210)
    local SUB = Color3.fromRGB(160, 160, 160)

    local function bBtn(parent, text, sz, pos, col)
        local btn = create("TextButton", {
            Parent = parent, Size = sz, Position = pos, Text = text,
            BackgroundColor3 = col or Color3.fromRGB(45, 45, 45),
            TextColor3 = TEXT, Font = FONT, TextSize = 11, AutoButtonColor = false, BorderSizePixel = 0
        })
        create("UICorner", {Parent = btn, CornerRadius = UDim.new(0, 6)})
        pix(btn)
        btn.MouseEnter:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(math.min(col.R*255+25,255), math.min(col.G*255+25,255), math.min(col.B*255+25,255))}):Play()
        end)
        btn.MouseLeave:Connect(function() TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = col}):Play() end)
        return btn
    end

    -- Alt selector overlay (left side, transparent)
    local selGui = create("ScreenGui", {Name = "CatAltAltSel", Parent = LocalPlayer.PlayerGui, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1})
    local selBg = create("Frame", {
        Parent = selGui, Size = UDim2.new(0, 185, 0, 300), Position = UDim2.new(0, 8, 0.5, -150),
        BackgroundColor3 = BG, BackgroundTransparency = 0.35, BorderSizePixel = 0
    })
    create("UICorner", {Parent = selBg, CornerRadius = UDim.new(0, 8)})
    create("UIStroke", {Parent = selBg, Color = Color3.fromRGB(50, 60, 50), Thickness = 1, Transparency = 0.5})

    pix(create("TextLabel", {
        Parent = selBg, Size = UDim2.new(1, -10, 0, 22), Position = UDim2.new(0, 5, 0, 5),
        Text = "ACCOUNTS", TextColor3 = TEXT, Font = FONT, TextSize = 13, BackgroundTransparency = 1
    }))
    UI.AltCountText = pix(create("TextLabel", {
        Parent = selBg, Size = UDim2.new(1, -10, 0, 16), Position = UDim2.new(0, 5, 0, 27),
        Text = "0 ALTS", TextColor3 = ACCENT, Font = FONT, TextSize = 10, BackgroundTransparency = 1
    }))

    UI.AltScroll = create("ScrollingFrame", {
        Parent = selBg, Size = UDim2.new(1, -10, 1, -50), Position = UDim2.new(0, 5, 0, 47),
        BackgroundTransparency = 1, ScrollBarThickness = 2, BorderSizePixel = 0
    })
    create("UIListLayout", {Parent = UI.AltScroll, Padding = UDim.new(0, 3)})

    -- Main command window
    local gui = create("ScreenGui", {Name = "CatAltModern", Parent = LocalPlayer.PlayerGui, ResetOnSpawn = false, DisplayOrder = 2})
    local main = create("Frame", {
        Parent = gui, Size = UDim2.new(0, 360, 0, 420), Position = UDim2.new(0.5, -180, 0.5, -210),
        BackgroundColor3 = BG, BorderSizePixel = 0
    })
    create("UICorner", {Parent = main, CornerRadius = UDim.new(0, 8)})
    create("UIStroke", {Parent = main, Color = Color3.fromRGB(50, 60, 50), Thickness = 1})
    makeDraggable(main, main)

    UI.StatusText = pix(create("TextLabel", {
        Parent = main, Size = UDim2.new(1, -16, 0, 22), Position = UDim2.new(0, 8, 0, 5),
        Text = "CatAlt v" .. VERSION, TextColor3 = ACCENT,
        Font = FONT, TextSize = 13, BackgroundTransparency = 1
    }))
    local SEP = Color3.fromRGB(55, 70, 58)
    create("Frame", {Parent = main, Size = UDim2.new(1, -16, 0, 1), Position = UDim2.new(0, 8, 0, 29), BackgroundColor3 = SEP, BorderSizePixel = 0})

    -- Search area container
    local searchArea = create("Frame", {
        Parent = main, Size = UDim2.new(1, -16, 0, 50), Position = UDim2.new(0, 8, 0, 31),
        BackgroundColor3 = PANEL
    })
    create("UICorner", {Parent = searchArea, CornerRadius = UDim.new(0, 6)})
    create("UIStroke", {Parent = searchArea, Color = Color3.fromRGB(50, 60, 50), Thickness = 1})

    UI.SearchBox = pix(create("TextBox", {
        Parent = searchArea, Size = UDim2.new(1, -10, 0, 22), Position = UDim2.new(0, 5, 0, 4),
        Text = "", PlaceholderText = "search", PlaceholderColor3 = SUB,
        BackgroundColor3 = INPUT, TextColor3 = TEXT, Font = FONT, TextSize = 12,
        BorderSizePixel = 0, ClearTextOnFocus = true
    }))
    create("UICorner", {Parent = UI.SearchBox, CornerRadius = UDim.new(0, 4)})

    -- IY exec box (Enter to exec to checked alts, clears)
    UI.IYBox = pix(create("TextBox", {
        Parent = searchArea, Size = UDim2.new(1, -10, 0, 20), Position = UDim2.new(0, 5, 0, 28),
        Text = "", PlaceholderText = "cmd", PlaceholderColor3 = Color3.fromRGB(80, 100, 80),
        BackgroundColor3 = INPUT, TextColor3 = Color3.fromRGB(180, 220, 180),
        Font = FONT, TextSize = 10, BorderSizePixel = 0, ClearTextOnFocus = false
    }))
    create("UICorner", {Parent = UI.IYBox, CornerRadius = UDim.new(0, 4)})
    UI.IYBox.FocusLost:Connect(function(enter)
        if enter and UI.IYBox.Text ~= "" then
            local cmd = UI.IYBox.Text
            for id, checked in pairs(UI.Checked) do
                if checked then pushCommand(id, {type = "iycmd", data = {command = cmd}}) end
            end
            UI.IYBox.Text = ""
        end
    end)
    create("Frame", {Parent = main, Size = UDim2.new(1, -16, 0, 2), Position = UDim2.new(0, 8, 0, 83), BackgroundColor3 = SEP, BorderSizePixel = 0})

    local actionsList = create("ScrollingFrame", {
        Parent = main, Size = UDim2.new(1, -16, 0, 182), Position = UDim2.new(0, 8, 0, 89),
        BackgroundColor3 = PANEL, ScrollBarThickness = 2, BorderSizePixel = 0
    })
    create("UICorner", {Parent = actionsList, CornerRadius = UDim.new(0, 6)})
    create("UIStroke", {Parent = actionsList, Color = Color3.fromRGB(50, 60, 50), Thickness = 1})
    create("UIListLayout", {Parent = actionsList, Padding = UDim.new(0, 1)})
    create("Frame", {Parent = main, Size = UDim2.new(1, -16, 0, 2), Position = UDim2.new(0, 8, 0, 273), BackgroundColor3 = SEP, BorderSizePixel = 0})

    local paramContainer = create("Frame", {
        Parent = main, Size = UDim2.new(1, -16, 0, 100), Position = UDim2.new(0, 8, 0, 279),
        BackgroundColor3 = PANEL
    })
    create("UICorner", {Parent = paramContainer, CornerRadius = UDim.new(0, 6)})
    create("UIStroke", {Parent = paramContainer, Color = Color3.fromRGB(50, 60, 50), Thickness = 1})
    create("Frame", {Parent = main, Size = UDim2.new(1, -16, 0, 2), Position = UDim2.new(0, 8, 0, 381), BackgroundColor3 = SEP, BorderSizePixel = 0})
    UI.ParamScroll = create("ScrollingFrame", {Parent = paramContainer, Size = UDim2.new(1, -10, 1, -10), Position = UDim2.new(0, 5, 0, 5), BackgroundTransparency = 1, ScrollBarThickness = 2})
    create("UIListLayout", {Parent = UI.ParamScroll, Padding = UDim.new(0, 4)})

    UI.ParamInputs = {}
    UI.SearchText = ""
    UI.AllActions = {}

    local function getFilteredActions()
        local merged = {}
        for _, a in ipairs(ACTIONS) do table.insert(merged, a) end
        for _, a in ipairs(IY_ACTIONS) do table.insert(merged, a) end
        local search = UI.SearchText:lower()
        if search == "" then return merged end
        local filtered = {}
        for _, a in ipairs(merged) do
            if a.name:lower():find(search, 1, true) or (a.description and a.description:lower():find(search, 1, true)) then
                table.insert(filtered, a)
            end
        end
        return filtered
    end

    local function renderParams()
        for _, c in pairs(UI.ParamScroll:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
        UI.ParamInputs = {}
        local action = UI.AllActions[UI.SelectedAction]
        if not action then return end
        if not action.params then return end
        for _, p in ipairs(action.params) do
            local row = create("Frame", {Parent = UI.ParamScroll, Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1})
            pix(create("TextLabel", {Parent = row, Size = UDim2.new(0.35, 0, 1, 0), Text = p[1], TextColor3 = SUB, Font = FONT, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1}))
            local box = pix(create("TextBox", {
                Parent = row, Size = UDim2.new(0.65, 0, 1, 0), Position = UDim2.new(0.35, 4, 0, 0),
                Text = p[3] or "", BackgroundColor3 = INPUT, TextColor3 = TEXT,
                Font = FONT, TextSize = 10, BorderSizePixel = 0, ClearTextOnFocus = false
            }))
            create("UICorner", {Parent = box, CornerRadius = UDim.new(0, 4)})
            UI.ParamInputs[p[2]] = box
            if p[4] then attachAutofill(box, row) end
        end
    end

    UI.Rerender = function()
        UI.AllActions = getFilteredActions()
        for _, c in pairs(actionsList:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
        for i, action in ipairs(UI.AllActions) do
            local isSel = (i == UI.SelectedAction)
            local bg = isSel and ACCENT or Color3.fromRGB(30, 32, 30)
            local btn = pix(create("TextButton", {
                Parent = actionsList, Size = UDim2.new(1, -4, 0, 24), Position = UDim2.new(0, 2, 0, 0),
                Text = "  " .. action.name, TextColor3 = TEXT, Font = FONT, TextSize = 11,
                BackgroundColor3 = bg, BorderSizePixel = 0, TextXAlignment = Enum.TextXAlignment.Left
            }))
            create("UICorner", {Parent = btn, CornerRadius = UDim.new(0, 4)})
            btn.MouseButton1Click:Connect(function() UI.SelectedAction = i; UI.Rerender(); renderParams() end)
        end
        actionsList.CanvasSize = UDim2.new(0, 0, 0, #UI.AllActions * 26)
        renderParams()
    end

    UI.SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
        UI.SearchText = UI.SearchBox.Text
        UI.SelectedAction = 1
        UI.Rerender()
    end)

    UI.Rerender()

    local bottom = create("Frame", {Parent = main, Size = UDim2.new(1, -16, 0, 24), Position = UDim2.new(0, 8, 0, 387), BackgroundTransparency = 1})
    local STOP = Color3.fromRGB(170, 80, 60)
    local BRING = Color3.fromRGB(60, 90, 100)
    local EXEC = Color3.fromRGB(56, 142, 60)

    bBtn(bottom, "STOP", UDim2.new(0.19, 0, 1, 0), UDim2.new(0, 0, 0, 0), STOP).MouseButton1Click:Connect(function()
        for id in pairs(UI.Alts) do pushCommand(id, {type = "stop"}) end
    end)
    bBtn(bottom, "BRING", UDim2.new(0.19, 0, 1, 0), UDim2.new(0.22, 0, 0, 0), BRING).MouseButton1Click:Connect(function()
        local pos = getPos()
        for id in pairs(UI.Alts) do pushCommand(id, {type = "tp", data = {position = {pos.X, pos.Y, pos.Z}}}) end
    end)
    local execBtn = bBtn(bottom, "EXEC", UDim2.new(0.56, 0, 1, 0), UDim2.new(0.44, 0, 0, 0), EXEC)
    execBtn.MouseButton1Click:Connect(function()
        local action = UI.AllActions[UI.SelectedAction]
        if not action then return end
        local data = {}
        for k, box in pairs(UI.ParamInputs) do
            local num = tonumber(box.Text)
            data[k] = num or box.Text
            if box.Text == "" then data[k] = nil end
        end
        local activeKey = action.key
        if action.iyCommand then
            local parts = {action.iyName}
            for _, p in ipairs(action.params or {}) do
                local val = data[p[2]]
                if val and tostring(val) ~= "" then table.insert(parts, tostring(val)) end
            end
            data = {command = table.concat(parts, " ")}
            activeKey = "iycmd"
        elseif activeKey == "test_sync" then
            local pos = getPos()
            if pos then data.ownerPos = {pos.X, pos.Y, pos.Z} end
        elseif activeKey == "test_notif" then
            UI.ShowNotification("Test Title", "Test notification body from CatAlt", MY_ID, 1)
            return
        elseif activeKey == "platform" then
            if platformActive then
                platformActive = false
                for id, checked in pairs(UI.Checked) do
                    if checked then pushCommand(id, {type = "stop"}) end
                end
                return
            end
            local tgtName = data.target or MNAME
            local checkedIds = {}
            for id, checked in pairs(UI.Checked) do
                if checked then table.insert(checkedIds, id) end
            end
            if #checkedIds == 0 then return end
            platformActive = true; platformMaxY = nil
            UI.ShowNotification("Platform", "Using " .. #checkedIds .. " alt" .. (#checkedIds > 1 and "s" or ""), MY_ID, #checkedIds)
            for i, id in ipairs(checkedIds) do
                pushCommand(id, {type = "platform", data = {ownerName = tgtName, total = #checkedIds, idx = i}})
            end
            return
        end
        local checkedIds = {}
        for id, checked in pairs(UI.Checked) do
            if checked then table.insert(checkedIds, id) end
        end
        local batchTotal, batchIds = #checkedIds, checkedIds
        local sent = 0
        for id, checked in pairs(UI.Checked) do
            if checked then pushCommand(id, {type = activeKey, data = data, totalOnline = batchTotal, onlineIds = batchIds}); sent = sent + 1 end
        end
        if sent > 0 then UI.ShowNotification(action.name, "Executed on " .. sent .. " alt" .. (sent > 1 and "s" or ""), MY_ID, sent) end
    end)
end

function UI.RefreshAlts()
    if not UI.AltScroll then return end
    for _, c in pairs(UI.AltScroll:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
    local sorted = {}
    for id, data in pairs(UI.Alts) do
        if id ~= MY_ID and (os.time() - (data.lastPing or 0)) <= 10 then
            table.insert(sorted, {id = id, data = data})
        end
    end
    table.sort(sorted, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
    local FONT = Enum.Font.GothamBlack
    local PIXEL
    local ok, f = pcall(Font.fromId, 11766871432)
    if ok then PIXEL = f end
    for i, entry in ipairs(sorted) do
        local id, data = entry.id, entry.data
        local sel = UI.Checked[id]
        local row = create("Frame", {
            Parent = UI.AltScroll, Size = UDim2.new(1, 0, 0, 24),
            BackgroundColor3 = sel and Color3.fromRGB(56, 142, 60) or Color3.fromRGB(30, 32, 30),
            BorderSizePixel = 0
        })
        create("UICorner", {Parent = row, CornerRadius = UDim.new(0, 4)})
        local btn = create("TextButton", {
            Parent = row, Size = UDim2.new(1, 0, 1, 0), Text = "", BackgroundTransparency = 1, BorderSizePixel = 0
        })
        btn.MouseButton1Click:Connect(function() UI.Checked[id] = not sel; UI.RefreshAlts() end)
        local sameServer = data.jobId and tostring(data.jobId) == tostring(game.JobId)
        local dot = create("Frame", {
            Parent = row, Size = UDim2.new(0, 6, 0, 6), Position = UDim2.new(0, 6, 0, 9),
            BackgroundColor3 = sameServer and Color3.fromRGB(76, 175, 80) or Color3.fromRGB(255, 180, 50),
            BorderSizePixel = 0
        })
        create("UICorner", {Parent = dot, CornerRadius = UDim.new(1, 0)})
        local label = create("TextLabel", {
            Parent = row, Size = UDim2.new(1, -20, 1, 0), Position = UDim2.new(0, 16, 0, 0),
            Text = i .. ". " .. (data.name or id), TextColor3 = Color3.fromRGB(210, 210, 210),
            Font = FONT, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1
        })
        if PIXEL then pcall(function() label.TextFont = PIXEL end) end
    end
    UI.AltScroll.CanvasSize = UDim2.new(0, 0, 0, #sorted * 28)
    if UI.AltCountText then UI.AltCountText.Text = #sorted .. " ALTS" end
end

local function loopBackend()
    local notifPoll = 0
    while isRunning do
        local ok, data = catbaseGet("/" .. SESSION_KEY .. "/alts.json")
        if ok and type(data) == "table" then
            UI.Alts = data
            for id in pairs(data) do if id ~= MY_ID and UI.Checked[id] == nil then UI.Checked[id] = false end end
            UI.RefreshAlts()
        end
        -- Owner: poll for alt notifications
        if Owner and tick() - notifPoll > 1 then
            notifPoll = tick()
            local ok2, nq = catbaseGet("/" .. SESSION_KEY .. "/notifq.json")
            if ok2 and type(nq) == "table" and #nq > 0 then
                local merged = {}
                for _, entry in ipairs(nq) do
                    if os.time() - (entry.t or 0) < 10 then
                        local key = (entry.text or "") .. "|" .. (entry.title or "")
                        if not merged[key] then
                            merged[key] = {title = entry.title, text = entry.text, altId = entry.altId, count = 0}
                        end
                        merged[key].count = merged[key].count + 1
                    end
                end
                for _, m in pairs(merged) do
                    UI.ShowNotification(m.title, m.text, m.altId, m.count)
                end
                catbasePut("/" .. SESSION_KEY .. "/notifq.json", {})
            end
        end
        task.wait(POLL_INTERVAL)
    end
end

-- ════════ INIT ════════
-- Step 1: register this account in the CatBase bot list
local function startup()
    if not waitForCharacter() then warn("[CatAlt] No character after timeout"); return end
    if not Owner then
        task.spawn(function()
            task.wait(0.5)
            local c = getChar()
            if c then
                local h = c:FindFirstChildOfClass("Humanoid")
                if h then pcall(function() h:ChangeState(Enum.HumanoidStateType.Jumping) end) end
            end
        end)
    end
    registerBot()
    publishState() -- ensure self appears in alts.json before discover
    task.wait(1) -- brief window for other bots to register
    discoverBots()
    -- Determine fixed botNumber from position in alts.json (if not already set)
    if not botNumber then
        local ok, alts = catbaseGet("/" .. SESSION_KEY .. "/alts.json")
        if ok and type(alts) == "table" then
            local keys = {}
            for id, st in pairs(alts) do
                if (os.time() - (st.lastPing or 0)) <= 15 then
                    table.insert(keys, id)
                end
            end
            table.sort(keys)
            for i, id in ipairs(keys) do
                if id == MY_ID then botNumber = i; break end
            end
            totalAlts = #keys
        end
    end
    if totalAlts == 0 then totalAlts = #botList end
    print("[CatAlt] " .. (Owner and "Owner" or "Alt") .. " mode. Bot#" .. tostring(botNumber) .. ", BotIndex: " .. tostring(botIndex) .. ", Bots: " .. #botList)

    -- If alt is not in owner's server, auto-join
    if not Owner and not botIndex then
        task.spawn(function()
            task.wait(3)
            local ok, alts = catbaseGet("/" .. SESSION_KEY .. "/alts.json")
            if ok and type(alts) == "table" then
                for _, st in pairs(alts) do
                    if st.isOwner and st.jobId and st.placeId then
                        local ts = game:GetService("TeleportService")
                        pcall(function()
                            ts:TeleportToPlaceInstance(st.placeId, st.jobId, LocalPlayer)
                        end)
                        break
                    end
                end
            end
        end)
    end

    if Owner then
        UI.Build()
        -- Fetch and parse IY source to populate command list (no GUI needed)
        if AUTO_LOAD_IY then
            task.spawn(function()
                task.wait(2)
                fetchAndPopulateIYCommands()
            end)
        end
        while isRunning do
            local pok, perr = pcall(function()
            publishState() -- owner's jobId must be in alts.json for same-server filtering
            local ok, data = catbaseGet("/" .. SESSION_KEY .. "/alts.json")
            if ok and type(data) == "table" then
                UI.Alts = data
                for id in pairs(data) do if id ~= MY_ID and UI.Checked[id] == nil then UI.Checked[id] = false end end
                UI.RefreshAlts()
            end
            discoverBots() -- refresh bot list (only same-server bots)
            task.wait(POLL_INTERVAL)
            end); if not pok then copyErr("Owner loop: " .. tostring(perr)) end
        end
    else
        -- Chat listener (same-server commands from owner)
        local function tryConnectChat()
            if not OWNER_NAME then return end
            local ownerPlayer = Players:FindFirstChild(OWNER_NAME)
            if ownerPlayer then connectChatListener(ownerPlayer) end
        end
        tryConnectChat()
        Players.PlayerAdded:Connect(function(plr)
            if plr.Name == OWNER_NAME then connectChatListener(plr) end
        end)

        startAntiAfk()

        -- Auto-load Infinite Yield on alt
        if AUTO_LOAD_IY then
            task.spawn(function()
                task.wait(2)
                pcall(CMD.loadiy)
            end)
        end

        -- Alt overlay: status info + kill/relaunch
        task.spawn(function()
            local pg = LocalPlayer:WaitForChild("PlayerGui")
            for _, n in ipairs({"CatAltOverlay", "CatAltStatus", "CatAltLoading"}) do
                local e = pg:FindFirstChild(n)
                if e then e:Destroy() end
            end
            local scr = Instance.new("ScreenGui")
            scr.Name = "CatAltOverlay"; scr.ResetOnSpawn = false; scr.Parent = pg; scr.IgnoreGuiInset = true
            local bg = Instance.new("Frame")
            bg.Size = UDim2.new(1, 0, 1, 0); bg.BackgroundColor3 = Color3.new(0, 0, 0)
            bg.BackgroundTransparency = 0; bg.BorderSizePixel = 0; bg.Parent = scr

            local function makeLabel(text, posYScale, size, fontSize, color, bold)
                local lbl = Instance.new("TextLabel")
                lbl.Size = UDim2.new(0, 260, 0, size); lbl.Position = UDim2.new(0, 40, posYScale, 0)
                lbl.Text = text; lbl.TextColor3 = color or Color3.fromRGB(200, 200, 200)
                lbl.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham; lbl.TextSize = fontSize
                lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.BackgroundTransparency = 1
                lbl.Parent = scr; lbl.ZIndex = 2
                return lbl
            end

            local sy = 0.35
            local userLbl = makeLabel("User: " .. MNAME, sy, 22, 15, Color3.fromRGB(180, 180, 180))
            sy = sy + 0.03
            local ownerLbl = makeLabel("Owner: " .. (OWNER_NAME or "unknown"), sy, 22, 15, Color3.fromRGB(180, 180, 180))
            sy = sy + 0.03
            local pingLbl = makeLabel("Ping: 0 ms", sy, 22, 15, Color3.fromRGB(180, 180, 180))
            sy = sy + 0.03
            local fpsLbl = makeLabel("FPS: 0", sy, 22, 15, Color3.fromRGB(180, 180, 180))
            sy = sy + 0.03
            local renderLbl = makeLabel(renderStatus, sy, 22, 15, Color3.fromRGB(180, 180, 180))

            local actionLbl = Instance.new("TextLabel")
            actionLbl.Size = UDim2.new(1, 0, 0, 36); actionLbl.Position = UDim2.new(0, 0, 0.44, 0)
            actionLbl.Text = "Idle"; actionLbl.TextColor3 = Color3.fromRGB(220, 220, 220)
            actionLbl.Font = Enum.Font.GothamBold; actionLbl.TextSize = 24
            actionLbl.TextXAlignment = Enum.TextXAlignment.Center; actionLbl.BackgroundTransparency = 1
            actionLbl.Parent = scr; actionLbl.ZIndex = 2

            local verLbl = Instance.new("TextLabel")
            verLbl.Size = UDim2.new(1, 0, 0, 22); verLbl.Position = UDim2.new(0, 0, 0.52, 0)
            verLbl.Text = "CatAlt v" .. VERSION; verLbl.TextColor3 = Color3.fromRGB(100, 100, 100)
            verLbl.Font = Enum.Font.Gotham; verLbl.TextSize = 15
            verLbl.TextXAlignment = Enum.TextXAlignment.Center; verLbl.BackgroundTransparency = 1
            verLbl.Parent = scr; verLbl.ZIndex = 2

            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(0, 220, 0, 44); btn.Position = UDim2.new(0.5, -110, 1, -60)
            btn.Text = "KILL & RELAUNCH"
            btn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
            btn.BackgroundTransparency = 0.5
            btn.TextColor3 = Color3.fromRGB(180, 180, 180)
            btn.Font = Enum.Font.GothamBold; btn.TextSize = 14
            btn.BorderSizePixel = 0; btn.AutoButtonColor = false; btn.Parent = scr; btn.ZIndex = 2
            create("UICorner", {Parent = btn, CornerRadius = UDim.new(0, 8)})
            btn.MouseButton1Click:Connect(function()
                btn.Text = "RELOADING..."; isRunning = false; _G.CatAlt_Running = nil
                if pg:FindFirstChild("CatAltOverlay") then pg.CatAltOverlay:Destroy() end
                if pg:FindFirstChild("CatAltModern") then pg.CatAltModern:Destroy() end
                local ok, src = pcall(game.HttpGet, game, 'https://catcloud.catapis.uk/share/523b0147-7dbf-40a4-849f-2d3dc24c39b0')
                if ok and src then local fn, err = loadstring(src); if fn then task.wait(0.5); pcall(fn) else warn("[CatAlt] Reload failed:", err) end
                else warn("[CatAlt] Reload failed: could not fetch script") end
            end)
            btn.MouseEnter:Connect(function() btn.BackgroundTransparency = 0.2; btn.TextColor3 = Color3.new(1, 1, 1) end)
            btn.MouseLeave:Connect(function() btn.BackgroundTransparency = 0.5; btn.TextColor3 = Color3.fromRGB(180, 180, 180) end)
            btn.MouseButton1Down:Connect(function() btn.BackgroundTransparency = 0.1 end)
            btn.MouseButton1Up:Connect(function() btn.BackgroundTransparency = 0.5 end)

            local lastT = tick(); local fpsVal = 0
            RunService.Heartbeat:Connect(function()
                local now = tick(); local dt = now - lastT; lastT = now
                fpsVal = dt > 0 and math.floor(1 / dt) or 0
            end)
            while isRunning do
                actionLbl.Text = currentAction
                pingLbl.Text = "Ping: " .. math.floor(LocalPlayer:GetNetworkPing() * 1000) .. " ms"
                fpsLbl.Text = "FPS: " .. tostring(fpsVal)
                task.wait(0.2)
            end
        end)

        -- Fast command polling (every 0.1s) — makes alts respond near-instantly
        task.spawn(function()
            while isRunning do
                task.wait(0.1)
                local pok, perr = pcall(function()
                    if waitForCharacter() then pollCommands() end
                end); if not pok then copyErr("Poll loop: " .. tostring(perr)) end
            end
        end)

        -- State publishing + bot index refresh (keeps numbering consistent)
        while isRunning do
            task.wait(POLL_INTERVAL)
            local pok, perr = pcall(function()
                if waitForCharacter() then
                    publishState()
                    discoverBots()
                end
            end); if not pok then copyErr("State loop: " .. tostring(perr)) end
        end
    end
end

task.spawn(function()
    local ok, err = pcall(startup)
    if not ok then
        local msg = "Startup crashed: " .. tostring(err)
        warn("[CatAlt] " .. msg)
        copyErr(msg)
    end
end)
