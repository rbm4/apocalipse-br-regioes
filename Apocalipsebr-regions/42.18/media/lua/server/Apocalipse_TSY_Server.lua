--        __     __                   
-- _|_   (_ ||\/|__) /\ _ _ _ _|   _  
--  |    __)||  |__)/--|_| (_(_||_|/_ 
--                     |              
if not isServer() then
    return
end

local Apocalipse_TSY_MODULE = "Apocalipse_TSY"
local Apocalipse_TSY_CMD_REQUEST = "ScreamRequest"
local Apocalipse_TSY_CMD_BROADCAST = "Scream"

local Apocalipse_TSY_MaxSlots = 62
local Apocalipse_TSY_DefaultAlertRadius = 80
local Apocalipse_TSY_DefaultAlertEnabled = true
local Apocalipse_TSY_DefaultClusterRadius = 35
local Apocalipse_TSY_DefaultClusterCDHours = 0.01
local Apocalipse_TSY_DefaultMaxCluster = 1
local Apocalipse_TSY_MaxClusterEvents = 200

local Apocalipse_TSY_TickCounter = 0
local Apocalipse_TSY_Delayed = {}

local function Apocalipse_TSY_Delay(fn, delayTicks)
    if type(fn) ~= "function" then
        return
    end
    delayTicks = tonumber(delayTicks) or 1
    table.insert(Apocalipse_TSY_Delayed, {
        t = Apocalipse_TSY_TickCounter + delayTicks,
        fn = fn
    })
end

local function Apocalipse_TSY_OnTick()
    Apocalipse_TSY_TickCounter = Apocalipse_TSY_TickCounter + 1

    if #Apocalipse_TSY_Delayed == 0 then
        return
    end

    for i = #Apocalipse_TSY_Delayed, 1, -1 do
        local job = Apocalipse_TSY_Delayed[i]
        if job and job.t <= Apocalipse_TSY_TickCounter then
            table.remove(Apocalipse_TSY_Delayed, i)
            pcall(job.fn)
        end
    end
end

Events.OnTick.Add(Apocalipse_TSY_OnTick)

local function Apocalipse_TSY_GetSandbox()
    if SandboxVars and SandboxVars.Apocalipse_TSY then
        return SandboxVars.Apocalipse_TSY
    end
    return nil
end

local Apocalipse_TSY_NightThreshold = 0.5

local function Apocalipse_TSY_GetNightStrength()
    local cm = getClimateManager()
    if cm then
        return cm:getNightStrength()
    end
    return 0
end

local function Apocalipse_TSY_TimeAllowed()
    local vars = Apocalipse_TSY_GetSandbox()
    local mode = 0
    if vars and vars.TimeMode ~= nil then
        mode = vars.TimeMode
    end

    local nightStrength = Apocalipse_TSY_GetNightStrength()

    if mode == 1 and nightStrength > Apocalipse_TSY_NightThreshold then
        return false
    end
    if mode == 2 and nightStrength <= Apocalipse_TSY_NightThreshold then
        return false
    end
    return true
end

local Apocalipse_TSY_ClusterEvents = {}

local function Apocalipse_TSY_CanClusterScream(x, y, timeNow, vars)
    local radius = Apocalipse_TSY_DefaultClusterRadius
    local cdHours = Apocalipse_TSY_DefaultClusterCDHours
    local maxCount = Apocalipse_TSY_DefaultMaxCluster

    if vars then
        if vars.ClusterRadius and vars.ClusterRadius > 0 then
            radius = vars.ClusterRadius
        end
        if vars.ClusterCooldownHours and vars.ClusterCooldownHours > 0 then
            cdHours = vars.ClusterCooldownHours
        end
        if vars.MaxClusterScreams and vars.MaxClusterScreams > 0 then
            maxCount = vars.MaxClusterScreams
        end
    end

    for i = #Apocalipse_TSY_ClusterEvents, 1, -1 do
        local e = Apocalipse_TSY_ClusterEvents[i]
        if (timeNow - e.t) > cdHours then
            table.remove(Apocalipse_TSY_ClusterEvents, i)
        end
    end

    local rr = radius * radius
    local count = 0

    for i = 1, #Apocalipse_TSY_ClusterEvents do
        local e = Apocalipse_TSY_ClusterEvents[i]
        local dx = x - e.x
        local dy = y - e.y
        if (dx * dx + dy * dy) <= rr then
            count = count + 1
            if count >= maxCount then
                return false
            end
        end
    end

    return true
end

local function Apocalipse_TSY_RegisterClusterScream(x, y, timeNow)
    table.insert(Apocalipse_TSY_ClusterEvents, {
        x = x,
        y = y,
        t = timeNow
    })
    if #Apocalipse_TSY_ClusterEvents > Apocalipse_TSY_MaxClusterEvents then
        table.remove(Apocalipse_TSY_ClusterEvents, 1)
    end
end

local function Apocalipse_TSY_Broadcast(args)
    local players = getOnlinePlayers()
    if not players then
        return
    end

    for i = 0, players:size() - 1 do
        local p = players:get(i)
        sendServerCommand(p, Apocalipse_TSY_MODULE, Apocalipse_TSY_CMD_BROADCAST, args)
    end
end

local function Apocalipse_TSY_PullHorde(player, x, y, vars)
    local enabled = Apocalipse_TSY_DefaultAlertEnabled
    local radius = Apocalipse_TSY_DefaultAlertRadius

    if vars then
        if vars.AlertNearbyZombies ~= nil then
            enabled = vars.AlertNearbyZombies
        end
        if vars.AlertRadius and vars.AlertRadius > 0 then
            radius = vars.AlertRadius
        end
    end

    if not enabled or radius <= 0 then
        return
    end

    local function pulse()
        addSound(player, x, y, 0, radius, radius)
    end

    pulse()
    Apocalipse_TSY_Delay(pulse, 20)
    Apocalipse_TSY_Delay(pulse, 40)
    Apocalipse_TSY_Delay(pulse, 60)
    Apocalipse_TSY_Delay(pulse, 80)
end

local function Apocalipse_TSY_OnClientCommand(module, command, player, args)
    if module ~= Apocalipse_TSY_MODULE then
        return
    end
    if command ~= Apocalipse_TSY_CMD_REQUEST then
        return
    end
    if not player or not args then
        return
    end

    if not Apocalipse_TSY_TimeAllowed() then
        return
    end

    local x = tonumber(args.x)
    local y = tonumber(args.y)
    local voiceIndex = tonumber(args.voiceIndex)
    local screamType = tostring(args.screamType or "far") -- "far" | "near" | "chase"

    if not x or not y then
        return
    end
    if not voiceIndex or voiceIndex < 1 or voiceIndex > Apocalipse_TSY_MaxSlots then
        return
    end

    local vars = Apocalipse_TSY_GetSandbox()
    local timeNow = getGameTime():getWorldAgeHours()

    if not Apocalipse_TSY_CanClusterScream(x, y, timeNow, vars) then
        return
    end

    Apocalipse_TSY_RegisterClusterScream(x, y, timeNow)

    Apocalipse_TSY_PullHorde(player, x, y, vars)

    Apocalipse_TSY_Broadcast({
        x = x,
        y = y,
        z = 0,
        voiceIndex = voiceIndex,
        screamType = screamType
    })
end

Events.OnClientCommand.Add(Apocalipse_TSY_OnClientCommand)