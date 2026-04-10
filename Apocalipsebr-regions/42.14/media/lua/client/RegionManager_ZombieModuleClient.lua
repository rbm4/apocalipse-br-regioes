-- ============================================================================
-- File: media/lua/client/RegionManager_ZombieModuleClient.lua
-- Client-side sound and behavior engine for registered zombie modules.
-- Handles theme music, periodic sounds, onHit sounds, vanilla sound
-- suppression, and AI redirect for any zombie matched to a module via the
-- confirmZombie pipeline.
--
-- Zombies are tracked by onlineID after the server confirms them with a
-- module ID (args.m in the ConfirmZombie payload). This file does NOT scan
-- all zombies — it only operates on explicitly initialized zombies.
-- ============================================================================

if isServer() then
    return
end

require "RegionManager_Config"
require "RegionManager_ZombieModules"

RegionManager.ZombieModuleClient = RegionManager.ZombieModuleClient or {}

-- Tracked module zombies: [onlineID] = { moduleDef, state... }
local trackedZombies = {}
local tickCounter = 0

-- ============================================================================
-- Theme fade-out system
-- Decoupled from zombie lifecycle so fades finish even after zombie death/removal.
-- Each entry: { emitter, instance, volume }
-- ============================================================================
local fadingThemes = {}
local FADE_DURATION_TICKS = 180  -- ~3 seconds at 60 FPS
local FADE_STEP = 1.0 / FADE_DURATION_TICKS

-- ============================================================================
-- Vanilla sound names to suppress when a module requests it
-- ============================================================================
local VANILLA_VOICE_SOUNDS = {
    "ZombieVoiceSprinting",
    "ZombieVoice",
    "MaleZombieVoice",
    "FemaleZombieVoice",
}

-- ============================================================================
-- Public API: called from RegionManager_ZombieClient on ConfirmZombie
-- ============================================================================

--- Initialize tracking for a module zombie after ConfirmZombie.
---@param zombie IsoZombie
---@param moduleId string  The module ID from the server payload (args.m)
function RegionManager.ZombieModuleClient.initZombie(zombie, moduleId)
    if not zombie or not moduleId then return end

    local moduleDef = RegionManager.ZombieModules.getById(moduleId)
    if not moduleDef then
        print("RegionManager.ZombieModuleClient: Unknown module '" .. tostring(moduleId) .. "'")
        return
    end

    local id = zombie:getOnlineID()

    -- Build periodic sound state (one timer per periodic entry)
    local periodicState = {}
    if moduleDef.sounds and moduleDef.sounds.periodic then
        for idx, _ in ipairs(moduleDef.sounds.periodic) do
            periodicState[idx] = { lastTick = tickCounter }
        end
    end

    trackedZombies[id] = {
        moduleDef       = moduleDef,
        themePlaying     = false,
        themeInstance    = nil,
        detectPlayed     = false,
        periodicState    = periodicState,
        lastRedirectTick = 0,
    }
end

-- ============================================================================
-- Sound helpers
-- ============================================================================

local function suppressVanillaSounds(zombie)
    local emitter = zombie:getEmitter()
    if not emitter then return end
    for _, soundName in ipairs(VANILLA_VOICE_SOUNDS) do
        if emitter:isPlaying(soundName) then
            emitter:stopSoundByName(soundName)
        end
    end
end

local function startTheme(zombie, data)
    if data.themePlaying then return end
    local sounds = data.moduleDef.sounds
    if not sounds or not sounds.theme then return end

    local emitter = zombie:getEmitter()
    if emitter then
        data.themeInstance = emitter:playSound(sounds.theme.name)
        data.themePlaying = true
        data.themeEmitter = emitter
    end
end

--- Begin a gradual fade-out of the theme music instead of stopping abruptly.
--- The emitter + instance are moved to the fadingThemes list so the fade
--- continues even after the zombie dies or goes out of range.
local function beginThemeFadeOut(zombie, data)
    if not data.themePlaying then return end
    -- Move to fading list
    if data.themeEmitter and data.themeInstance then
        table.insert(fadingThemes, {
            emitter  = data.themeEmitter,
            instance = data.themeInstance,
            volume   = 1.0,
        })
    end
    data.themePlaying = false
    data.themeInstance = nil
    data.themeEmitter = nil
end

--- Process all active fade-outs. Called once per tick.
local function tickFadingThemes()
    local i = 1
    while i <= #fadingThemes do
        local entry = fadingThemes[i]
        entry.volume = entry.volume - FADE_STEP
        if entry.volume <= 0 then
            -- Fade complete: stop sound and remove entry
            local ok, _ = pcall(entry.emitter.stopSound, entry.emitter, entry.instance)
            -- Swap-remove for O(1) deletion
            fadingThemes[i] = fadingThemes[#fadingThemes]
            fadingThemes[#fadingThemes] = nil
        else
            -- Reduce volume
            local ok, _ = pcall(entry.emitter.setVolume, entry.emitter, entry.instance, entry.volume)
            if not ok then
                -- Emitter became invalid (zombie removed from world), drop it
                fadingThemes[i] = fadingThemes[#fadingThemes]
                fadingThemes[#fadingThemes] = nil
            else
                i = i + 1
            end
        end
    end
end

local function playDetectSound(zombie, data)
    if data.detectPlayed then return end
    local sounds = data.moduleDef.sounds
    if not sounds or not sounds.onDetect then return end

    local sq = zombie:getSquare()
    if sq then
        getSoundManager():PlayWorldSound(sounds.onDetect.name, sq, 0, 1.0, 1.0, false)
        data.detectPlayed = true
    end
end

local function playPeriodicSounds(zombie, data)
    local sounds = data.moduleDef.sounds
    if not sounds or not sounds.periodic then return end

    local sq = zombie:getSquare()
    if not sq then return end

    for idx, def in ipairs(sounds.periodic) do
        local state = data.periodicState[idx]
        if state and (tickCounter - state.lastTick) >= def.cooldownTicks then
            if ZombRand(100) < def.chance then
                local soundName = def.names[ZombRand(#def.names) + 1]
                getSoundManager():PlayWorldSound(soundName, sq, 0, 0.7, 1.0, false)
            end
            state.lastTick = tickCounter
        end
    end
end

local function playHitSounds(zombie, moduleDef)
    local sounds = moduleDef.sounds
    if not sounds or not sounds.onHit then return end

    local sq = zombie:getSquare()
    if not sq then return end

    for _, def in ipairs(sounds.onHit) do
        if ZombRand(100) < def.chance then
            local soundName = def.names[ZombRand(#def.names) + 1]
            getSoundManager():PlayWorldSound(soundName, sq, 0, 0.6, 1.0, false)
        end
    end
end

-- ============================================================================
-- Distance helper
-- ============================================================================

local function getDistSq(a, b)
    local dx = a:getX() - b:getX()
    local dy = a:getY() - b:getY()
    return dx * dx + dy * dy
end

-- ============================================================================
-- OnZombieUpdate — process tracked module zombies only
-- ============================================================================

local function onZombieUpdate(zombie)
    if not zombie then return end

    local id = zombie:getOnlineID()
    local data = trackedZombies[id]
    if not data then return end

    -- Dead zombie: fade out theme and clean up
    if zombie:isDead() then
        beginThemeFadeOut(zombie, data)
        trackedZombies[id] = nil
        return
    end

    local moduleDef = data.moduleDef
    local behavior = moduleDef.behavior or {}
    local sounds = moduleDef.sounds or {}
    local detectionRange = behavior.detectionRange or 80

    local player = getPlayer()
    if not player or player:isDead() then return end

    local distSq = getDistSq(zombie, player)
    local detectionSq = detectionRange * detectionRange

    -- Out of detection range: fade out sounds, don't remove tracking
    if distSq > detectionSq then
        beginThemeFadeOut(zombie, data)
        return
    end

    -- Suppress vanilla voice sounds every tick for this zombie
    if sounds.suppressVanilla then
        suppressVanillaSounds(zombie)
    end

    -- Detection announcement (once per encounter)
    if sounds.onDetect then
        local detectRange = sounds.onDetect.range or 40
        if distSq <= (detectRange * detectRange) then
            playDetectSound(zombie, data)
        end
    end

    -- Theme music: distance-based start/stop
    if sounds.theme then
        local themeRange = sounds.theme.range or 60
        if distSq <= (themeRange * themeRange) then
            startTheme(zombie, data)
        else
            beginThemeFadeOut(zombie, data)
        end
    end

    -- Periodic sounds (roars, etc.)
    playPeriodicSounds(zombie, data)

    -- AI redirect to player (only owning client)
    if behavior.redirectToPlayer and zombie:isLocal() then
        local cooldown = behavior.redirectCooldownTicks or 300
        if (tickCounter - data.lastRedirectTick) >= cooldown then
            zombie:pathToLocationF(player:getX(), player:getY(), player:getZ())
            data.lastRedirectTick = tickCounter
        end
    end
end

-- ============================================================================
-- OnWeaponHitCharacter — hit sounds for tracked module zombies
-- ============================================================================

local function onWeaponHitCharacter(attacker, target, weapon, damage)
    local player = getPlayer()
    if not player or attacker ~= player then return end
    if not instanceof(target, "IsoZombie") or not target:isAlive() then return end

    local id = target:getOnlineID()
    local data = trackedZombies[id]
    if not data then return end

    playHitSounds(target, data.moduleDef)
end

-- ============================================================================
-- Tick counter
-- ============================================================================

local function onTick()
    tickCounter = tickCounter + 1
    tickFadingThemes()
end

-- ============================================================================
-- Register event hooks
-- ============================================================================

Events.OnZombieUpdate.Add(onZombieUpdate)
Events.OnWeaponHitCharacter.Add(onWeaponHitCharacter)
Events.OnTick.Add(onTick)
