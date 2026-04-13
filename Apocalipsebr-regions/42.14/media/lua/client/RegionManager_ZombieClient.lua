if isServer() then
    return
end

require "RegionManager_Config"
require "RegionManager_ClientTick"
require "RegionManager_ZombieShared"
require "RegionManager_ZombieModules"
require "RegionManager_ZombieModuleClient"

local sandboxOptions = getSandboxOptions()

-- ============================================================================
-- SpeedTracker: flat array of zombies with speed overrides for round-robin
-- revalidation. Replaces the full zombie list scan with O(batch) per tick.
-- ============================================================================
local SpeedTracker = {
    entries = {},   -- { [i] = { onlineID=number, zombieRef=IsoZombie } }
    count = 0,
    cursor = 0,     -- current round-robin position (0-based)
    BATCH_SIZE = 8, -- zombies to check per tick interval
}

--- Add a zombie to the speed tracker.
---@param zombie IsoZombie
function SpeedTracker.add(zombie)
    local id = zombie:getOnlineID()
    -- Avoid duplicates
    for i = 1, SpeedTracker.count do
        if SpeedTracker.entries[i] and SpeedTracker.entries[i].onlineID == id then
            SpeedTracker.entries[i].zombieRef = zombie
            return
        end
    end
    SpeedTracker.count = SpeedTracker.count + 1
    SpeedTracker.entries[SpeedTracker.count] = {
        onlineID = id,
        zombieRef = zombie,
    }
end

--- Remove a zombie from the speed tracker by onlineID.
---@param onlineID number
function SpeedTracker.remove(onlineID)
    for i = 1, SpeedTracker.count do
        if SpeedTracker.entries[i] and SpeedTracker.entries[i].onlineID == onlineID then
            -- Swap with last entry to avoid holes
            SpeedTracker.entries[i] = SpeedTracker.entries[SpeedTracker.count]
            SpeedTracker.entries[SpeedTracker.count] = nil
            SpeedTracker.count = SpeedTracker.count - 1
            if SpeedTracker.cursor >= SpeedTracker.count then
                SpeedTracker.cursor = 0
            end
            return
        end
    end
end

--- Round-robin revalidation: check BATCH_SIZE entries per call.
function SpeedTracker.revalidateBatch()
    if SpeedTracker.count == 0 then
        return
    end
    local checked = 0
    local startCursor = SpeedTracker.cursor
    while checked < SpeedTracker.BATCH_SIZE and SpeedTracker.count > 0 do
        SpeedTracker.cursor = (SpeedTracker.cursor % SpeedTracker.count) + 1
        local entry = SpeedTracker.entries[SpeedTracker.cursor]
        if entry then
            local z = entry.zombieRef
            if z and not z:isDead() then
                RegionManager.Shared.RevalidateZombieSpeed(z, sandboxOptions)
            else
                -- Zombie is dead or nil, remove from tracker
                SpeedTracker.entries[SpeedTracker.cursor] = SpeedTracker.entries[SpeedTracker.count]
                SpeedTracker.entries[SpeedTracker.count] = nil
                SpeedTracker.count = SpeedTracker.count - 1
                if SpeedTracker.count == 0 then
                    SpeedTracker.cursor = 0
                    break
                end
                -- Don't increment checked — we need to re-check this slot
                -- But do avoid infinite loop if all entries are dead
                if SpeedTracker.cursor > SpeedTracker.count then
                    SpeedTracker.cursor = 0
                end
            end
        end
        checked = checked + 1
        -- Full cycle: don't loop more than once around
        if SpeedTracker.cursor == startCursor then
            break
        end
    end
end

-- ============================================================================
-- PendingZombies: queue of newly-spawned zombies awaiting onlineID assignment.
-- OnZombieCreate fires BEFORE the server assigns onlineID, so we defer
-- processing to the next tick when the ID is available.
-- ============================================================================
local PendingZombies = {
    queue = {},   -- { [i] = IsoZombie ref }
    count = 0,
}

--- OnZombieCreate handler: queue newly spawned remote zombies for processing.
--- Do NOT read getOnlineID() here — it is not set yet at event time.
---@param zombie IsoZombie
local function onZombieCreate(zombie)
    if not zombie then return end
    -- Process all zombies on the client
    PendingZombies.count = PendingZombies.count + 1
    PendingZombies.queue[PendingZombies.count] = zombie
end
Events.OnZombieCreate.Add(onZombieCreate)

-- ============================================================================
-- Decode compact bit-encoded payload from server (Protocol v2)
-- Format: "BBBBBBBBBSXXXXXSYYYYYMM" (23 chars, fixed length)
--   B(9):  28 boolean flags packed as a zero-padded decimal integer
--   S(1):  coordinate sign digit (0 = negative, 1 = positive)
--   X(5):  absolute X coordinate, zero-padded
--   Y(5):  absolute Y coordinate, zero-padded
--   M(2):  maxHits for tough zombies, zero-padded
-- Bit layout (LSB first):
--   0:isSprinter  1:isShambler      2:hawkVision      3:badVision
--   4:normalVision 5:poorVision     6:randomVision    7:goodHearing
--   8:badHearing   9:pinpointHearing 10:normalHearing 11:poorHearing
--  12:randomHearing 13:isResistant  14:isTough        15:isNormalToughness
--  16:isFragile    17:isRandomToughness 18:isSuperhuman 19:isNormalToughness2
--  20:isWeak       21:isRandomToughness2 22:hasNavigation 23:hasMemoryLong
--  24:hasMemoryNormal 25:hasMemoryShort 26:hasMemoryNone 27:hasMemoryRandom
-- ============================================================================
local function decodeConfirmPayload(args)
    local r = args.r
    local bits    = tonumber(string.sub(r, 1, 9))   or 0
    local xSign   = tonumber(string.sub(r, 10, 10)) or 1
    local xAbs    = tonumber(string.sub(r, 11, 15)) or 0
    local ySign   = tonumber(string.sub(r, 16, 16)) or 1
    local yAbs    = tonumber(string.sub(r, 17, 21)) or 0
    local maxHits = tonumber(string.sub(r, 22, 23)) or RegionManager.Shared.DEFAULT_MAX_HITS

    local x = xSign == 1 and xAbs or -xAbs
    local y = ySign == 1 and yAbs or -yAbs

    local function hasBit(pos)
        return math.floor(bits / (2 ^ pos)) % 2 == 1
    end

    return {
        zombieID           = args.z,
        isSprinter         = hasBit(0),
        isShambler         = hasBit(1),
        hawkVision         = hasBit(2),
        badVision          = hasBit(3),
        normalVision       = hasBit(4),
        poorVision         = hasBit(5),
        randomVision       = hasBit(6),
        goodHearing        = hasBit(7),
        badHearing         = hasBit(8),
        pinpointHearing    = hasBit(9),
        normalHearing      = hasBit(10),
        poorHearing        = hasBit(11),
        randomHearing      = hasBit(12),
        isResistant        = hasBit(13),
        isTough            = hasBit(14),
        isNormalToughness  = hasBit(15),
        isFragile          = hasBit(16),
        isRandomToughness  = hasBit(17),
        isSuperhuman       = hasBit(18),
        isNormalToughness2 = hasBit(19),
        isWeak             = hasBit(20),
        isRandomToughness2 = hasBit(21),
        hasNavigation      = hasBit(22),
        hasMemoryLong      = hasBit(23),
        hasMemoryNormal    = hasBit(24),
        hasMemoryShort     = hasBit(25),
        hasMemoryNone      = hasBit(26),
        hasMemoryRandom    = hasBit(27),
        x       = x,
        y       = y,
        maxHits = maxHits,
    }
end

-- Handle server commands
---@param module string
---@param command string
---@param args table
local function Apocalipse_TSY_OnServerCommand(module, command, args)
    if module ~= "Apocalipse_TSY" then
        return
    end

    -- ========================================================================
    -- Handle tough zombie hit broadcast from server
    -- ========================================================================
    if command == "ToughZombieHit" then
        local zombieID = args.zombieID
        local hitCounter = args.hitCounter
        local maxHits = args.maxHits
        local isExhausted = args.isExhausted
        local zombieX = args.x
        local zombieY = args.y

        local player = getPlayer()
        if not player then
            return
        end
        local playerX = player:getX()
        local playerY = player:getY()

        -- Check distance between player and zombie
        local distance = math.sqrt((playerX - zombieX) ^ 2 + (playerY - zombieY) ^ 2)
        if distance > 200 then
            return
        end
        RegionManager.Shared.ApplyToughZombieHit(zombieID, hitCounter, maxHits, isExhausted)
        return
    end

    if command == "ConfirmZombie" then
        local player = getPlayer()
        if not player then
            return
        end

        -- Decode compact bit-encoded payload (Protocol v2)
        local data = decodeConfirmPayload(args)
        local zombieID = data.zombieID

        local cell = player:getCell()
        if not cell then
            return
        end

        local zombieList = cell:getZombieList()
        if not zombieList then
            return
        end
        -- Find zombie and apply all properties using shared function
        for i = 0, zombieList:size() - 1 do
            local zombie = zombieList:get(i)
            if zombie and not zombie:isDead() and zombie:getOnlineID() == zombieID then
                -- Pass module ID into data so ServerSideProperties can use it for kill bonus
                if args.m then
                    data.moduleId = args.m
                end

                -- Apply all server-determined properties using the shared function
                RegionManager.Shared.ServerSideProperties(zombie, data, sandboxOptions)

                -- Cache the raw payload for revalidation without server roundtrip
                local modData = zombie:getModData()
                modData.Apocalipse_TSY_CachedPayload = args.r
                modData.Apocalipse_TSY_CachedMaxHits = data.maxHits

                -- Add to SpeedTracker if speed override was applied
                if data.isSprinter or data.isShambler then
                    SpeedTracker.add(zombie)
                end

                if data.isSprinter then
                    print("  -> Converted to Sprinter (lunger=" .. tostring(zombie.lunger) .. ")")
                end
                if data.isShambler then
                    print("  -> Converted to Shambler")
                end

                -- Module zombie: initialize client-side sound/behavior tracking
                if args.m then
                    modData.Apocalipse_TSY_IsModuleZombie = true
                    RegionManager.ZombieModuleClient.initZombie(zombie, args.m)
                    -- Apply bossHealth override if the module defines it
                    local moduleDef = RegionManager.ZombieModules.getById(args.m)
                    if moduleDef and moduleDef.stats and moduleDef.stats.bossHealth then
                        if zombie:getHealth() < moduleDef.stats.bossHealth then
                            zombie:setHealth(moduleDef.stats.bossHealth)
                        end
                    end
                end

                break
            end
        end
    end
end

Events.OnServerCommand.Add(Apocalipse_TSY_OnServerCommand)

-- ============================================================================
-- Process pending zombies from OnZombieCreate queue.
-- Only iterates the small pending queue (~0-20), NOT the full cell zombie list.
-- Zombies whose onlineID is not yet assigned are kept for the next tick.
-- ============================================================================
local function Apocalipse_TSY_ProcessPending()
    if PendingZombies.count == 0 then
        return
    end

    local player = getPlayer()
    if not player then
        return
    end

    -- Zone data not ready yet — request it and bail
    if not (RegionManager and RegionManager.Client and RegionManager.Client.zoneData) then
        sendClientCommand("RegionManager", "RequestAllBoundaries", {})
        return
    end

    local proposals = {}

    -- Iterate backwards for safe removal during iteration
    for i = PendingZombies.count, 1, -1 do
        local zombie = PendingZombies.queue[i]

        -- Remove dead/nil entries
        if not zombie or zombie:isDead() then
            PendingZombies.queue[i] = PendingZombies.queue[PendingZombies.count]
            PendingZombies.queue[PendingZombies.count] = nil
            PendingZombies.count = PendingZombies.count - 1
        else
            local onlineID = zombie:getOnlineID()

            if onlineID >= 0 then
                local data = zombie:getModData()

                -- Skip if already processed (e.g. from a prior ConfirmZombie)
                if data.Apocalipse_TSY_Processed then
                    PendingZombies.queue[i] = PendingZombies.queue[PendingZombies.count]
                    PendingZombies.queue[PendingZombies.count] = nil
                    PendingZombies.count = PendingZombies.count - 1
                else
                    data.Apocalipse_TSY_Processed = true

                    local persistentID = RegionManager.Shared.GetZombiePersistentID(zombie)

                    table.insert(proposals, {
                        zombieID = onlineID,
                        persistentID = persistentID,
                        x = zombie:getX(),
                        y = zombie:getY(),
                        outfitName = zombie:getOutfitName(),
                    })

                    -- Remove from queue (swap with last)
                    PendingZombies.queue[i] = PendingZombies.queue[PendingZombies.count]
                    PendingZombies.queue[PendingZombies.count] = nil
                    PendingZombies.count = PendingZombies.count - 1
                end
            end
            -- else: onlineID < 0 means server hasn't assigned it yet — keep in queue
        end
    end

    -- Send requests to server for new zombie information
    if #proposals > 0 then
        sendClientCommand(player, "Apocalipse_TSY", "RequestZombieInfo", {
            zombies = proposals
        })
    end
end

-- ============================================================================
-- Register two independent tick modules with the central dispatcher:
--   1. SpawnProcessor  — drains the pending queue (new zombie arrivals)
--   2. SpeedRevalidation — round-robin checks for ownership-transfer drift
-- ============================================================================

---@type TickModuleDef
local spawnProcessorModule = {
    name = "Apocalipse_TSY_SpawnProcessor",
    onTick = function(player, currentZones)
        Apocalipse_TSY_ProcessPending()
    end
}
RegionManager.ClientTick.registerModule(spawnProcessorModule)

---@type TickModuleDef
local speedRevalidationModule = {
    name = "Apocalipse_TSY_SpeedRevalidation",
    onTick = function(player, currentZones)
        SpeedTracker.revalidateBatch()
    end
}
RegionManager.ClientTick.registerModule(speedRevalidationModule)

-- ============================================================================
-- Zombie death handler
-- ============================================================================
local function onZombieDead(zombie)
    if not zombie then
        return
    end

    -- Clean up SpeedTracker entry
    SpeedTracker.remove(zombie:getOnlineID())

    local player = getPlayer()
    if not player then
        return
    end

    local attacker = zombie:getAttackedBy()
    if not attacker or attacker ~= player then
        return
    end

    local modData = zombie:getModData()
    local killBonus = modData.Apocalipse_TSY_KillBonus or 0
    -- Base kill = 1, plus difficulty bonus (already clamped to >= 0)
    local totalKillValue = 1 + killBonus
    ZKC_Main.recordKill(player, totalKillValue)
    if killBonus > 0 then
        print("Apocalipse_TSY: Player earned +" .. killBonus .. " extra kill points (total " .. totalKillValue .. ")")
    end
end
Events.OnZombieDead.Add(onZombieDead)
