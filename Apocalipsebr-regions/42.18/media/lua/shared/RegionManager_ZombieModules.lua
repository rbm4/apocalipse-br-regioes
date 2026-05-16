-- ============================================================================
-- File: media/lua/shared/RegionManager_ZombieModules.lua
-- Shared module registry for custom zombie types (boss zombies, special zombies).
-- External mods register their zombie definitions here by outfit name.
-- When the confirmZombie pipeline encounters a zombie whose outfit matches a
-- registered module, it uses the module's guaranteed stat overrides instead of
-- probabilistic region rolling.
--
-- Usage (server or client init):
--   require "RegionManager_ZombieModules"
--   RegionManager.ZombieModules.register({
--       id = "nemesis",
--       outfitNames = {"Nemesis"},
--       stats = { isSprinter = true, isTough = true, maxHits = 10, ... },
--       sounds = { ... },
--       behavior = { ... },
--   })
-- ============================================================================

require "RegionManager_Config"

RegionManager.ZombieModules = RegionManager.ZombieModules or {}

-- Outfit name -> moduleDef lookup (built on register)
RegionManager.ZombieModules._registry = RegionManager.ZombieModules._registry or {}
-- Module ID -> moduleDef lookup
RegionManager.ZombieModules._byId = RegionManager.ZombieModules._byId or {}

--- Register a custom zombie module.
--- After registration, any zombie whose outfit matches one of `moduleDef.outfitNames`
--- will receive guaranteed stat overrides and optional client-side sound/behavior.
---
---@param moduleDef table Module definition with the following shape:
---   id           string              Unique module identifier (e.g. "nemesis")
---   outfitNames  string[]            Outfit names that trigger this module
---   stats        table               Property overrides applied instead of region RNG:
---     isSprinter?        boolean
---     isShambler?        boolean
---     hawkVision?        boolean
---     badVision?         boolean
---     normalVision?      boolean
---     poorVision?        boolean
---     goodHearing?       boolean
---     badHearing?        boolean
---     pinpointHearing?   boolean
---     normalHearing?     boolean
---     poorHearing?       boolean
---     isResistant?       boolean
---     isTough?           boolean
---     isNormalToughness? boolean
---     isFragile?         boolean
---     isSuperhuman?      boolean
---     isWeak?            boolean
---     hasNavigation?     boolean
---     hasMemoryLong?     boolean
---     hasMemoryNormal?   boolean
---     hasMemoryShort?    boolean
---     hasMemoryNone?     boolean
---     hasMemoryRandom?   boolean
---     maxHits?           number       Extra hits for tough zombies (1-99)
---     bossHealth?        number       Direct health override (applied after toughness)
---     killBonus?         number       Flat kill bonus (overrides computed value)
---   sounds       table|nil           Client-side sound configuration:
---     suppressVanilla  boolean        Stop vanilla zombie voice sounds
---     theme?           table          { name=string, range=number, loop=boolean }
---     onDetect?        table          { name=string, range=number }
---     periodic?        table[]        { { names=string[], cooldownTicks=number, chance=number }, ... }
---     onHit?           table[]        { { names=string[], chance=number }, ... }
---   behavior     table|nil           Client-side behavior configuration:
---     redirectToPlayer?      boolean  Pathfind to owning player
---     redirectCooldownTicks? number   Ticks between redirect attempts
---     detectionRange?        number   Max distance (tiles) for tracking
---     smashObstacles?        boolean  Damage/destroy windows and doors blocking the path
---     smashCooldownTicks?    number   Ticks between smash attempts (default 60)
---     smashDamage?           number   Damage per smash tick to barricades/doors (default 25)
function RegionManager.ZombieModules.register(moduleDef)
    if not moduleDef or not moduleDef.id then
        print("RegionManager.ZombieModules: ERROR - register() requires an 'id' field")
        return
    end
    if not moduleDef.outfitNames or #moduleDef.outfitNames == 0 then
        print("RegionManager.ZombieModules: ERROR - register() requires 'outfitNames' (non-empty)")
        return
    end
    if not moduleDef.stats then
        moduleDef.stats = {}
    end

    -- Store by ID
    RegionManager.ZombieModules._byId[moduleDef.id] = moduleDef

    -- Index by each outfit name for O(1) lookup
    for _, outfitName in ipairs(moduleDef.outfitNames) do
        if RegionManager.ZombieModules._registry[outfitName] then
            print("RegionManager.ZombieModules: WARNING - outfit '" .. outfitName ..
                  "' already registered by module '" ..
                  RegionManager.ZombieModules._registry[outfitName].id ..
                  "', overwriting with '" .. moduleDef.id .. "'")
        end
        RegionManager.ZombieModules._registry[outfitName] = moduleDef
    end

    print("RegionManager.ZombieModules: Registered module '" .. moduleDef.id ..
          "' for outfits: " .. table.concat(moduleDef.outfitNames, ", "))
end

--- Look up a registered module by outfit name.
---@param outfitName string
---@return table|nil moduleDef
function RegionManager.ZombieModules.getByOutfit(outfitName)
    if not outfitName then return nil end
    return RegionManager.ZombieModules._registry[outfitName]
end

--- Look up a registered module by its ID.
---@param moduleId string
---@return table|nil moduleDef
function RegionManager.ZombieModules.getById(moduleId)
    if not moduleId then return nil end
    return RegionManager.ZombieModules._byId[moduleId]
end

--- Build a decisions table from a module's stats.
--- Returns a table compatible with the confirmZombie pipeline (same shape as
--- ZombieHelper.RollDecisions output), with `_moduleId` set.
---@param moduleDef table Registered module definition
---@param x number World X coordinate
---@param y number World Y coordinate
---@return table decisions
function RegionManager.ZombieModules.buildDecisions(moduleDef, x, y)
    local s = moduleDef.stats
    return {
        _moduleId               = moduleDef.id,
        isSprinter              = s.isSprinter or false,
        isShambler              = s.isShambler or false,
        hawkVision              = s.hawkVision or false,
        badVision               = s.badVision or false,
        normalVision            = s.normalVision or false,
        poorVision              = s.poorVision or false,
        randomVision            = s.randomVision or false,
        goodHearing             = s.goodHearing or false,
        badHearing              = s.badHearing or false,
        pinpointHearing         = s.pinpointHearing or false,
        normalHearing           = s.normalHearing or false,
        poorHearing             = s.poorHearing or false,
        randomHearing           = s.randomHearing or false,
        hasArmor                = s.hasArmor or false,
        isResistant             = s.isResistant or false,
        isTough                 = s.isTough or false,
        isNormalToughness       = s.isNormalToughness or false,
        isFragile               = s.isFragile or false,
        isRandomToughness       = false,
        isSuperhuman            = s.isSuperhuman or false,
        isNormalToughness2      = false,
        isWeak                  = s.isWeak or false,
        isRandomToughness2      = false,
        hasNavigation           = s.hasNavigation or false,
        hasMemoryLong           = s.hasMemoryLong or false,
        hasMemoryNormal         = s.hasMemoryNormal or false,
        hasMemoryShort          = s.hasMemoryShort or false,
        hasMemoryNone           = s.hasMemoryNone or false,
        hasMemoryRandom         = s.hasMemoryRandom or false,
        armorEffectivenessMultiplier = s.armorEffectivenessMultiplier or 0,
        armorDefensePercentage       = s.armorDefensePercentage or 0,
        maxHits                 = s.maxHits or RegionManager.Shared.DEFAULT_MAX_HITS,
        x                       = math.floor(x),
        y                       = math.floor(y),
    }
end
