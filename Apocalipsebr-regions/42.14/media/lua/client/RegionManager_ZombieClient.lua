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
    entries = {}, -- { [i] = { onlineID=number, zombieRef=IsoZombie } }
    count = 0,
    cursor = 0, -- current round-robin position (0-based)
    BATCH_SIZE = 1 -- one zombie checked per tick; revalidation is a
                   -- background drift check, no need for bursts.
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
        zombieRef = zombie
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
                -- Don't increment checked - we need to re-check this slot
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
    queue = {}, -- { [i] = IsoZombie ref }
    count = 0
}

-- ============================================================================
-- PendingConfirmations: O(1) lookup map for ConfirmZombie responses.
-- Keyed by PersistentID (stable across ownership transfers).
-- If a new zombie shares a PersistentID but is >500 tiles away, the old
-- entry is considered stale (recycled zombie) and gets replaced.
-- ============================================================================
local PendingConfirmations = {} -- { [persistentID] = { zombieRef, x, y, onlineID } }
local PendingIDIndex = {} -- { [onlineID] = persistentID } reverse lookup

-- ============================================================================
-- DecidedByPID: client-side cache of server decisions keyed by persistentID.
--
-- Why not onlineID: onlineID gets RECYCLED across chunk unload/reload cycles,
-- so it cannot be used as a stability key. That's exactly why persistentID
-- was introduced (GetZombiePersistentID -> "<persistentOutfitID>_<female>",
-- stable and shared by every zombie in the same "class").
--
-- How this is used:
--   * On ConfirmZombie / ConfirmZombieBatch we store the decoded decision.
--   * When a new IsoZombie spawns locally (OnZombieCreate), ProcessPending
--     looks up DecidedByPID[pid]. If present, we skip sending ANY request
--     to the server for that zombie -- the decision is already known.
--   * We still only call ServerSideProperties if the zombie's LIVE state
--     diverges from the cached decision (speedType / toughness modData).
--     If it already matches we just drop the entry -- zero Java cost.
--
-- The cache is keyed by the persistent CLASS-level ID, so a single entry
-- handles every zombie with the same outfit+gender. Typical population is
-- a few dozen entries per session.
-- ============================================================================
local DecidedByPID = {} -- { [persistentID] = { data=<decoded>, raw=<string>, moduleId=<string|nil> } }

--- Return true if the zombie's current live state already matches the
--- cached decision, meaning ServerSideProperties would be a no-op.
---@param zombie IsoZombie
---@param data table decoded decision
---@return boolean
local function zombieMatchesDecision(zombie, data)
    -- Speed: the only observable live field we can read cheaply.
    -- Constants: 1=sprinter, 2=fast shambler, 3=shambler, -1=unset.
    local speedType = zombie.speedType
    if data.isSprinter then
        if speedType ~= 1 or not zombie.lunger then
            return false
        end
    elseif data.isShambler then
        if speedType ~= 3 then
            return false
        end
    end

    -- Toughness: we stamp modData at apply time; if it's missing or
    -- wrong, we need to re-apply.
    local modData = zombie:getModData()
    local tt = modData.Apocalipse_TSY_ToughnessType
    if data.isTough and tt ~= "tough" then return false end
    if data.isFragile and tt ~= "fragile" then return false end
    if data.isNormalToughness and tt ~= "normal" then return false end

    -- KillBonus stamp is cheap enough to verify presence
    if (data.killBonusPrecomputed ~= nil or data.moduleId)
       and modData.Apocalipse_TSY_KillBonus == nil then
        return false
    end

    return true
end

--- OnZombieCreate handler: queue newly spawned remote zombies for processing.
--- Do NOT read getOnlineID() here - it is not set yet at event time.
---@param zombie IsoZombie
local function onZombieCreate(zombie)
    if not zombie then
        return
    end
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
    local bits = tonumber(string.sub(r, 1, 9)) or 0
    local xSign = tonumber(string.sub(r, 10, 10)) or 1
    local xAbs = tonumber(string.sub(r, 11, 15)) or 0
    local ySign = tonumber(string.sub(r, 16, 16)) or 1
    local yAbs = tonumber(string.sub(r, 17, 21)) or 0
    local maxHits = tonumber(string.sub(r, 22, 23)) or RegionManager.Shared.DEFAULT_MAX_HITS

    local x = xSign == 1 and xAbs or -xAbs
    local y = ySign == 1 and yAbs or -yAbs

    local function hasBit(pos)
        return math.floor(bits / (2 ^ pos)) % 2 == 1
    end

    return {
        zombieID = args.z,
        isSprinter = hasBit(0),
        isShambler = hasBit(1),
        hawkVision = hasBit(2),
        badVision = hasBit(3),
        normalVision = hasBit(4),
        poorVision = hasBit(5),
        randomVision = hasBit(6),
        goodHearing = hasBit(7),
        badHearing = hasBit(8),
        pinpointHearing = hasBit(9),
        normalHearing = hasBit(10),
        poorHearing = hasBit(11),
        randomHearing = hasBit(12),
        isResistant = hasBit(13),
        isTough = hasBit(14),
        isNormalToughness = hasBit(15),
        isFragile = hasBit(16),
        isRandomToughness = hasBit(17),
        isSuperhuman = hasBit(18),
        isNormalToughness2 = hasBit(19),
        isWeak = hasBit(20),
        isRandomToughness2 = hasBit(21),
        hasNavigation = hasBit(22),
        hasMemoryLong = hasBit(23),
        hasMemoryNormal = hasBit(24),
        hasMemoryShort = hasBit(25),
        hasMemoryNone = hasBit(26),
        hasMemoryRandom = hasBit(27),
        x = x,
        y = y,
        maxHits = maxHits
    }
end

-- Handle server commands
---@param module string
---@param command string
---@param args table
-- ============================================================================
-- PendingApply: queue of confirmed zombies whose stats are pending client-side
-- application. Drained a few per tick to keep `makeInactive(true/false)` cost
-- (the dominant FPS hit per zombie) spread across frames.
-- ============================================================================
local PendingApply = { queue = {}, head = 1, tail = 0 }
local APPLY_PER_TICK = 1      -- normal steady-state drain rate
local APPLY_BURST_ALLOW = 1   -- one-shot larger drain right after queue empties
local pendingApplyBurstRemaining = APPLY_BURST_ALLOW

local function enqueueApply(zombie, data, raw, moduleId, zombieID)
    PendingApply.tail = PendingApply.tail + 1
    PendingApply.queue[PendingApply.tail] = {
        zombie   = zombie,
        data     = data,
        raw      = raw,
        moduleId = moduleId,
        zombieID = zombieID,
        -- Cache the pid at enqueue time; zombie may be gone by drain time
        pid      = RegionManager.Shared.GetZombiePersistentID(zombie),
    }
end

local function applyConfirmedZombie(entry)
    local zombie = entry.zombie
    if not zombie or zombie:isDead() or zombie:getOnlineID() ~= entry.zombieID then
        return
    end
    local data = entry.data

    -- Apply all server-determined properties using the shared function
    RegionManager.Shared.ServerSideProperties(zombie, data, sandboxOptions)

    -- Cache the raw payload for revalidation without server roundtrip
    local modData = zombie:getModData()
    modData.Apocalipse_TSY_CachedPayload = entry.raw
    modData.Apocalipse_TSY_CachedMaxHits = data.maxHits

    -- If this zombie belongs to a registered module, initialize client-side
    -- module tracking (sounds, AI redirect, convergence).
    if entry.moduleId then
        modData.Apocalipse_TSY_IsModuleZombie = true
        local initOpts = nil
        if data.isTough then
            local maxHits = data.maxHits or RegionManager.Shared.DEFAULT_MAX_HITS
            initOpts = {
                expectedToughness = {
                    type    = "tough",
                    maxHits = maxHits
                }
            }
        end
        RegionManager.ZombieModuleClient.initZombie(zombie, entry.moduleId, initOpts)
    end

    if data.isSprinter or data.isShambler then
        SpeedTracker.add(zombie)
    end

    -- Cache the decision keyed by persistentID (class-level, survives
    -- chunk unload/reload). Any later zombie sharing this PID will use
    -- this cached decision without hitting the server.
    if entry.pid then
        DecidedByPID[entry.pid] = {
            data     = data,
            raw      = entry.raw,
            moduleId = entry.moduleId,
        }
    end

    if data.isSprinter and zombie.lunger then
        print("  -> Converted to Sprinter (lunger=true)")
    elseif data.isShambler then
        print("  -> Converted to Shambler")
    end
end

local function drainPendingApply()
    if PendingApply.head > PendingApply.tail then
        -- Queue empty: replenish burst allowance for next wave
        pendingApplyBurstRemaining = APPLY_BURST_ALLOW
        return
    end
    local limit = APPLY_PER_TICK
    if pendingApplyBurstRemaining > limit then
        limit = pendingApplyBurstRemaining
    end
    local processed = 0
    while processed < limit and PendingApply.head <= PendingApply.tail do
        local entry = PendingApply.queue[PendingApply.head]
        PendingApply.queue[PendingApply.head] = nil
        PendingApply.head = PendingApply.head + 1
        processed = processed + 1
        applyConfirmedZombie(entry)
    end
    if pendingApplyBurstRemaining > 0 then
        pendingApplyBurstRemaining = pendingApplyBurstRemaining - processed
        if pendingApplyBurstRemaining < 0 then pendingApplyBurstRemaining = 0 end
    end
    -- Reset indices when fully drained to avoid unbounded index growth
    if PendingApply.head > PendingApply.tail then
        PendingApply.head = 1
        PendingApply.tail = 0
    end
end

--- Validate a ConfirmZombie payload and enqueue it onto PendingApply.
--- Consumes the matching PendingConfirmations/PendingIDIndex entries.
---@param args table The payload args from a ConfirmZombie / ConfirmZombieBatch item
local function processConfirmEntry(args)
    local data = decodeConfirmPayload(args)
    local zombieID = data.zombieID

    local persistentID = PendingIDIndex[zombieID]
    if not persistentID then
        return
    end

    local entry = PendingConfirmations[persistentID]
    if not entry then
        PendingIDIndex[zombieID] = nil
        return
    end

    local zombie = entry.zombieRef
    if not zombie or zombie:isDead() or zombie:getOnlineID() ~= zombieID then
        PendingConfirmations[persistentID] = nil
        PendingIDIndex[zombieID] = nil
        return
    end

    -- Consume the entry now; apply happens later during drain
    PendingConfirmations[persistentID] = nil
    PendingIDIndex[zombieID] = nil

    if args.m then data.moduleId = args.m end
    -- Server-precomputed killBonus (skips the 15-branch if-ladder in ServerSideProperties)
    if args.k ~= nil then data.killBonusPrecomputed = args.k end

    enqueueApply(zombie, data, args.r, args.m, zombieID)
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
        local persistentID = args.persistentID
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
        RegionManager.Shared.ApplyToughZombieHit(zombieID, persistentID, hitCounter, maxHits, isExhausted)
        return
    end

    if command == "ConfirmZombie" then
        if not getPlayer() then
            return
        end
        processConfirmEntry(args)
        return
    end

    if command == "ConfirmZombieBatch" then
        if not getPlayer() then
            return
        end
        local items = args and args.items
        if not items then
            return
        end
        for i = 1, #items do
            processConfirmEntry(items[i])
        end
        return
    end
end

Events.OnServerCommand.Add(Apocalipse_TSY_OnServerCommand)

--- Return true if the zone's broadcast payload exposes any non-zero
--- zombie-affecting property. Mirrors the fields serialised server-side
--- in the "AllZoneBoundaries" handler.
---@param zone table
---@return boolean
local function zoneAffectsZombies(zone)
    if not zone then
        return false
    end
    if (zone.sprinterChance or 0) > 0 then
        return true
    end
    if (zone.shamblerChance or 0) > 0 then
        return true
    end
    if (zone.hawkVisionChance or 0) > 0 then
        return true
    end
    if (zone.badVisionChance or 0) > 0 then
        return true
    end
    if (zone.goodHearingChance or 0) > 0 then
        return true
    end
    if (zone.badHearingChance or 0) > 0 then
        return true
    end
    if (zone.resistantChance or 0) > 0 then
        return true
    end
    return false
end

--- Return true if (x,y) is inside at least one zone that has any
--- zombie-affecting property set. Falls back to true when no zone data
--- is loaded yet so startup doesn't silently drop real spawns.
---@param zx number
---@param zy number
---@return boolean
local function isInZombieAffectingZone(zx, zy)
    if not hasZones then
        return true
    end
    -- Prefer the spatial grid (built when AllZoneBoundaries arrives) so
    -- we only scan zones bucketed near the zombie, not the full zone
    -- list per pending zombie per tick.
    local bucket = RegionManager.Client.getZonesAt and RegionManager.Client.getZonesAt(zx, zy) or nil
    if bucket then
        for i = 1, #bucket do
            local zone = bucket[i]
            local b = zone and zone.bounds
            if b and zx >= b.minX and zx <= b.maxX and zy >= b.minY and zy <= b.maxY then
                if zoneAffectsZombies(zone) then
                    return true
                end
            end
        end
        return false
    end
    -- Legacy linear fallback if the grid hasn't been built yet.
    for i = 1, #zoneList do
        local zone = zoneList[i]
        local b = zone and zone.bounds
        if b and zx >= b.minX and zx <= b.maxX and zy >= b.minY and zy <= b.maxY then
            if zoneAffectsZombies(zone) then
                return true
            end
        end
    end
    return false
end

-- ============================================================================
-- Process pending zombies from OnZombieCreate queue.
--
-- Pacing strategy (rewritten from the original loop-everything-per-tick):
--
--   * At most one queue entry is processed per invocation. The OnTick hook
--     below only invokes this every PROCESS_EVERY_N_TICKS game ticks, so a
--     burst of zombies streaming in does not translate into a spike of
--     modData reads + getZombiePersistentID calls in a single frame.
--   * Processed entries accumulate in ProposalBatch. We flush the batch to
--     the server when either (a) it reaches BATCH_FLUSH_SIZE entries, or
--     (b) the queue has been empty for FLUSH_TOLERANCE_TICKS consecutive
--     process-ticks. That tolerance gives trailing zombies a chance to
--     arrive (as the player moves) and ride the same RequestZombieInfo
--     packet instead of each triggering their own.
--
-- Entries whose onlineID is not yet assigned stay in the queue; the
-- iteration skips them without consuming the per-tick budget.
-- ============================================================================

local BATCH_FLUSH_SIZE        = 30
local PROCESS_EVERY_N_TICKS   = 6   -- ~6 per second at PZ default ~6 TPS
local FLUSH_TOLERANCE_TICKS   = 12   -- ~2 second grace after queue drains

---@type table[] accumulating proposal payloads across ticks
local ProposalBatch           = {}
local IdleTolerance           = 0   -- process-ticks elapsed with empty queue
local ProcessTickCounter      = 0

--- Dispatch the currently buffered proposals to the server (if any).
local function flushProposalBatch(player)
    local n = #ProposalBatch
    if n == 0 then return end
    sendClientCommand(player, "Apocalipse_TSY", "RequestZombieInfo", {
        zombies = ProposalBatch
    })
    -- Reset without reallocating: clear keys so the table can be reused.
    for i = 1, n do
        ProposalBatch[i] = nil
    end
end

--- Swap-remove queue[i] in O(1).
local function queuePop(i)
    PendingZombies.queue[i] = PendingZombies.queue[PendingZombies.count]
    PendingZombies.queue[PendingZombies.count] = nil
    PendingZombies.count = PendingZombies.count - 1
end

local function Apocalipse_TSY_ProcessPending()
    -- Nothing to do and batch already drained.
    if PendingZombies.count == 0 and #ProposalBatch == 0 then
        IdleTolerance = 0
        return
    end

    local player = getPlayer()
    if not player then
        return
    end

    -- Zone data not ready yet - request it (throttled) and bail
    if not (RegionManager and RegionManager.Client and RegionManager.Client.zoneData) then
        if RegionManager.ClientTick and RegionManager.ClientTick.requestBoundariesThrottled then
            RegionManager.ClientTick.requestBoundariesThrottled()
        else
            sendClientCommand("RegionManager", "RequestAllBoundaries", {})
        end
        return
    end

    -- Snapshot zone boundary list for O(zones) lookups per zombie.
    -- We only want to send RequestZombieInfo for zombies standing inside a
    -- zone whose properties actually affect zombies. Regions always cover
    -- the whole map (auto-fill), so a pure bounds test is not enough -- we
    -- need to check that at least one zombie-affecting chance property is
    -- non-zero in the overlapping zone(s).
    local zoneList = (RegionManager and RegionManager.Client and RegionManager.Client.zoneData) or nil
    local hasZones = zoneList and #zoneList > 0

    -- ------------------------------------------------------------------
    -- Process AT MOST ONE eligible zombie this tick. We walk the queue
    -- from the tail looking for the first entry whose onlineID is ready,
    -- dropping dead/already-processed entries along the way (those are
    -- cheap housekeeping, they don't "count" against the per-tick budget
    -- because they don't touch getModData/GetZombiePersistentID).
    -- ------------------------------------------------------------------
    local processed = false
    local i = PendingZombies.count
    while i >= 1 and not processed do
        local zombie = PendingZombies.queue[i]

        if not zombie or zombie:isDead() then
            queuePop(i)
        else
            local onlineID = zombie:getOnlineID()
            if onlineID < 0 then
                -- Server hasn't assigned it yet; leave in place, try earlier slot.
                i = i - 1
            else
                local data = zombie:getModData()
                if data.Apocalipse_TSY_Processed then
                    -- Same IsoZombie object we already processed this session.
                    -- (modData on the same ref survives until that ref is GC'd.)
                    queuePop(i)
                else
                    local persistentID = RegionManager.Shared.GetZombiePersistentID(zombie)

                    -- -------- PID fast path --------
                    -- If the server already told us what to do with this
                    -- PID-class (including via a sibling zombie earlier this
                    -- session), use that decision without contacting the
                    -- server again. If the zombie's live properties already
                    -- match the decision, we don't even run makeInactive.
                    local cachedDecision = DecidedByPID[persistentID]
                    if cachedDecision then
                        data.Apocalipse_TSY_Processed = true

                        if RegionManager.ZombieModuleClient and RegionManager.ZombieModuleClient.clearTrackedByPID then
                            RegionManager.ZombieModuleClient.clearTrackedByPID(persistentID)
                        end

                        if zombieMatchesDecision(zombie, cachedDecision.data) then
                            -- Already configured correctly (e.g. chunk reload
                            -- of an already-converted zombie). Zero Java cost.
                            queuePop(i)
                        else
                            -- Decision known, properties diverge: apply it
                            -- directly via the PendingApply drain. Still paced
                            -- one per tick via drainPendingApply.
                            enqueueApply(
                                zombie,
                                cachedDecision.data,
                                cachedDecision.raw,
                                cachedDecision.moduleId,
                                onlineID
                            )
                            queuePop(i)
                            -- Count as "processed" so the idle-flush tolerance
                            -- counter doesn't misfire a stale proposal batch.
                            processed = true
                        end
                    else
                        -- -------- Normal path: ask the server --------
                        data.Apocalipse_TSY_Processed = true
                        local zx, zy = zombie:getX(), zombie:getY()

                        -- Clear any stale trackedZombies entry inherited from a
                        -- previous zombie that reused this persistent ID.
                        if RegionManager.ZombieModuleClient and RegionManager.ZombieModuleClient.clearTrackedByPID then
                            RegionManager.ZombieModuleClient.clearTrackedByPID(persistentID)
                        end

                        if not isInZombieAffectingZone(zx, zy) then
                            -- Not in a zombie-affecting zone: drop without touching the batch.
                            queuePop(i)
                        else
                            ProposalBatch[#ProposalBatch + 1] = {
                                zombieID = onlineID,
                                persistentID = persistentID,
                                x = zx,
                                y = zy,
                                outfitName = zombie:getOutfitName()
                            }

                            -- Store in PendingConfirmations for O(1) lookup on ConfirmZombie
                            local existing = PendingConfirmations[persistentID]
                            if existing then
                                -- >500 tiles away: old entry is stale (recycled zombie)
                                local dx = existing.x - zx
                                local dy = existing.y - zy
                                if (dx * dx + dy * dy) > 250000 then -- 500^2
                                    PendingIDIndex[existing.onlineID] = nil
                                end
                            end
                            PendingConfirmations[persistentID] = {
                                zombieRef = zombie,
                                x = zx,
                                y = zy,
                                onlineID = onlineID
                            }
                            PendingIDIndex[onlineID] = persistentID

                            queuePop(i)
                            processed = true
                        end
                    end
                end
            end
        end
        i = i - 1
    end

    -- ------------------------------------------------------------------
    -- Flush policy.
    --   * Hard cap: once the batch reaches BATCH_FLUSH_SIZE, send now.
    --   * Soft cap: once the queue drains, wait FLUSH_TOLERANCE_TICKS more
    --     process-ticks so late arrivals (as the player moves) can join
    --     the same packet. Reset the tolerance counter any tick we
    --     actually processed a new entry.
    -- ------------------------------------------------------------------
    if #ProposalBatch >= BATCH_FLUSH_SIZE then
        flushProposalBatch(player)
        IdleTolerance = 0
    elseif PendingZombies.count == 0 then
        if processed then
            IdleTolerance = 0
        else
            IdleTolerance = IdleTolerance + 1
            if IdleTolerance >= FLUSH_TOLERANCE_TICKS then
                flushProposalBatch(player)
                IdleTolerance = 0
            end
        end
    else
        -- Queue still has work: tolerance only matters after it drains.
        IdleTolerance = 0
    end
end

-- ============================================================================
-- Spawn processor hook. Runs on Events.OnTick but only drains the queue
-- every PROCESS_EVERY_N_TICKS ticks, so a wave of incoming zombies gets
-- spread across frames instead of processed in one burst. Events.OnTick
-- at the PZ default fires ~6 times per second (a "game tick", NOT a
-- render frame), so this is still fast enough to pick up new spawns
-- quickly without holding the main thread.
--
-- SpeedRevalidation still uses the central ClientTick dispatcher because
-- it is a periodic drift check that doesn't need per-frame granularity.
-- ============================================================================

Events.OnTick.Add(function()
    ProcessTickCounter = ProcessTickCounter + 1
    if ProcessTickCounter < PROCESS_EVERY_N_TICKS then
        return
    end
    ProcessTickCounter = 0
    Apocalipse_TSY_ProcessPending()
    drainPendingApply()
    -- SpeedTracker.revalidateBatch()
end)

-- ============================================================================
-- Zombie death handler
-- ============================================================================
local function onZombieDead(zombie)
    if not zombie then
        return
    end

    -- Clean up SpeedTracker entry
    SpeedTracker.remove(zombie:getOnlineID())

    -- Clean up PendingConfirmations if zombie dies before confirmation
    local deadOnlineID = zombie:getOnlineID()
    local deadPersistentID = PendingIDIndex[deadOnlineID]
    if deadPersistentID then
        PendingConfirmations[deadPersistentID] = nil
        PendingIDIndex[deadOnlineID] = nil
    end
    -- DecidedByPID is keyed by the PID CLASS (outfit_female), shared by
    -- many zombies. It must NOT be cleared on individual zombie death --
    -- doing so would force every sibling to round-trip again.

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
    if ZKC_Main and ZKC_Main.recordKill then
        ZKC_Main.recordKill(player, totalKillValue)
        if killBonus > 0 then
            print("Apocalipse_TSY: Player earned +" .. killBonus .. " extra kill points (total " .. totalKillValue ..
                      ")")
        end
    end
end
Events.OnZombieDead.Add(onZombieDead)
