--[[
    CatControl Executor v4.0

    - Anti-double-execute guard
    - Auto-registers with Catbase
    - Heartbeat, auto-rejoin on kick
    - Player list reporting
    - Fling, goto player, tp to player, speed, noclip, god, invis, fly
    - Skips cleared commands
]]

-- ═══════════════════════════════════════════════════════════════════════════════
--  ANTI-DOUBLE-EXECUTE
-- ═══════════════════════════════════════════════════════════════════════════════

if _G.CatControlRunning then
    warn("[CatControl] Already running — skipping duplicate execution")
    return
end
_G.CatControlRunning = true

-- ═══════════════════════════════════════════════════════════════════════════════
--  CONFIG
-- ═══════════════════════════════════════════════════════════════════════════════

local CONFIG = {
    catbaseUrl = "https://catbase.catapis.uk",
    apiKey     = "0bdfcf7e815ae951f75a66a475feb6ed4b723b81ebd9ef473a761b99cc9d4f6e",
    database   = "roblox_control",

    pollInterval      = 2,
    heartbeatInterval = 15,
    retryDelay        = 5,
    maxRetries        = 3,
    backoffDelay      = 15,

    debug = true,
}

-- ═══════════════════════════════════════════════════════════════════════════════
--  SERVICES
-- ═══════════════════════════════════════════════════════════════════════════════

local Players            = game:GetService("Players")
local TeleportService    = game:GetService("TeleportService")
local HttpService        = game:GetService("HttpService")
local StarterGui         = game:GetService("StarterGui")
local MarketplaceService = game:GetService("MarketplaceService")
local CoreGui            = game:GetService("CoreGui")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

-- ═══════════════════════════════════════════════════════════════════════════════
--  PER-USER PATHS
-- ═══════════════════════════════════════════════════════════════════════════════

local USERNAME      = LocalPlayer.Name
local EXECUTOR_PATH = "executors/" .. USERNAME
local COMMAND_PATH  = "commands/" .. USERNAME
local LOG_PATH      = "logs/" .. USERNAME

-- ═══════════════════════════════════════════════════════════════════════════════
--  HTTP ABSTRACTION
-- ═══════════════════════════════════════════════════════════════════════════════

local function httpRequest(params)
    if syn and syn.request then
        return syn.request(params)
    elseif http and http.request then
        return http.request(params)
    elseif http_request then
        return http_request(params)
    elseif request then
        return request(params)
    elseif fluxus and fluxus.request then
        return fluxus.request(params)
    else
        error("No HTTP request function found")
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════════

local function log(msg, level)
    level = level or "INFO"
    local text = string.format("[CatControl] [%s] %s", level, tostring(msg))
    if CONFIG.debug or level == "ERROR" or level == "WARN" then
        print(text)
    end
    if level == "ERROR" or level == "WARN" then
        pcall(function()
            StarterGui:SetCore("SendNotification", {
                Title = "CatControl",
                Text = tostring(msg),
                Duration = 4,
            })
        end)
    end
end

local function notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title or "CatControl",
            Text = text or "",
            Duration = duration or 3,
        })
    end)
end

local function jsonDecode(str)
    local ok, result = pcall(function() return HttpService:JSONDecode(str) end)
    if ok then return result end
    return nil
end

local function jsonEncode(tbl)
    local ok, result = pcall(function() return HttpService:JSONEncode(tbl) end)
    if ok then return result end
    return "{}"
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  CATBASE API
-- ═══════════════════════════════════════════════════════════════════════════════

local function catbaseGet(path)
    local url = string.format("%s/db/%s/%s", CONFIG.catbaseUrl, CONFIG.database, path)
    local ok, response = pcall(function()
        return httpRequest({
            Url = url, Method = "GET",
            Headers = { ["X-API-Key"] = CONFIG.apiKey, ["Content-Type"] = "application/json" },
        })
    end)
    if not ok then log("GET failed: " .. tostring(response), "ERROR"); return nil end
    if response.StatusCode ~= 200 then return nil end
    return jsonDecode(response.Body)
end

local function catbasePut(path, data)
    local url = string.format("%s/db/%s/%s", CONFIG.catbaseUrl, CONFIG.database, path)
    local ok, response = pcall(function()
        return httpRequest({
            Url = url, Method = "PUT", Body = jsonEncode(data),
            Headers = { ["X-API-Key"] = CONFIG.apiKey, ["Content-Type"] = "application/json" },
        })
    end)
    if not ok then log("PUT failed: " .. tostring(response), "ERROR"); return false end
    return response.StatusCode == 200
end

local function catbasePatch(path, data)
    local url = string.format("%s/db/%s/%s", CONFIG.catbaseUrl, CONFIG.database, path)
    local ok, response = pcall(function()
        return httpRequest({
            Url = url, Method = "PATCH", Body = jsonEncode(data),
            Headers = { ["X-API-Key"] = CONFIG.apiKey, ["Content-Type"] = "application/json" },
        })
    end)
    if not ok then log("PATCH failed: " .. tostring(response), "ERROR"); return false end
    return response.StatusCode == 200
end

local function catbasePost(path, data)
    local url = string.format("%s/db/%s/%s", CONFIG.catbaseUrl, CONFIG.database, path)
    local ok, response = pcall(function()
        return httpRequest({
            Url = url, Method = "POST", Body = jsonEncode(data),
            Headers = { ["X-API-Key"] = CONFIG.apiKey, ["Content-Type"] = "application/json" },
        })
    end)
    if not ok then log("POST failed: " .. tostring(response), "ERROR"); return false end
    return response.StatusCode == 200
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  PLAYER FINDER HELPER
-- ═══════════════════════════════════════════════════════════════════════════════

local function findPlayer(name)
    if not name or name == "" then return nil end
    name = name:lower()
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower() == name or p.DisplayName:lower() == name then
            return p
        end
    end
    -- partial match
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower():find(name, 1, true) or p.DisplayName:lower():find(name, 1, true) then
            return p
        end
    end
    return nil
end

local function getCharPos(player)
    local char = player and player.Character
    local root = char and (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head"))
    return root and root.Position
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  REGISTRATION & HEARTBEAT
-- ═══════════════════════════════════════════════════════════════════════════════

local function getGameName()
    local name = "Unknown"
    pcall(function()
        local info = MarketplaceService:GetProductInfo(game.PlaceId)
        if info and info.Name then name = info.Name end
    end)
    return name
end

local function register()
    local gameName = getGameName()
    local data = {
        username = USERNAME,
        userId   = LocalPlayer.UserId,
        placeId  = game.PlaceId,
        jobId    = game.JobId,
        game     = gameName,
        status   = "online",
        joinedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        lastSeen = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    local ok = catbasePut(EXECUTOR_PATH, data)
    if ok then
        log("Registered as: " .. USERNAME)
        log("  Game: " .. gameName .. " (" .. tostring(game.PlaceId) .. ")")
    else
        log("Registration failed!", "ERROR")
    end
    return ok
end

local function heartbeat()
    while true do
        task.wait(CONFIG.heartbeatInterval)
        catbasePatch(EXECUTOR_PATH, {
            status   = "online",
            lastSeen = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            placeId  = game.PlaceId,
            jobId    = game.JobId,
        })
    end
end

local function setOffline()
    pcall(function()
        catbasePatch(EXECUTOR_PATH, {
            status   = "offline",
            lastSeen = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        })
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  AUTO-REJOIN ON KICK
-- ═══════════════════════════════════════════════════════════════════════════════

local function setupAutoRejoin()
    local placeId = game.PlaceId

    pcall(function()
        local errorPrompt = CoreGui:WaitForChild("RobloxPromptGui", 2)
        if errorPrompt then
            errorPrompt.DescendantAdded:Connect(function()
                log("Kick detected — auto-rejoining in 3s...", "WARN")
                task.wait(3)
                TeleportService:Teleport(placeId, LocalPlayer)
            end)
        end
    end)

    pcall(function()
        TeleportService.TeleportInitFailed:Connect(function(player, result)
            if player == LocalPlayer then
                log("Teleport failed (" .. tostring(result) .. ") — retrying in 5s...", "WARN")
                task.wait(5)
                TeleportService:Teleport(placeId, LocalPlayer)
            end
        end)
    end)

    pcall(function()
        LocalPlayer.OnTeleport:Connect(function(state)
            if state == Enum.TeleportState.Failed then
                log("Teleport state failed — retrying in 5s...", "WARN")
                task.wait(5)
                TeleportService:Teleport(placeId, LocalPlayer)
            end
        end)
    end)

    log("Auto-rejoin hooks installed")
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  COMMAND HANDLERS
-- ═══════════════════════════════════════════════════════════════════════════════

local CommandHandlers = {}

-- ── Game Control ──

CommandHandlers["leave"] = function(args)
    log("Executing: LEAVE")
    notify("CatControl", "Leaving game...", 2)
    setOffline()
    task.wait(0.5)
    game:Shutdown()
end

CommandHandlers["reset"] = function(args)
    log("Executing: RESET")
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.Health = 0 else char:BreakJoints() end
    end
end

CommandHandlers["rejoin"] = function(args)
    log("Executing: REJOIN")
    setOffline()
    task.wait(0.5)
    TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
end

CommandHandlers["serverhop"] = function(args)
    log("Executing: SERVER HOP")
    setOffline()
    task.wait(0.5)
    TeleportService:Teleport(game.PlaceId, LocalPlayer)
end

CommandHandlers["teleport"] = function(args)
    local placeId = args and tonumber(args.placeId)
    if not placeId then return false, "missing placeId" end
    log("Executing: TELEPORT to " .. tostring(placeId))
    setOffline()
    task.wait(0.5)
    TeleportService:Teleport(placeId, LocalPlayer)
end

-- ── Execution ──

CommandHandlers["exec"] = function(args)
    local code = args and args.code
    if not code or code == "" then return false, "no code" end
    log("Executing: EXEC (" .. #code .. " chars)")
    local fn, err = loadstring(code)
    if not fn then return false, "compile: " .. tostring(err) end
    local ok, runErr = pcall(fn)
    if not ok then return false, "runtime: " .. tostring(runErr) end
    return true
end

CommandHandlers["chat"] = function(args)
    local msg = args and (args.message or args.value)
    if not msg then return false, "no message" end
    log("Executing: CHAT → " .. tostring(msg))
    local ok = pcall(function()
        local tcs = game:GetService("TextChatService")
        local ch = tcs.TextChannels:FindFirstChild("RBXGeneral")
        if ch then ch:SendAsync(tostring(msg)) end
    end)
    if not ok then
        pcall(function()
            game:GetService("ReplicatedStorage").DefaultChatSystemChatEvents
                .SayMessageRequest:FireServer(tostring(msg), "All")
        end)
    end
end

CommandHandlers["print"] = function(args)
    local msg = args and (args.message or args.value) or "hello"
    log("PRINT: " .. tostring(msg))
    notify("CatControl", tostring(msg), 5)
end

-- ── Movement ──

CommandHandlers["jump"] = function(args)
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end

CommandHandlers["walkto"] = function(args)
    -- walkto by coordinates OR by player name
    local target = args and args.target
    if target then
        local player = findPlayer(target)
        if not player then return false, "player not found: " .. target end
        local pos = getCharPos(player)
        if not pos then return false, "player has no character" end
        local char = LocalPlayer.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then hum:MoveTo(pos) end
        end
        log("WALKTO player: " .. player.Name)
        return true
    end
    -- fallback: coordinates
    local x = args and tonumber(args.x) or 0
    local y = args and tonumber(args.y) or 0
    local z = args and tonumber(args.z) or 0
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum:MoveTo(Vector3.new(x, y, z)) end
    end
end

CommandHandlers["goto"] = function(args)
    -- Teleport to a player's position
    local target = args and args.target
    if not target then return false, "no target" end
    local player = findPlayer(target)
    if not player then return false, "player not found: " .. target end
    local pos = getCharPos(player)
    if not pos then return false, "player has no character" end
    local char = LocalPlayer.Character
    if char then
        local root = char:FindFirstChild("HumanoidRootPart")
        if root then
            root.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
            log("GOTO player: " .. player.Name)
        end
    end
end

-- ── Player Interaction ──

CommandHandlers["fling"] = function(args)
    local target = args and args.target
    if not target then return false, "no target" end
    local player = findPlayer(target)
    if not player then return false, "player not found: " .. target end
    local targetChar = player.Character
    if not targetChar then return false, "player has no character" end

    local myChar = LocalPlayer.Character
    if not myChar then return false, "you have no character" end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return false, "no root part" end
    local myHum = myChar:FindFirstChildOfClass("Humanoid")
    if not myHum then return false, "no humanoid" end

    local targetRoot = targetChar:FindFirstChild("HumanoidRootPart")
    if not targetRoot then return false, "target has no root part" end

    log("FLING player: " .. player.Name)

    -- Create anchor part + AlignPosition (from danya23131's fling)
    local fakepart = Instance.new("Part", workspace)
    fakepart.Anchored = true
    fakepart.Size = Vector3.new(1, 1, 1)
    fakepart.CanCollide = false
    fakepart.Transparency = 1
    fakepart.Position = myRoot.Position

    local att1 = Instance.new("Attachment", fakepart)
    local att2 = Instance.new("Attachment", myRoot)
    local body = Instance.new("AlignPosition", fakepart)
    body.Attachment0 = att2
    body.Attachment1 = att1
    body.RigidityEnabled = true
    body.Responsiveness = math.huge
    body.MaxForce = math.huge
    body.MaxVelocity = math.huge
    body.MaxAxesForce = Vector3.new(math.huge, math.huge, math.huge)
    body.Mode = Enum.PositionAlignmentMode.TwoAttachment

    -- Enter fling state
    myHum:ChangeState(Enum.HumanoidStateType.StrafingNoPhysics)
    myHum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)

    -- Launch up to build momentum
    local oldcf = myRoot.CFrame
    myRoot.CFrame = CFrame.new(Vector3.new(0, 40000000, 0)) * CFrame.fromEulerAnglesXYZ(math.rad(180), 0, 0)
    myRoot.Velocity = Vector3.new(0, 1000000, 0)
    task.wait(3)
    myRoot.Velocity = Vector3.new(0, 0, 0)
    myRoot.CFrame = oldcf
    task.wait(0.2)

    -- Move to target and spin with high velocity
    local duration = 6
    local startTime = tick()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if tick() - startTime > duration then
            conn:Disconnect()
            return
        end

        -- Refresh target position
        local tRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        if not tRoot then
            conn:Disconnect()
            return
        end

        -- Move fakepart to target
        fakepart.Position = tRoot.Position

        -- Face target
        pcall(function()
            local lookAt = CFrame.lookAt(
                myRoot.Position,
                Vector3.new(tRoot.Position.X, myRoot.Position.Y, tRoot.Position.Z)
            )
            myRoot.CFrame = lookAt
        end)

        -- Apply fling velocity + angular spin
        myRoot.AssemblyAngularVelocity = Vector3.new(
            math.random(-500, 50),
            math.random(-500, 500) * 100,
            math.random(-5, 5)
        )
        myRoot.Velocity = Vector3.new(
            math.random(-250, 250),
            math.random(-500, 500),
            math.random(-250, 250)
        )

        myRoot.CFrame = fakepart.CFrame
        myHum:ChangeState(Enum.HumanoidStateType.Swimming)
    end)

    -- Wait for fling duration then clean up
    task.delay(duration + 0.5, function()
        pcall(function() conn:Disconnect() end)
        pcall(function() att1:Destroy() end)
        pcall(function() att2:Destroy() end)
        pcall(function() body:Destroy() end)
        pcall(function() fakepart:Destroy() end)
        pcall(function()
            myHum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
            myHum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end)
end

-- ── Info ──

CommandHandlers["players"] = function(args)
    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do
        table.insert(list, {
            name = p.Name,
            displayName = p.DisplayName,
            userId = p.UserId,
        })
    end
    -- Write the player list to catbase for the bot to read
    catbasePut("playerlist/" .. USERNAME, {
        players = list,
        count = #list,
        updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })
    log("Reported " .. #list .. " players")
end

CommandHandlers["ping"] = function(args)
    log("PING — alive")
    notify("CatControl", "Pong!", 3)
end

CommandHandlers["none"] = function(args)
    return true
end

-- ── Extras ──

CommandHandlers["speed"] = function(args)
    local val = args and tonumber(args.value) or 50
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = val end
    end
    log("SPEED set to: " .. tostring(val))
end

CommandHandlers["jumppower"] = function(args)
    local val = args and tonumber(args.value) or 100
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            hum.UseJumpPower = true
            hum.JumpPower = val
        end
    end
    log("JUMPPOWER set to: " .. tostring(val))
end

CommandHandlers["god"] = function(args)
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.MaxHealth = math.huge; hum.Health = math.huge end
    end
    log("GOD mode enabled")
end

CommandHandlers["freeze"] = function(args)
    local target = args and args.target
    if not target then
        -- freeze self
        local char = LocalPlayer.Character
        if char then
            local root = char:FindFirstChild("HumanoidRootPart")
            if root then root.Anchored = not root.Anchored end
        end
        return
    end
    -- freeze target (only works if you can access their character)
    local player = findPlayer(target)
    if not player then return false, "player not found" end
    local char = player.Character
    if char then
        local root = char:FindFirstChild("HumanoidRootPart")
        if root then root.Anchored = true end
    end
end

CommandHandlers["bringall"] = function(args)
    local myChar = LocalPlayer.Character
    if not myChar then return false, "no character" end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return false, "no root" end
    -- Note: only works in games without server-side anti-exploit
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local root = p.Character:FindFirstChild("HumanoidRootPart")
            if root then
                pcall(function() root.CFrame = myRoot.CFrame + Vector3.new(math.random(-5,5), 0, math.random(-5,5)) end)
            end
        end
    end
    log("BRINGALL executed")
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  COMMAND EXECUTOR
-- ═══════════════════════════════════════════════════════════════════════════════

local function executeCommand(data)
    local cmd = data.command
    local args = data.args or {}
    local id = data.id

    log(string.format("Processing #%s: %s", tostring(id), tostring(cmd)))

    local handler = CommandHandlers[cmd]
    if not handler then
        log("Unknown command: " .. tostring(cmd), "WARN")
        catbasePatch(COMMAND_PATH, {
            status = "error",
            error = "unknown command: " .. tostring(cmd),
            executedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        })
        return
    end

    local ok, result, errMsg = pcall(function()
        return handler(args)
    end)

    if ok then
        local patchData = {
            status = "done",
            executedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }
        if result == false then
            patchData.status = "error"
            patchData.error = errMsg or "handler error"
        end
        catbasePatch(COMMAND_PATH, patchData)
    else
        catbasePatch(COMMAND_PATH, {
            status = "error",
            error = tostring(result),
            executedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        })
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  MAIN
-- ═══════════════════════════════════════════════════════════════════════════════

local function main()
    log("CatControl Executor v4.0")
    log("Player: " .. USERNAME)
    log("")

    -- Register
    if not register() then
        task.wait(CONFIG.retryDelay)
        register()
    end
    notify("CatControl", "Online: " .. USERNAME, 5)

    -- Init command slot
    local existing = catbaseGet(COMMAND_PATH)
    local lastId = 0
    if existing and type(existing) == "table" and existing.id then
        lastId = tonumber(existing.id) or 0
    else
        catbasePut(COMMAND_PATH, { id = 0, command = "none", status = "init", issuedAt = os.date("!%Y-%m-%dT%H:%M:%SZ") })
    end

    task.spawn(heartbeat)
    setupAutoRejoin()

    pcall(function()
        game:BindToClose(function() setOffline() end)
    end)

    -- Poll loop
    local consecutiveErrors = 0
    while true do
        local ok, err = pcall(function()
            local data = catbaseGet(COMMAND_PATH)
            if not data or type(data) ~= "table" then
                consecutiveErrors = consecutiveErrors + 1
                if consecutiveErrors >= CONFIG.maxRetries then
                    task.wait(CONFIG.backoffDelay)
                    consecutiveErrors = 0
                end
                return
            end
            consecutiveErrors = 0
            local id = tonumber(data.id)
            if not id then return end
            if id > lastId then
                lastId = id
                if data.status == "cleared" then
                    log("Skipped cleared #" .. tostring(id))
                else
                    executeCommand(data)
                end
            end
        end)
        if not ok then
            consecutiveErrors = consecutiveErrors + 1
            if consecutiveErrors >= CONFIG.maxRetries then
                task.wait(CONFIG.backoffDelay)
                consecutiveErrors = 0
            else
                task.wait(CONFIG.retryDelay)
            end
        else
            task.wait(CONFIG.pollInterval)
        end
    end
end

task.spawn(main)
