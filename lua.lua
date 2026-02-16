--[[
    CatControl Executor v3.0 — Auto-Register + Auto-Rejoin

    - Registers with Catbase using LocalPlayer.Name
    - Heartbeat keeps status alive
    - Polls per-user command path
    - Auto-rejoins if kicked from server
    - Skips "cleared" commands (stale pending)

    Designed for exploit executors (Solara, Synapse, Fluxus, etc.)
]]

-- ═══════════════════════════════════════════════════════════════════════════════
--  CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════════════

local CONFIG = {
    catbaseUrl = "https://catbase.catapis.uk",
    apiKey     = "0bdfcf7e815ae951f75a66a475feb6ed4b723b81ebd9ef473a761b99cc9d4f6e",
    database   = "roblox_control",

    pollInterval      = 2,       -- seconds between command polls
    heartbeatInterval = 15,      -- seconds between heartbeats
    retryDelay        = 5,       -- seconds to wait after an error
    maxRetries        = 3,       -- consecutive errors before backing off
    backoffDelay      = 15,      -- seconds to wait after maxRetries errors

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

local LocalPlayer = Players.LocalPlayer

-- ═══════════════════════════════════════════════════════════════════════════════
--  PER-USER PATHS  (derived from the Roblox username)
-- ═══════════════════════════════════════════════════════════════════════════════

local USERNAME      = LocalPlayer.Name
local EXECUTOR_PATH = "executors/" .. USERNAME
local COMMAND_PATH  = "commands/" .. USERNAME
local LOG_PATH      = "logs/" .. USERNAME

-- ═══════════════════════════════════════════════════════════════════════════════
--  HTTP ABSTRACTION  (works across most executors)
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
        error("No HTTP request function found — your executor may not support HTTP requests")
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
    local ok, result = pcall(function()
        return HttpService:JSONDecode(str)
    end)
    if ok then return result end
    return nil
end

local function jsonEncode(tbl)
    local ok, result = pcall(function()
        return HttpService:JSONEncode(tbl)
    end)
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
            Url = url,
            Method = "GET",
            Headers = {
                ["X-API-Key"] = CONFIG.apiKey,
                ["Content-Type"] = "application/json",
            },
        })
    end)

    if not ok then
        log("GET request failed: " .. tostring(response), "ERROR")
        return nil
    end

    if response.StatusCode ~= 200 then
        log("GET " .. path .. " → " .. tostring(response.StatusCode), "WARN")
        return nil
    end

    return jsonDecode(response.Body)
end

local function catbasePut(path, data)
    local url = string.format("%s/db/%s/%s", CONFIG.catbaseUrl, CONFIG.database, path)
    local body = jsonEncode(data)

    local ok, response = pcall(function()
        return httpRequest({
            Url = url,
            Method = "PUT",
            Headers = {
                ["X-API-Key"] = CONFIG.apiKey,
                ["Content-Type"] = "application/json",
            },
            Body = body,
        })
    end)

    if not ok then
        log("PUT request failed: " .. tostring(response), "ERROR")
        return false
    end

    return response.StatusCode == 200
end

local function catbasePatch(path, data)
    local url = string.format("%s/db/%s/%s", CONFIG.catbaseUrl, CONFIG.database, path)
    local body = jsonEncode(data)

    local ok, response = pcall(function()
        return httpRequest({
            Url = url,
            Method = "PATCH",
            Headers = {
                ["X-API-Key"] = CONFIG.apiKey,
                ["Content-Type"] = "application/json",
            },
            Body = body,
        })
    end)

    if not ok then
        log("PATCH request failed: " .. tostring(response), "ERROR")
        return false
    end

    return response.StatusCode == 200
end

local function catbasePost(path, data)
    local url = string.format("%s/db/%s/%s", CONFIG.catbaseUrl, CONFIG.database, path)
    local body = jsonEncode(data)

    local ok, response = pcall(function()
        return httpRequest({
            Url = url,
            Method = "POST",
            Headers = {
                ["X-API-Key"] = CONFIG.apiKey,
                ["Content-Type"] = "application/json",
            },
            Body = body,
        })
    end)

    if not ok then
        log("POST request failed: " .. tostring(response), "ERROR")
        return false
    end

    return response.StatusCode == 200
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  REGISTRATION & HEARTBEAT
-- ═══════════════════════════════════════════════════════════════════════════════

local function getGameName()
    local name = "Unknown"
    pcall(function()
        local info = MarketplaceService:GetProductInfo(game.PlaceId)
        if info and info.Name then
            name = info.Name
        end
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
        log("  Game: " .. gameName .. " (PlaceId: " .. tostring(game.PlaceId) .. ")")
        log("  Server: " .. tostring(game.JobId))
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
    -- Detect kick / disconnect and auto-rejoin the same place
    local placeId = game.PlaceId

    -- Method 1: CoreGui error prompt ("You have been kicked")
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

    -- Method 2: TeleportService failure callback
    pcall(function()
        TeleportService.TeleportInitFailed:Connect(function(player, result)
            if player == LocalPlayer then
                log("Teleport failed (" .. tostring(result) .. ") — retrying in 5s...", "WARN")
                task.wait(5)
                TeleportService:Teleport(placeId, LocalPlayer)
            end
        end)
    end)

    -- Method 3: Player.OnTeleport status
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

CommandHandlers["leave"] = function(args)
    log("Executing: LEAVE")
    notify("CatControl", "Leaving game...", 2)
    setOffline()
    task.wait(0.5)
    game:Shutdown()
end

CommandHandlers["reset"] = function(args)
    log("Executing: RESET")
    notify("CatControl", "Resetting character...", 2)
    local character = LocalPlayer.Character
    if character then
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid.Health = 0
        else
            character:BreakJoints()
        end
    end
end

CommandHandlers["rejoin"] = function(args)
    log("Executing: REJOIN")
    notify("CatControl", "Rejoining server...", 2)
    setOffline()
    task.wait(0.5)
    TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
end

CommandHandlers["serverhop"] = function(args)
    log("Executing: SERVER HOP")
    notify("CatControl", "Hopping to new server...", 2)
    setOffline()
    task.wait(0.5)
    TeleportService:Teleport(game.PlaceId, LocalPlayer)
end

CommandHandlers["teleport"] = function(args)
    local placeId = args and tonumber(args.placeId)
    if not placeId then
        log("teleport: missing placeId arg", "ERROR")
        return false, "missing placeId"
    end
    log("Executing: TELEPORT to " .. tostring(placeId))
    notify("CatControl", "Teleporting to " .. tostring(placeId), 2)
    setOffline()
    task.wait(0.5)
    TeleportService:Teleport(placeId, LocalPlayer)
end

CommandHandlers["exec"] = function(args)
    local code = args and args.code
    if not code or code == "" then
        log("exec: no code provided", "ERROR")
        return false, "no code"
    end
    log("Executing: EXEC (" .. #code .. " chars)")

    local fn, compileErr = loadstring(code)
    if not fn then
        log("exec compile error: " .. tostring(compileErr), "ERROR")
        return false, "compile error: " .. tostring(compileErr)
    end

    local ok, runErr = pcall(fn)
    if not ok then
        log("exec runtime error: " .. tostring(runErr), "ERROR")
        return false, "runtime error: " .. tostring(runErr)
    end

    return true
end

CommandHandlers["print"] = function(args)
    local msg = args and args.message or args and args.value or "hello from CatControl"
    log("PRINT: " .. tostring(msg))
    notify("CatControl", tostring(msg), 5)
end

CommandHandlers["chat"] = function(args)
    local msg = args and (args.message or args.value)
    if not msg then
        return false, "no message"
    end
    log("Executing: CHAT → " .. tostring(msg))

    local ok = pcall(function()
        local tcs = game:GetService("TextChatService")
        local channel = tcs.TextChannels:FindFirstChild("RBXGeneral")
        if channel then
            channel:SendAsync(tostring(msg))
        end
    end)

    if not ok then
        pcall(function()
            game:GetService("ReplicatedStorage")
                .DefaultChatSystemChatEvents
                .SayMessageRequest
                :FireServer(tostring(msg), "All")
        end)
    end
end

CommandHandlers["jump"] = function(args)
    log("Executing: JUMP")
    local character = LocalPlayer.Character
    if character then
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
end

CommandHandlers["walkto"] = function(args)
    local x = args and tonumber(args.x) or 0
    local y = args and tonumber(args.y) or 0
    local z = args and tonumber(args.z) or 0
    log(string.format("Executing: WALKTO (%s, %s, %s)", x, y, z))

    local character = LocalPlayer.Character
    if character then
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid:MoveTo(Vector3.new(x, y, z))
        end
    end
end

CommandHandlers["ping"] = function(args)
    log("PING received — executor alive")
    notify("CatControl", "Pong! Executor is running", 3)
end

CommandHandlers["none"] = function(args)
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════════
--  COMMAND EXECUTOR
-- ═══════════════════════════════════════════════════════════════════════════════

local function executeCommand(data)
    local cmd = data.command
    local args = data.args or {}
    local id = data.id

    log(string.format("Processing command #%s: %s", tostring(id), tostring(cmd)))

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
            patchData.error = errMsg or "handler returned false"
        end
        catbasePatch(COMMAND_PATH, patchData)
        log(string.format("Command #%s completed (status=%s)", tostring(id), patchData.status))
    else
        log(string.format("Command #%s failed: %s", tostring(id), tostring(result)), "ERROR")
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
    log("╔══════════════════════════════════════╗")
    log("║       CatControl Executor v3.0       ║")
    log("║    Auto-Register + Auto-Rejoin       ║")
    log("╚══════════════════════════════════════╝")
    log("")
    log("Player: " .. USERNAME .. " (ID: " .. tostring(LocalPlayer.UserId) .. ")")
    log("Catbase: " .. CONFIG.catbaseUrl)
    log("Database: " .. CONFIG.database)
    log("")

    -- ── Register with Catbase ──
    log("Registering with Catbase...")
    if not register() then
        log("Retrying registration in " .. CONFIG.retryDelay .. "s...", "WARN")
        task.wait(CONFIG.retryDelay)
        if not register() then
            log("Registration failed after retry — continuing anyway", "ERROR")
        end
    end

    notify("CatControl", "Registered as " .. USERNAME, 5)

    -- ── Initialize per-user command slot ──
    local existing = catbaseGet(COMMAND_PATH)
    local lastId = 0
    if existing and type(existing) == "table" and existing.id then
        lastId = tonumber(existing.id) or 0
        log("Synced — last command ID: " .. tostring(lastId))
    else
        catbasePut(COMMAND_PATH, {
            id = 0,
            command = "none",
            status = "init",
            issuedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        })
        log("Initialized command slot")
    end

    -- ── Start heartbeat coroutine ──
    task.spawn(heartbeat)
    log("Heartbeat started (every " .. CONFIG.heartbeatInterval .. "s)")

    -- ── Auto-rejoin on kick ──
    setupAutoRejoin()

    -- ── Try to mark offline on game close ──
    pcall(function()
        game:BindToClose(function()
            setOffline()
        end)
    end)

    log("")
    log("Polling for commands... (every " .. CONFIG.pollInterval .. "s)")

    -- ── Poll loop ──
    local consecutiveErrors = 0

    while true do
        local ok, err = pcall(function()
            local data = catbaseGet(COMMAND_PATH)

            if not data or type(data) ~= "table" then
                consecutiveErrors = consecutiveErrors + 1
                if consecutiveErrors >= CONFIG.maxRetries then
                    log("Too many errors — backing off for " .. CONFIG.backoffDelay .. "s", "WARN")
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
                -- Skip commands the bot already cleared (stale pending)
                if data.status == "cleared" then
                    log("Skipped cleared command #" .. tostring(id))
                else
                    executeCommand(data)
                end
            end
        end)

        if not ok then
            log("Poll loop error: " .. tostring(err), "ERROR")
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

-- ═══════════════════════════════════════════════════════════════════════════════
--  LAUNCH
-- ═══════════════════════════════════════════════════════════════════════════════

task.spawn(main)
