-- ============================================================================
-- File: media/lua/client/RegionManager_ZombieModuleClient.lua
-- Client-side sound and behavior engine for registered zombie modules.
-- Handles theme music, periodic sounds, onHit sounds, vanilla sound
-- suppression, and AI redirect for any zombie matched to a module via the
-- confirmZombie pipeline.
--
-- Zombies are tracked by onlineID after the server confirms them with a
-- module ID (args.m in the ConfirmZombie payload). This file does NOT scan
-- all zombies - it only operates on explicitly initialized zombies.
-- ============================================================================

if isServer() then
    return
end

require "RegionManager_Config"
require "RegionManager_ZombieModules"
require "RegionManager_ZombieShared"

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

--- Check whether a zombie's current outfit matches any of a module's outfitNames.
--- Also accepts zombies force-flagged via modData (e.g. mid-game conversions where
--- dressInNamedOutfit doesn't sync the outfit name).
---@param zombie IsoZombie
---@param moduleDef table
---@return boolean
local function outfitMatchesModule(zombie, moduleDef)
    if not moduleDef or not moduleDef.outfitNames then return false end
    -- Force-flagged zombies always match their assigned module
    local modData = zombie:getModData()
    if modData.Apocalipse_TSY_ForceModuleId == moduleDef.id then return true end
    local outfit = zombie:getOutfitName()
    if not outfit then return false end
    for _, name in ipairs(moduleDef.outfitNames) do
        if outfit == name then return true end
    end
    return false
end

--- Initialize tracking for a module zombie after ConfirmZombie.
---@param zombie IsoZombie
---@param moduleId string  The module ID from the server payload (args.m)
---@param opts table|nil   Optional convergence hints: { expectedOutfit, expectedToughness }
function RegionManager.ZombieModuleClient.initZombie(zombie, moduleId, opts)
    if not zombie or not moduleId then return end

    local moduleDef = RegionManager.ZombieModules.getById(moduleId)
    if not moduleDef then
        print("RegionManager.ZombieModuleClient: Unknown module '" .. tostring(moduleId) .. "'")
        return
    end

    -- Only track zombies whose outfit actually matches the module definition
    if not outfitMatchesModule(zombie, moduleDef) then
        print("RegionManager.ZombieModuleClient: Zombie outfit '" ..
              tostring(zombie:getOutfitName()) .. "' does not match module '" ..
              moduleId .. "', skipping")
        return
    end

    local id = RegionManager.Shared.GetReliablePID(zombie)

    -- Build periodic sound state (one timer per periodic entry)
    local periodicState = {}
    if moduleDef.sounds and moduleDef.sounds.periodic then
        for idx, _ in ipairs(moduleDef.sounds.periodic) do
            periodicState[idx] = { lastTick = tickCounter }
        end
    end

    trackedZombies[id] = {
        moduleDef        = moduleDef,
        themePlaying     = false,
        themeInstance    = nil,
        detectPlayed     = false,
        periodicState    = periodicState,
        lastRedirectTick = 0,
        -- Convergence hints: self-heal outfit/toughness if they drift
        expectedOutfit    = opts and opts.expectedOutfit or nil,
        expectedToughness = opts and opts.expectedToughness or nil,
    }
end

--- Remove a tracked entry by reliable PID.
--- Called when a zombie is (re)spawned on the client to discard any stale
--- tracking from a previous zombie that shared the same persistent ID (e.g.
--- recycled onlineID, chunk reload). Safe no-op when no entry exists.
---@param pid string|nil
function RegionManager.ZombieModuleClient.clearTrackedByPID(pid)
    if not pid then return end
    if trackedZombies[pid] then
        trackedZombies[pid] = nil
    end
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
-- Obstacle smashing: when a module zombie is stuck hitting a window or door,
-- damage/destroy it so the zombie can continue pursuing the player.
-- Only runs on the owning client (zombie:isLocal()).
-- ============================================================================

--- Damage or destroy a window the zombie is adjacent to.
---@param zombie IsoZombie
---@param window IsoWindow
---@param damagePer number  Damage per smash tick
local function smashWindow(zombie, window, damagePer)
    if not window then return end
    -- Destroy barricade first, then the window itself
    local barricade = window:getBarricadeForCharacter(zombie)
    if barricade then
        barricade:Damage(damagePer)
        return
    end
    -- If the window has glass / is not broken, smash it
    if not window:isSmashed() then
        window:smashWindow()
        return
    end
    -- Broken and no barricade: the path should be clear now
end

--- Damage a door / barricaded door the zombie is adjacent to.
---@param zombie IsoZombie
---@param door IsoThumpable|IsoDoor
---@param damagePer number  Damage per smash tick
local function smashDoor(zombie, door, damagePer)
    if not door then return end
    -- If the door is openable (unlocked), just open it
    if instanceof(door, "IsoDoor") then
        if not door:isLocked() and not door:isBarricaded() then
            door:ToggleDoor(zombie)
            return
        end
    end
    -- Damage through the thumpable interface
    if door.Damage then
        door:Damage(damagePer)
    elseif door.damage then
        door:damage(damagePer)
    end
end

--- Scan the zombie's current square and adjacent squares for obstacles.
--- Returns the first window or door found, or nil.
---@param zombie IsoZombie
---@return IsoWindow|nil, IsoThumpable|IsoDoor|nil
local function findAdjacentObstacle(zombie)
    local sq = zombie:getSquare()
    if not sq then return nil, nil end

    -- Check objects on the zombie's square and immediate neighbours
    local squares = { sq }
    for dir = 0, 3 do
        local adj = sq:getAdjacentSquare(dir)
        if adj then squares[#squares + 1] = adj end
    end

    for _, checkSq in ipairs(squares) do
        local objects = checkSq:getObjects()
        if objects then
            for j = 0, objects:size() - 1 do
                local obj = objects:get(j)
                if obj then
                    if instanceof(obj, "IsoWindow") then
                        return obj, nil
                    end
                    if instanceof(obj, "IsoDoor") or
                       (instanceof(obj, "IsoThumpable") and obj:isDoor()) then
                        return nil, obj
                    end
                end
            end
        end
    end
    return nil, nil
end

-- ============================================================================
-- OnZombieUpdate - process tracked module zombies only
-- ============================================================================

local function onZombieUpdate(zombie)
    if not zombie then return end

    local id = RegionManager.Shared.GetReliablePID(zombie)
    local data = trackedZombies[id]
    if not data then return end

    -- Dead zombie: fade out theme and clean up
    if zombie:isDead() then
        beginThemeFadeOut(zombie, data)
        trackedZombies[id] = nil
        return
    end

    -- Validate outfit still matches the module (guards against recycled onlineIDs)
    if not outfitMatchesModule(zombie, data.moduleDef) then
        beginThemeFadeOut(zombie, data)
        trackedZombies[id] = nil
        return
    end

    local moduleDef = data.moduleDef
    local behavior = moduleDef.behavior or {}
    local sounds = moduleDef.sounds or {}
    local detectionRange = behavior.detectionRange or 80

    -- ----------------------------------------------------------------
    -- Convergence: self-heal outfit and toughness if they diverged
    -- (e.g. makeInactive cycle reset them, late join, etc.)
    -- ----------------------------------------------------------------
    if data.expectedOutfit then
        local curOutfit = zombie:getOutfitName()
        if curOutfit ~= data.expectedOutfit then
            if not data._outfitFixLogged then
                print("[ZMC-Converge] z=" .. tostring(id) ..
                      " outfit mismatch: got='" .. tostring(curOutfit) ..
                      "' expected='" .. tostring(data.expectedOutfit) .. "', fixing")
                data._outfitFixLogged = true
            end
            zombie:dressInNamedOutfit(data.expectedOutfit)
            zombie:resetModelNextFrame()
        else
            -- Outfit matched; allow logging again if it drifts later
            data._outfitFixLogged = nil
        end
    end

    -- Toughness convergence: repair modData if ownership transfer or
    -- makeInactive cycle wiped the toughness fields.
    if data.expectedToughness then
        local modData = zombie:getModData()
        local curType = modData.Apocalipse_TSY_ToughnessType
        -- Only converge if not exhausted (exhausted = system disengaged)
        if curType ~= "exhausted" then
            local expected = data.expectedToughness
            local needsFix = false
            if curType ~= expected.type then
                needsFix = true
            end
            local curMax = tonumber(modData.Apocalipse_TSY_ToughnessMaxHits)
            if curMax ~= expected.maxHits then
                needsFix = true
            end
            if needsFix then
                if not data._toughFixLogged then
                    print("[ZMC-Converge] z=" .. tostring(id) ..
                          " toughness mismatch: type=" .. tostring(curType) ..
                          " maxHits=" .. tostring(curMax) ..
                          " expected=" .. tostring(expected.type) ..
                          "/" .. tostring(expected.maxHits) .. ", fixing")
                    data._toughFixLogged = true
                end
                modData.Apocalipse_TSY_ToughnessType = expected.type
                modData.Apocalipse_TSY_ToughnessMaxHits = expected.maxHits
                -- Preserve existing hit counter (never reset to 0)
                if not modData.Apocalipse_TSY_ToughnessHitCounter then
                    modData.Apocalipse_TSY_ToughnessHitCounter = 0
                end
            else
                data._toughFixLogged = nil
            end
        end
    end

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

        -- Obstacle smashing: if the zombie is stuck on a window/door, break
        -- through it and re-redirect to the player.
        if behavior.smashObstacles then
            local smashCooldown = behavior.smashCooldownTicks or 60
            if not data.lastSmashTick then data.lastSmashTick = 0 end
            if (tickCounter - data.lastSmashTick) >= smashCooldown then
                local target = zombie:getTarget()
                -- If zombie is targeting something that isn't a player,
                -- check for adjacent obstacles.
                local isStuck = false
                if target then
                    isStuck = not instanceof(target, "IsoPlayer")
                end
                if isStuck then
                    local dmg = behavior.smashDamage or 100
                    local window, door = findAdjacentObstacle(zombie)
                    if window then
                        smashWindow(zombie, window, dmg)
                        data.lastSmashTick = tickCounter
                    elseif door then
                        smashDoor(zombie, door, dmg)
                        data.lastSmashTick = tickCounter
                    end
                    -- Re-redirect immediately after clearing obstacle
                    zombie:pathToLocationF(player:getX(), player:getY(), player:getZ())
                    data.lastRedirectTick = tickCounter
                end
            end
        end
    end
end

-- ============================================================================
-- OnWeaponHitCharacter - hit sounds for tracked module zombies
-- ============================================================================

local function onWeaponHitCharacter(attacker, target, weapon, damage)
    local player = getPlayer()
    if not player or attacker ~= player then return end
    if not instanceof(target, "IsoZombie") or not target:isAlive() then return end

    local id = RegionManager.Shared.GetReliablePID(target)
    local data = trackedZombies[id]
    if not data then return end

    playHitSounds(target, data.moduleDef)
end

-- ============================================================================
-- Tick counter + periodic outfit enforcement
-- OnZombieUpdate doesn't fire every frame, so we enforce outfit on a fixed
-- schedule by scanning all tracked zombies from the cell zombie list.
-- ============================================================================

local OUTFIT_ENFORCE_INTERVAL = 30  -- ~0.5 seconds at 60 FPS

local function onTick()
    tickCounter = tickCounter + 1
    tickFadingThemes()

    -- Periodic outfit enforcement for tracked module zombies
    if tickCounter % OUTFIT_ENFORCE_INTERVAL == 0 then
        local player = getPlayer()
        if not player then return end
        local cell = player:getCell()
        if not cell then return end
        local zombieList = cell:getZombieList()
        if not zombieList then return end

        for i = 0, zombieList:size() - 1 do
            local zombie = zombieList:get(i)
            if zombie and not zombie:isDead() then
                local pid = RegionManager.Shared.GetReliablePID(zombie)
                local data = trackedZombies[pid]
                if data and data.expectedOutfit then
                    local curOutfit = zombie:getOutfitName()
                    if curOutfit ~= data.expectedOutfit then
                        zombie:dressInNamedOutfit(data.expectedOutfit)
                        zombie:resetModelNextFrame()
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- Register event hooks
-- ============================================================================

Events.OnZombieUpdate.Add(onZombieUpdate)
Events.OnWeaponHitCharacter.Add(onWeaponHitCharacter)
Events.OnTick.Add(onTick)