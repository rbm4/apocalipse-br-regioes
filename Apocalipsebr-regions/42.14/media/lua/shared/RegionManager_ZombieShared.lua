RegionManager.Shared = RegionManager.Shared or {}

-- Module dependencies
RegionManager.Shared.sandboxOptions = nil

-- Default number of extra hits tough zombies resist before dying (1-99)
-- Used as fallback when the region does not specify maxHits.
-- Shared between client & server code: change ONLY here.
---@type number
RegionManager.Shared.DEFAULT_MAX_HITS = 2

---@type string[]
local Apocalipse_TSY_SprinterWalkTypes = {"sprint1", "sprint2", "sprint3", "sprint4", "sprint5"}

---@type number
local Apocalipse_TSY_BaselineSprinterChance = 0 -- Default when not in any region

-- Cache for default stats
local defaultSpeed = nil
local defaultSight = nil
local defaultHearing = nil
local defaultToughness = nil
local defaultStrength = nil
local defaultCognition = nil
local defaultMemory = nil
local defaultArmorFactor = nil
local defaultMaxDefense = nil

-- Initialize sandbox options after game boot
local function InitializeSandboxOptions()
    if not RegionManager.Shared.sandboxOptions then
        RegionManager.Shared.sandboxOptions = getSandboxOptions()
        if RegionManager.Shared.sandboxOptions then
            print("Apocalipse_TSY: Sandbox options initialized successfully")
        else
            print("Apocalipse_TSY WARNING: Failed to initialize sandbox options")
        end
    end
end
-- Hook into early game events
if isServer() then
    Events.OnInitWorld.Add(InitializeSandboxOptions)
else
    Events.OnGameBoot.Add(InitializeSandboxOptions)
end

-- Get default zombie speed from sandbox options
function RegionManager.Shared.getDefaultSpeed()
    if defaultSpeed == nil then
        defaultSpeed = RegionManager.Shared.sandboxOptions:getOptionByName("ZombieLore.Speed") and
                           RegionManager.Shared.sandboxOptions:getOptionByName("ZombieLore.Speed"):getValue() or 2
    end
    return defaultSpeed
end
-- 1=Eagle, 2=Normal, 3=Poor, 4=Random, 5=Random between Normal and Poor
function RegionManager.Shared.getDefaultSight()
    if defaultSight == nil then
        defaultSight = RegionManager.Shared.sandboxOptions:getOptionByName("ZombieLore.Sight")
    end
    return defaultSight
end
-- 1=Pinpoint, 2=Normal, 3=Poor, 4=Random, 5=Random between Normal and Poor
function RegionManager.Shared.getDefaultHearing()
    if defaultHearing == nil then
        defaultHearing = RegionManager.Shared.sandboxOptions:getOptionByName("ZombieLore.Hearing")
    end
    return defaultHearing
end

-- 1=Tough, 2=Normal, 3=Fragile, 4=Random
function RegionManager.Shared.getDefaultToughness()
    if defaultToughness == nil then
        defaultToughness = RegionManager.Shared.sandboxOptions:getOptionByName("ZombieLore.Toughness")
    end
    return defaultToughness
end

-- 1=Superhuman, 2=Normal, 3=Weak, 4=Random
function RegionManager.Shared.getDefaultStrength()
    if defaultStrength == nil then
        defaultStrength = RegionManager.Shared.sandboxOptions:getOptionByName("ZombieLore.Strength")
    end
    return defaultStrength
end
-- 1=Navigate and Use Doors, 2=Navigate, 3=Basic Navigation, 4=Random
function RegionManager.Shared.getDefaultCognition()
    if defaultCognition == nil then
        defaultCognition = RegionManager.Shared.sandboxOptions:getOptionByName("ZombieLore.Cognition")
    end
    return defaultCognition
end

-- 1=Long, 2=Normal, 3=Short, 4=None, 5=Random, 6=Random between Normal and None
function RegionManager.Shared.getDefaultMemory()
    if defaultMemory == nil then
        defaultMemory = RegionManager.Shared.sandboxOptions:getOptionByName("ZombieLore.Memory")
    end
    return defaultMemory
end
-- Zombie armor effectiveness multiplier. 0.00 to 100.00 (default 2)
function RegionManager.Shared.getDefaultArmorFactor()
    if defaultArmorFactor == nil then
        defaultArmorFactor = RegionManager.Shared.sandboxOptions:getOptionByName("ZombieLore.ZombiesArmorFactor")
    end
    return defaultArmorFactor
end

-- Maximum zombie armor defense percentage. 0 to 100
function RegionManager.Shared.getDefaultMaxDefense()
    if defaultMaxDefense == nil then
        defaultMaxDefense = RegionManager.Shared.sandboxOptions:getOptionByName("ZombieLore.ZombiesMaxDefense")
    end
    return defaultMaxDefense
end

-- Create a persistent identifier for zombies (matches server logic)
---@param zombie IsoZombie
---@return string persistentID
function RegionManager.Shared.GetZombiePersistentID(zombie)
    -- Combine attributes that are stable across respawns
    local outfit = zombie:getPersistentOutfitID()
    local female = zombie:isFemale() and 1 or 0

    return string.format("%d_%d", outfit, female)
end

--- Get a reliable persistent ID that survives outfit changes.
--- Module zombies have their PID stamped into modData at conversion time
--- (before dressInPersistentOutfit changes the underlying persistentOutfitID).
--- Normal zombies fall through to the computed PID (no behavior change).
---@param zombie IsoZombie
---@return string persistentID
function RegionManager.Shared.GetReliablePID(zombie)
    local modData = zombie:getModData()
    local assigned = modData.Apocalipse_TSY_AssignedPID
    if assigned then
        return assigned
    end
    return RegionManager.Shared.GetZombiePersistentID(zombie)
end

-- Make zombie sprint
---@param zombie IsoZombie
function RegionManager.Shared.makeSprint(zombie, sandboxOptions)
    if defaultSpeed == nil then
        defaultSpeed = RegionManager.Shared.getDefaultSpeed()
    end

    zombie:makeInactive(true)
    sandboxOptions:set("ZombieLore.Speed", 1)
    zombie:makeInactive(false)
    sandboxOptions:set("ZombieLore.Speed", defaultSpeed)
end

-- Make zombie shamble
---@param zombie IsoZombie
function RegionManager.Shared.makeShamble(zombie, sandboxOptions)
    if defaultSpeed == nil then
        defaultSpeed = RegionManager.Shared.getDefaultSpeed()
    end

    zombie:makeInactive(true)
    sandboxOptions:set("ZombieLore.Speed", 3)
    zombie:makeInactive(false)
    sandboxOptions:set("ZombieLore.Speed", defaultSpeed)
end

-- Deterministic pseudo-random (matches server logic)
---@param zombieID number
---@param max number
---@return number
-- Deterministic pseudo-random (matches server logic)
---@param max number
---@return number
function RegionManager.Shared.GetDeterministicRandom(max)
    if not RegionManager.Shared._rngSeed then
        RegionManager.Shared._rngSeed = os.time()
    end
    local seed = RegionManager.Shared._rngSeed
    seed = ((seed * 1103515245) + 12345) % 2147483648
    RegionManager.Shared._rngSeed = seed
    return seed % max
end

-- Set the internal seed (call this with a zombie-specific value before calling GetDeterministicRandom)
---@param seed number
function RegionManager.Shared.SetDeterministicSeed(seed)
    if seed < 0 then
        seed = seed * -1
    end
    RegionManager.Shared._rngSeed = seed
end

-- Get sprinter chance for current position based on known regions
---@param region table Region data
---@return number chance 0-100 sprinter percentage
function RegionManager.Shared.GetSprinterChance(region)
    -- Check which region contains this position
    if region.properties.sprinterChance and type(region.properties.sprinterChance) == "number" then
        local chance = region.properties.sprinterChance
        if chance < 1 then
            chance = 0
        end
        if chance > 100 then
            chance = 100
        end
        return chance
    end

    -- No region found or region has no sprinter config
    return 0
end

-- Get shambler chance for current position based on known regions
---@param region table Region data
---@return number chance 0-100 shambler percentage
function RegionManager.Shared.GetShamblerChance(region)
    -- Check if region has shambler configuration
    if region.properties.shamblerChance and type(region.properties.shamblerChance) == "number" then
        local chance = region.properties.shamblerChance
        if chance < 1 then
            chance = 0
        end
        if chance > 100 then
            chance = 100
        end
        return chance
    end

    -- No region found or region has no shambler config
    return 0
end

-- Get hawk vision chance for current position based on known regions
---@param region table Region data
---@return number chance 0-100 hawk vision percentage
function RegionManager.Shared.GetHawkVisionChanceFromRegion(region)
    if region.properties.hawkVisionChance and type(region.properties.hawkVisionChance) == "number" then
        local chance = region.properties.hawkVisionChance
        if chance < 1 then
            chance = 0
        end
        if chance > 100 then
            chance = 100
        end
        return chance
    end
    return 0
end

-- Get bad vision chance for current position based on known regions
---@param region table Region data
---@return number chance 0-100 bad vision percentage
function RegionManager.Shared.GetBadVisionChance(region)
    if region.properties.badVisionChance and type(region.properties.badVisionChance) == "number" then
        local chance = region.properties.badVisionChance
        if chance < 1 then
            chance = 0
        end
        if chance > 100 then
            chance = 100
        end
        return chance
    end
    return 0
end

-- Get good hearing chance for current position based on known regions
---@param region table Region data
---@return number chance 0-100 good hearing percentage
function RegionManager.Shared.GetGoodHearingChance(region)
    if region.properties.goodHearingChance and type(region.properties.goodHearingChance) == "number" then
        local chance = region.properties.goodHearingChance
        if chance < 1 then
            chance = 0
        end
        if chance > 100 then
            chance = 100
        end
        return chance
    end
    return 0
end

-- Get bad hearing chance for current position based on known regions
---@param region table Region data
---@return number chance 0-100 bad hearing percentage
function RegionManager.Shared.GetBadHearingChance(region)
    if region.properties.badHearingChance and type(region.properties.badHearingChance) == "number" then
        local chance = region.properties.badHearingChance
        if chance < 1 then
            chance = 0
        end
        if chance > 100 then
            chance = 100
        end
        return chance
    end
    return 0
end

-- Get zombie armor factor for current position based on known regions
---@param region table Region data
---@return number factor 0-100 armor factor percentage
function RegionManager.Shared.GetZombieArmorFactor(region)
    if region.properties.zombieArmorFactor and type(region.properties.zombieArmorFactor) == "number" then
        local factor = region.properties.zombieArmorFactor
        if factor < 0 then
            factor = 0
        end
        if factor > 100 then
            factor = 100
        end
        return factor
    end
    return 0
end

-- Get resistant chance for current position based on known regions
---@param region table Region data
---@return number chance 0-100 resistant percentage
function RegionManager.Shared.GetResistantChance(region)
    if region.properties.resistantChance and type(region.properties.resistantChance) == "number" then
        local chance = region.properties.resistantChance
        if chance < 1 then
            chance = 0
        end
        if chance > 100 then
            chance = 100
        end
        return chance
    end
    return 0
end

-- Get normal vision chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetNormalVisionChance(region)
    if region.properties.normalVisionChance and type(region.properties.normalVisionChance) == "number" then
        return math.max(0, math.min(100, region.properties.normalVisionChance))
    end
    return 0
end

-- Get poor vision chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetPoorVisionChance(region)
    if region.properties.poorVisionChance and type(region.properties.poorVisionChance) == "number" then
        return math.max(0, math.min(100, region.properties.poorVisionChance))
    end
    return 0
end

-- Get random vision chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetRandomVisionChance(region)
    if region.properties.randomVisionChance and type(region.properties.randomVisionChance) == "number" then
        return math.max(0, math.min(100, region.properties.randomVisionChance))
    end
    return 0
end

-- Get pinpoint hearing chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetPinpointHearingChance(region)
    if region.properties.pinpointHearingChance and type(region.properties.pinpointHearingChance) == "number" then
        return math.max(0, math.min(100, region.properties.pinpointHearingChance))
    end
    return 0
end

-- Get normal hearing chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetNormalHearingChance(region)
    if region.properties.normalHearingChance and type(region.properties.normalHearingChance) == "number" then
        return math.max(0, math.min(100, region.properties.normalHearingChance))
    end
    return 0
end

-- Get poor hearing chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetPoorHearingChance(region)
    if region.properties.poorHearingChance and type(region.properties.poorHearingChance) == "number" then
        return math.max(0, math.min(100, region.properties.poorHearingChance))
    end
    return 0
end

-- Get random hearing chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetRandomHearingChance(region)
    if region.properties.randomHearingChance and type(region.properties.randomHearingChance) == "number" then
        return math.max(0, math.min(100, region.properties.randomHearingChance))
    end
    return 0
end

-- Get toughness chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetToughnessChance(region)
    if region.properties.toughnessChance and type(region.properties.toughnessChance) == "number" then
        return math.max(0, math.min(100, region.properties.toughnessChance))
    end
    return 0
end

-- Get normal toughness chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetNormalToughnessChance(region)
    if region.properties.normalToughnessChance and type(region.properties.normalToughnessChance) == "number" then
        return math.max(0, math.min(100, region.properties.normalToughnessChance))
    end
    return 0
end

-- Get fragile chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetFragileChance(region)
    if region.properties.fragileChance and type(region.properties.fragileChance) == "number" then
        return math.max(0, math.min(100, region.properties.fragileChance))
    end
    return 0
end

-- Get random toughness chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetRandomToughnessChance(region)
    if region.properties.randomToughnessChance and type(region.properties.randomToughnessChance) == "number" then
        return math.max(0, math.min(100, region.properties.randomToughnessChance))
    end
    return 0
end

-- Get navigation chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetNavigationChance(region)
    if region.properties.navigationChance and type(region.properties.navigationChance) == "number" then
        return math.max(0, math.min(100, region.properties.navigationChance))
    end
    return 0
end

-- Get armor effectiveness multiplier
---@param region table Region data
---@return number multiplier
function RegionManager.Shared.GetArmorEffectivenessMultiplier(region)
    if region.properties.armorEffectivenessMultiplier and type(region.properties.armorEffectivenessMultiplier) ==
        "number" then
        return math.max(0, region.properties.armorEffectivenessMultiplier)
    end
    return 1.0
end

-- Get armor defense percentage
---@param region table Region data
---@return number percentage 0-100
function RegionManager.Shared.GetArmorDefensePercentage(region)
    if region.properties.armorDefensePercentage and type(region.properties.armorDefensePercentage) == "number" then
        return math.max(0, math.min(100, region.properties.armorDefensePercentage))
    end
    return 0
end

-- Get superhuman toughness chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetSuperhumanChance(region)
    if region.properties.superhumanChance and type(region.properties.superhumanChance) == "number" then
        return math.max(0, math.min(100, region.properties.superhumanChance))
    end
    return 0
end

-- Get normal toughness chance (alt naming)
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetNormalToughness(region)
    if region.properties.normalToughness and type(region.properties.normalToughness) == "number" then
        return math.max(0, math.min(100, region.properties.normalToughness))
    end
    return 0
end

-- Get weak toughness chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetWeakChance(region)
    if region.properties.weakChance and type(region.properties.weakChance) == "number" then
        return math.max(0, math.min(100, region.properties.weakChance))
    end
    return 0
end

-- Get random toughness chance (alt naming)
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetRandomToughness(region)
    if region.properties.randomToughness and type(region.properties.randomToughness) == "number" then
        return math.max(0, math.min(100, region.properties.randomToughness))
    end
    return 0
end

-- Get memory long chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetMemoryLongChance(region)
    if region.properties.memoryLongChance and type(region.properties.memoryLongChance) == "number" then
        return math.max(0, math.min(100, region.properties.memoryLongChance))
    end
    return 0
end

-- Get memory normal chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetMemoryNormalChance(region)
    if region.properties.memoryNormalChance and type(region.properties.memoryNormalChance) == "number" then
        return math.max(0, math.min(100, region.properties.memoryNormalChance))
    end
    return 0
end

-- Get memory short chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetMemoryShortChance(region)
    if region.properties.memoryShortChance and type(region.properties.memoryShortChance) == "number" then
        return math.max(0, math.min(100, region.properties.memoryShortChance))
    end
    return 0
end

-- Get memory none chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetMemoryNoneChance(region)
    if region.properties.memoryNoneChance and type(region.properties.memoryNoneChance) == "number" then
        return math.max(0, math.min(100, region.properties.memoryNoneChance))
    end
    return 0
end

-- Get memory random chance
---@param region table Region data
---@return number chance 0-100 percentage
function RegionManager.Shared.GetMemoryRandomChance(region)
    if region.properties.memoryRandomChance and type(region.properties.memoryRandomChance) == "number" then
        return math.max(0, math.min(100, region.properties.memoryRandomChance))
    end
    return 0
end

-- ============================================================================
-- Reflection helpers (like BLTRandomZombies)
-- ============================================================================

-- Cached ConfigOption references (NOT just values)
local speedConfigOption = nil
local cognitionConfigOption = nil
local sightConfigOption = nil
local hearingConfigOption = nil
local toughnessConfigOption = nil
local strengthConfigOption = nil
local memoryConfigOption = nil


-- Initialize field and config option references (call once)
local function initializeReflectionCache()
    if not speedConfigOption then

        -- Get ConfigOption references (NOT just sandbox options)
        local sandbox = getSandboxOptions()
        speedConfigOption = sandbox:getOptionByName("ZombieLore.Speed"):asConfigOption()
        cognitionConfigOption = sandbox:getOptionByName("ZombieLore.Cognition"):asConfigOption()
        sightConfigOption = sandbox:getOptionByName("ZombieLore.Sight"):asConfigOption()
        hearingConfigOption = sandbox:getOptionByName("ZombieLore.Hearing"):asConfigOption()
        toughnessConfigOption = sandbox:getOptionByName("ZombieLore.Toughness"):asConfigOption()
        strengthConfigOption = sandbox:getOptionByName("ZombieLore.Strength"):asConfigOption()
        memoryConfigOption = sandbox:getOptionByName("ZombieLore.Memory"):asConfigOption()

        print("Apocalipse_TSY: Reflection cache initialized")
    end
end

-- Public accessor so other files can force the reflection cache to warm up
-- BEFORE the first zombie conversion (which happens inside a hot path and
-- would otherwise pay the Java-interop cost of 7 sandbox option lookups).
function RegionManager.Shared.PrewarmReflectionCache()
    local ok, err = pcall(initializeReflectionCache)
    if not ok then
        print("Apocalipse_TSY WARNING: Reflection prewarm failed: " .. tostring(err))
    end
end

-- Warm the reflection cache + default-stat cache as early as possible so the
-- first zombie batch does not stall on sandbox lookups.
local function prewarmCaches()
    RegionManager.Shared.PrewarmReflectionCache()
    -- Touch each default-stat getter so the lazy cache is primed. Wrapped in
    -- pcall because a missing sandbox option should not break boot.
    pcall(RegionManager.Shared.getDefaultSpeed)
    pcall(RegionManager.Shared.getDefaultSight)
    pcall(RegionManager.Shared.getDefaultHearing)
    pcall(RegionManager.Shared.getDefaultToughness)
    pcall(RegionManager.Shared.getDefaultStrength)
    pcall(RegionManager.Shared.getDefaultCognition)
    pcall(RegionManager.Shared.getDefaultMemory)
    pcall(RegionManager.Shared.getDefaultArmorFactor)
    pcall(RegionManager.Shared.getDefaultMaxDefense)
end
if isServer() then
    Events.OnInitWorld.Add(prewarmCaches)
else
    Events.OnGameBoot.Add(prewarmCaches)
end

-- Constants for zombie properties (matching BLTRandomZombies)
local SPEED_SPRINTER = 1
local SPEED_FAST_SHAMBLER = 2
local SPEED_SHAMBLER = 3

local COGNITION_NAVIGATE_DOORS = 1
local COGNITION_NAVIGATE = 2
local COGNITION_BASIC = 3
local COGNITION_RANDOM = 4

local SIGHT_EAGLE = 1
local SIGHT_NORMAL = 2
local SIGHT_POOR = 3

local HEARING_PINPOINT = 1
local HEARING_NORMAL = 2
local HEARING_POOR = 3

local TOUGHNESS_TOUGH = 1
local TOUGHNESS_NORMAL = 2
local TOUGHNESS_FRAGILE = 3

local STRENGTH_SUPERHUMAN = 1
local STRENGTH_NORMAL = 2
local STRENGTH_WEAK = 3

local MEMORY_LONG = 1
local MEMORY_NORMAL = 2
local MEMORY_SHORT = 3
local MEMORY_NONE = 4
local MEMORY_RANDOM = 5

-- Apply zombie properties based on server-determined data
-- This function is called CLIENT-SIDE after receiving decisions from the server
-- Uses BLTRandomZombies approach: reflection + ConfigOptions + makeInactive cycle
--
-- FIX: All config options are set BEFORE the makeInactive cycle so that the
-- internal DoZombieStats() (called by makeInactive(false)) applies everything
-- in a single pass. The old approach set speed first, restored it, then set
-- other configs and called DoZombieStats() - which re-triggered doZombieSpeed()
-- against the already-restored sandbox default, undoing the speed override ~66%
-- of the time due to Rand.Next(3) in doZombieSpeedInternal.
--
-- For sprinters: retry the makeInactive cycle until zombie.lunger == true.
-- Only doSprinter() sets lunger=true; doFakeShambler() (the 66% path) does not.
-- Expected ~3 attempts, capped at 15 for 99.5% reliability.
---@param zombie IsoZombie The zombie to modify
---@param data table Property decisions from server
---@param sandboxOptions table Sandbox options (unused, kept for compatibility)
function RegionManager.Shared.ServerSideProperties(zombie, data, sandboxOptions)
    if not zombie or not data then
        return
    end

    -- Initialize reflection cache if needed
    initializeReflectionCache()

    -- Store original config option values
    local origSpeed = speedConfigOption:getValue()
    local origCognition = cognitionConfigOption:getValue()
    local origSight = sightConfigOption:getValue()
    local origHearing = hearingConfigOption:getValue()
    local origToughness = toughnessConfigOption:getValue()
    local origStrength = strengthConfigOption:getValue()
    local origMemory = memoryConfigOption:getValue()

    -- ========================================================================
    -- SET ALL CONFIG OPTIONS AT ONCE before the makeInactive cycle.
    -- makeInactive(false) -> DoZombieStats() reads these and applies them.
    -- ========================================================================

    -- Speed
    if data.isSprinter then
        speedConfigOption:setValue(SPEED_SPRINTER)
    elseif data.isShambler then
        speedConfigOption:setValue(SPEED_SHAMBLER)
    end

    -- Cognition
    if data.hasNavigation then
        cognitionConfigOption:setValue(COGNITION_NAVIGATE_DOORS)
    end

    -- Sight
    if data.hawkVision then
        sightConfigOption:setValue(SIGHT_EAGLE)
    elseif data.normalVision then
        sightConfigOption:setValue(SIGHT_NORMAL)
    elseif data.poorVision or data.badVision then
        sightConfigOption:setValue(SIGHT_POOR)
    end

    -- Hearing
    if data.pinpointHearing or data.goodHearing then
        hearingConfigOption:setValue(HEARING_PINPOINT)
    elseif data.normalHearing then
        hearingConfigOption:setValue(HEARING_NORMAL)
    elseif data.poorHearing or data.badHearing then
        hearingConfigOption:setValue(HEARING_POOR)
    end

    -- Strength
    if data.isSuperhuman then
        strengthConfigOption:setValue(STRENGTH_SUPERHUMAN)
    elseif data.isNormalToughness2 or data.isNormalToughness then
        strengthConfigOption:setValue(STRENGTH_NORMAL)
    elseif data.isWeak then
        strengthConfigOption:setValue(STRENGTH_WEAK)
    end

    -- Memory
    if data.hasMemoryLong then
        memoryConfigOption:setValue(MEMORY_LONG)
    elseif data.hasMemoryNormal then
        memoryConfigOption:setValue(MEMORY_NORMAL)
    elseif data.hasMemoryShort then
        memoryConfigOption:setValue(MEMORY_SHORT)
    elseif data.hasMemoryNone then
        memoryConfigOption:setValue(MEMORY_NONE)
    elseif data.hasMemoryRandom then
        memoryConfigOption:setValue(MEMORY_RANDOM)
    end

    -- ========================================================================
    -- SINGLE makeInactive CYCLE - applies ALL config options at once via
    -- the internal DoZombieStats() call inside makeInactive(false).
    -- For sprinters: retry until doSprinter() path is taken (lunger=true).
    -- Shamblers always hit doShambler() on the first try (no Rand.Next(3)).
    -- ========================================================================
    local modData = zombie:getModData()

    if data.isSprinter then
        local MAX_RETRIES = 1 --should be higher but we can't get stuck here rolling for a true sprinter
        for attempt = 1, MAX_RETRIES do
            zombie:makeInactive(true)
            zombie:makeInactive(false)
            if zombie.lunger then
                break
            end
        end
    elseif data.isShambler then
        zombie:makeInactive(true)
        zombie:makeInactive(false)
    else
        -- No speed override, but still apply other stats via the cycle
        zombie:makeInactive(true)
        zombie:makeInactive(false)
    end

    -- ========================================================================
    -- RESTORE ALL CONFIG OPTIONS - done AFTER the cycle so DoZombieStats
    -- read our overrides, not the sandbox defaults.
    -- NO trailing DoZombieStats() call - everything was applied above.
    -- ========================================================================
    speedConfigOption:setValue(origSpeed)
    cognitionConfigOption:setValue(origCognition)
    sightConfigOption:setValue(origSight)
    hearingConfigOption:setValue(origHearing)
    toughnessConfigOption:setValue(origToughness)
    strengthConfigOption:setValue(origStrength)
    memoryConfigOption:setValue(origMemory)

    -- Re-fetch modData after the makeInactive cycle in case the cycle
    -- invalidated the earlier Lua reference to the Java HashMap.
    modData = zombie:getModData()

    -- Write ExpectedSpeed on the fresh reference
    if data.isSprinter then
        modData.Apocalipse_TSY_ExpectedSpeed = "sprinter"
    elseif data.isShambler then
        modData.Apocalipse_TSY_ExpectedSpeed = "shambler"
    end

    -- ========================================================================
    -- TOUGHNESS (HP-based) - applied after cycle since DoZombieStats
    -- does not touch health.
    -- Always set toughness modData so the hit system recognizes this zombie.
    -- Only modify health when the zombie is not mid-combat. 
    -- ========================================================================
    if data.isTough then
        local maxHits = data.maxHits or RegionManager.Shared.DEFAULT_MAX_HITS
        modData.Apocalipse_TSY_ToughnessType = "tough"
        modData.Apocalipse_TSY_ToughnessHitCounter = 0
        modData.Apocalipse_TSY_ToughnessMaxHits = maxHits
        if not zombie:getAttackedBy() and not zombie:isOnFire() then
            local health = 0.1 * ZombRand(4) + 2.0
            zombie:setHealth(health)
        end
    elseif data.isFragile then
        modData.Apocalipse_TSY_ToughnessType = "fragile"
        if not zombie:getAttackedBy() and not zombie:isOnFire() then
            local health = 0.1 * ZombRand(4) + 0.5
            zombie:setHealth(health)
        end
    elseif data.isNormalToughness then
        modData.Apocalipse_TSY_ToughnessType = "normal"
        if not zombie:getAttackedBy() and not zombie:isOnFire() then
            local health = 0.1 * ZombRand(4) + 1.5
            zombie:setHealth(health)
        end
    end

    -- ========================================================================
    -- KILL BONUS - module override or difficulty-based computation
    -- ========================================================================
    local killBonus = 0

    -- Check if this zombie belongs to a registered module with a flat killBonus
    if data.moduleId then
        require "RegionManager_ZombieModules"
        local moduleDef = RegionManager.ZombieModules.getById(data.moduleId)
        if moduleDef and moduleDef.stats and moduleDef.stats.killBonus then
            killBonus = moduleDef.stats.killBonus
            modData.Apocalipse_TSY_KillBonus = math.max(0, killBonus)
            return -- skip computed bonus
        end
    end

    -- Fast path: server pre-computed the non-module killBonus and sent it in
    -- the payload. Skip the 15-branch if-ladder entirely.
    if data.killBonusPrecomputed ~= nil then
        local precomputed = data.killBonusPrecomputed
        if precomputed < 0 then precomputed = 0 end
        modData.Apocalipse_TSY_KillBonus = precomputed
        return
    end

    if data.isSprinter then killBonus = killBonus + 3 end
    if data.isShambler then killBonus = killBonus - 3 end
    if data.hawkVision then killBonus = killBonus + 1 end
    if data.poorVision or data.badVision then killBonus = killBonus - 1 end
    if data.pinpointHearing or data.goodHearing then killBonus = killBonus + 1 end
    if data.poorHearing or data.badHearing then killBonus = killBonus - 1 end
    if data.isTough then killBonus = killBonus + 3 end
    if data.isFragile then killBonus = killBonus - 1 end
    if data.isSuperhuman then killBonus = killBonus + 1 end
    if data.isWeak then killBonus = killBonus - 1 end
    if data.hasNavigation then killBonus = killBonus + 2 end
    if data.hasMemoryLong then killBonus = killBonus + 1 end
    if data.hasMemoryShort then killBonus = killBonus - 1 end
    if data.hasMemoryNone then killBonus = killBonus - 2 end
    if data.isResistant then killBonus = killBonus + 1 end
    if data.maxHits then killBonus = killBonus + math.floor(data.maxHits * 0.5) end
    modData.Apocalipse_TSY_KillBonus = math.max(0, killBonus)
end

-- ============================================================================
-- Speed Revalidation (O(1) per zombie)
-- When a zombie changes authority owner in MP, makeInactive(false) resets
-- speedType to -1 and DoZombieStats() re-randomizes from sandbox defaults.
-- This function checks a single zombie's speedType against the expected value
-- stored in modData and re-runs the full ServerSideProperties from the cached
-- ConfirmZombie payload if mismatched.
--
-- Uses zombie.speedType (public int) for O(1) detection instead of parsing
-- the walkType string. Returns true if the speed was corrected.
-- ============================================================================
---@param zombie IsoZombie
---@param sandboxOptions table
---@return boolean corrected
function RegionManager.Shared.RevalidateZombieSpeed(zombie, sandboxOptions)
    if not zombie or zombie:isDead() then
        return false
    end

    -- Only fix zombies we are currently simulating (we are the auth owner)
    if zombie:isRemoteZombie() then
        return false
    end

    local modData = zombie:getModData()
    local expected = modData.Apocalipse_TSY_ExpectedSpeed
    if not expected then
        return false -- not a zombie we modified, skip
    end

    
    -- Read the current walkType from the animation variable
    local walkType = zombie:getVariableString("zombiewalktype")
    if not walkType then
        walkType = ""
    end
    walkType = string.lower(tostring(walkType))

    if expected == "sprinter" then
        -- Sprinter walkType should contain "sprint"
        if string.find(walkType, "sprint") then
            return false -- already correct
        end
        -- Mismatch: zombie should be sprinting but isn't
        RegionManager.Shared.makeSprint(zombie, sandboxOptions)
        print("Apocalipse_TSY: Revalidated sprinter zombie " .. tostring(zombie:getOnlineID())
              .. " (walkType was '" .. walkType .. "')")
        return true

    elseif expected == "shambler" then
        -- Shambler walkType should contain "slow" (slow1, slow2, slow3)
        if string.find(walkType, "slow") then
            return false -- already correct
        end
        -- Also accept empty/nil as possibly OK if the zombie is idle,
        -- but if it contains "sprint" that is definitely wrong
        if not string.find(walkType, "sprint") then
            return false -- not clearly wrong, leave it
        end
        -- Mismatch: zombie is sprinting but should be shambling
        RegionManager.Shared.makeShamble(zombie, sandboxOptions)
        print("Apocalipse_TSY: Revalidated shambler zombie " .. tostring(zombie:getOnlineID())
              .. " (walkType was '" .. walkType .. "')")
        return true
    end

    return false
end

-- Decode a cached ConfirmZombie payload string into a data table.
-- This mirrors the client-side decodeConfirmPayload but works from the raw
-- payload string + known zombieID/maxHits (stored separately in modData).
---@param payloadStr string The 23-char encoded payload
---@param zombieID number The zombie's onlineID
---@param maxHits number|nil Cached maxHits value
---@return table|nil data Decoded property table
function RegionManager.Shared.DecodePayload(payloadStr, zombieID, maxHits)
    if not payloadStr or #payloadStr < 21 then
        return nil
    end

    local bits = tonumber(string.sub(payloadStr, 1, 9)) or 0
    maxHits = maxHits or RegionManager.Shared.DEFAULT_MAX_HITS

    local function hasBit(pos)
        return math.floor(bits / (2 ^ pos)) % 2 == 1
    end

    return {
        zombieID           = zombieID,
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
        maxHits            = maxHits,
    }
end

-- ============================================================================
-- Dynamic Toughness System - Networked OnHit Handler
-- Tough zombies get extra resilience through server-authoritative hit tracking.
-- Flow: Client detects hit -> sends to server -> server validates & broadcasts
--       -> all nearby clients apply avoidDamage + stagger
-- ============================================================================

-- Pending attacker-side references for tough-hit acknowledgements.
-- Keyed by reliable PID with a short TTL to avoid stale references.
local ToughHitPendingRef = {}
local TOUGH_HIT_REF_TTL_SEC = 15
local TOUGH_HIT_MATCH_MAX_DIST = 10
local TOUGH_HIT_EXHAUST_FALLBACK_MAX_DIST = 20

local function applyToughHitState(zombie, persistentID, hitCounter, maxHits, isExhausted)
    local modData = zombie:getModData()

    -- Sync authoritative counter from server
    modData.Apocalipse_TSY_ToughnessHitCounter = hitCounter
    modData.Apocalipse_TSY_ToughnessMaxHits = maxHits

    if not isExhausted then
        -- Still has lives: make immune to this hit + stagger
        zombie:setAvoidDamage(true)
        zombie:setKnockedDown(false)
        zombie:setStaggerBack(true)
        print("Apocalipse_TSY: Tough zombie pid=" .. tostring(persistentID) .. " resisted hit (" .. hitCounter .. "/" .. maxHits .. ")")
    else
        -- All lives used up: fully disengage the toughness system.
        -- Clear the type so OnWeaponHitCharacter stops intercepting hits
        -- and the convergence loop stops re-enforcing toughness.
        modData.Apocalipse_TSY_ToughnessType = "exhausted"
        zombie:setAvoidDamage(false)
        print("Apocalipse_TSY: Tough zombie pid=" .. tostring(persistentID) .. " exhausted all lives, now vulnerable")
    end
end

local function sweepPendingToughHitRefs(now)
    for pid, entry in pairs(ToughHitPendingRef) do
        if not entry or not entry.expiresAt or entry.expiresAt <= now then
            ToughHitPendingRef[pid] = nil
        end
    end
end

-- CLIENT-SIDE: Apply the toughness effect received from server broadcast
-- Called by the client command handler in RegionManager_ZombieClient.lua
---@param zombieID number The online ID of the zombie (used for log output)
---@param persistentID string|nil The server-computed persistent ID
---@param hitCounter number The authoritative hit counter from server
---@param maxHits number The maximum hits before zombie can die
---@param isExhausted boolean True if zombie has used all its extra lives
---@param zombieX number|nil Broadcast X of the hit zombie
---@param zombieY number|nil Broadcast Y of the hit zombie
function RegionManager.Shared.ApplyToughZombieHit(zombieID, persistentID, hitCounter, maxHits, isExhausted, zombieX, zombieY)
    local now = os.time()
    sweepPendingToughHitRefs(now)

    -- Attacker fast path: use direct cached zombie reference first.
    if persistentID then
        local pending = ToughHitPendingRef[persistentID]
        if pending and pending.expiresAt and pending.expiresAt > now then
            local cachedZombie = pending.zombie
            if cachedZombie and not cachedZombie:isDead() and RegionManager.Shared.GetReliablePID(cachedZombie) == persistentID then
                ToughHitPendingRef[persistentID] = nil
                applyToughHitState(cachedZombie, persistentID, hitCounter, maxHits, isExhausted)
                return
            end
        end
    end

    local player = getPlayer()
    if not player then
        return
    end

    local cell = player:getCell()
    if not cell then
        return
    end

    local zombieList = cell:getZombieList()
    if not zombieList then
        return
    end

    local applied = false
    for i = 0, zombieList:size() - 1 do
        local zombie = zombieList:get(i)
        if zombie and not zombie:isDead() then
            -- Match by persistent ID first, then onlineID as a fallback in case
            -- PID stamping diverged between server and client for this zombie.
            local matched = false
            if persistentID then
                matched = RegionManager.Shared.GetReliablePID(zombie) == persistentID
                if not matched and zombie:getOnlineID() == zombieID then
                    matched = true
                end
            else
                matched = zombie:getOnlineID() == zombieID
            end
            if matched then
                if persistentID then
                    ToughHitPendingRef[persistentID] = nil
                end
                applyToughHitState(zombie, persistentID, hitCounter, maxHits, isExhausted)
                applied = true
                break
            end
        end
    end

    if applied then
        return
    end

    -- Defensive fallback: if the server marked exhausted but strict matching
    -- failed locally, force-clear optimistic mitigation on the best candidate
    -- near the broadcast coordinates so zombies cannot remain immortal.
    if isExhausted then
        local bestZombie = nil
        local bestDistSq = nil
        local maxDistSq = TOUGH_HIT_EXHAUST_FALLBACK_MAX_DIST * TOUGH_HIT_EXHAUST_FALLBACK_MAX_DIST

        for i = 0, zombieList:size() - 1 do
            local zombie = zombieList:get(i)
            if zombie and not zombie:isDead() then
                local candidate = false
                if zombie:getOnlineID() == zombieID then
                    candidate = true
                elseif zombieX and zombieY then
                    local modData = zombie:getModData()
                    if modData.Apocalipse_TSY_ToughnessType == "tough" and zombie:avoidDamage() then
                        candidate = true
                    end
                end

                if candidate then
                    local distSq = 0
                    if zombieX and zombieY then
                        local dx = zombie:getX() - zombieX
                        local dy = zombie:getY() - zombieY
                        distSq = dx * dx + dy * dy
                    end

                    if (not zombieX or not zombieY or distSq <= maxDistSq)
                        and (not bestDistSq or distSq < bestDistSq) then
                        bestZombie = zombie
                        bestDistSq = distSq
                    end
                end
            end
        end

        if bestZombie then
            applyToughHitState(bestZombie, persistentID, hitCounter, maxHits, true)
            print("Apocalipse_TSY: Defensive exhausted fallback applied for pid="
                  .. tostring(persistentID) .. " onlineID=" .. tostring(zombieID))
            return
        end
    end

    print("Apocalipse_TSY: Tough hit apply failed pid=" .. tostring(persistentID)
          .. " onlineID=" .. tostring(zombieID) .. " exhausted=" .. tostring(isExhausted))
end

-- CLIENT-SIDE: Detect weapon hit on tough zombie then notify server
local function OnWeaponHitCharacter(attacker, target, weapon, damage)
    -- Only the attacker's client sends the command to avoid duplicates
    local player = getPlayer()
    if not player or attacker ~= player then
        return
    end

    -- Verify target is a living zombie
    if not instanceof(target, "IsoZombie") or not target:isAlive() then
        return
    end

    local modData = target:getModData()
    local toughnessType = modData.Apocalipse_TSY_ToughnessType
    if toughnessType == "tough" then
        local targetPID = RegionManager.Shared.GetReliablePID(target)
        local zombieID = target:getOnlineID()
        local hitCounter = tonumber(modData.Apocalipse_TSY_ToughnessHitCounter) or 0
        local maxHits = tonumber(modData.Apocalipse_TSY_ToughnessMaxHits) or RegionManager.Shared.DEFAULT_MAX_HITS

        -- Already exhausted: let normal PZ combat handle everything
        if hitCounter >= maxHits then
            return
        end

        -- Optimistic local application: immediately protect the zombie on this client
        -- The server will send the authoritative state back shortly
        target:setAvoidDamage(true)
        target:setKnockedDown(false)
        target:setStaggerBack(true)

        -- Send to server for authoritative processing
        sendClientCommand(player, "Apocalipse_TSY", "ZombieHitTough", {
            zombieID = zombieID,
            x = target:getX(),
            y = target:getY(),
            persistentID = targetPID
        })

        if targetPID then
            ToughHitPendingRef[targetPID] = {
                zombie = target,
                expiresAt = os.time() + TOUGH_HIT_REF_TTL_SEC,
            }
        end
    elseif target:avoidDamage() then 
        target:setAvoidDamage(false)
    end
end

-- Register the event handler (client-side only)
if not isServer() then
    Events.OnWeaponHitCharacter.Add(OnWeaponHitCharacter)
    print("Apocalipse_TSY: Networked toughness system initialized (OnWeaponHitCharacter)")
end


