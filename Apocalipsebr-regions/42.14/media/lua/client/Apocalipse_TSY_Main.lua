--        __     __                   
-- _|_   (_ ||\/|__) /\ _ _ _ _|   _  
--  |    __)||  |__)/--|_| (_(_||_|/_ 
--                     |              


-- SLOTS DE VOZ
local Apocalipse_TSY_MaxSlots             = 62     -- quantidade de slots de voz ABMIS (1..128)

-- DISTÂNCIAS (EM TILES)
local Apocalipse_TSY_FarRange             = 150    -- distância máxima para grito de descoberta
local Apocalipse_TSY_NearRange            = 8      -- distância para grito na cara

-- VOLUME / ESCALA GLOBAL
local Apocalipse_TSY_GlobalVolume         = 1.0    -- multiplicador global de volume TSY
local Apocalipse_TSY_FarVolume            = 0.08   -- volume base do grito de descoberta
local Apocalipse_TSY_NearVolume           = 1.0    -- multiplicador relativo para grito na cara
local Apocalipse_TSY_DayVolumeMult        = 1.0    -- multiplicador de volume durante o dia
local Apocalipse_TSY_NightVolumeMult      = 1.0    -- multiplicador de volume durante a noite

-- CHANCES (%) DE GRITO
local Apocalipse_TSY_DefaultScreechChance = 60     -- chance de grito de descoberta ao ver o player
local Apocalipse_TSY_ChaseScreechChance   = 50     -- chance de grito durante perseguição (0 = desligado)

-- ALERTA / HORDA
local Apocalipse_TSY_AlertRadiusDefault   = 80     -- raio para puxar horda com addSound
local Apocalipse_TSY_AlertEnabledDefault  = true   -- se puxar horda vem ligado por padrão

-- CLUSTER (ANTI-SPAM DE GRITOS)
local Apocalipse_TSY_ClusterRadius        = 35     -- raio para agrupar gritos no mesmo cluster
local Apocalipse_TSY_ClusterCooldownHours = 0.01   -- ~36 segundos de janela de tempo por cluster
local Apocalipse_TSY_MaxClusterScreams    = 1      -- máximo de gritos dentro do mesmo cluster e janela

-- PERSEGUIÇÃO / GRITO NA CARA
local Apocalipse_TSY_ChaseCooldownHours   = 0.03   -- cooldown entre tentativas de grito de perseguição
local Apocalipse_TSY_NearDelayTicks       = 10     -- ticks de atraso para o grito na cara depois de entrar no range

-- CONTEXTO DIA / NOITE
local Apocalipse_TSY_DayNightMode         = 0      -- 0 = dia e noite, 1 = só dia, 2 = só noite
local Apocalipse_TSY_NightThreshold       = 0.5    -- nightStrength a partir do qual consideramos "noite"

-- LIMITE / FASE DE PERSEGUIÇÃO
local Apocalipse_TSY_MaxScreamsPerZombie  = 3      -- descoberta, na cara, perseguição longa
local Apocalipse_TSY_ChaseMinDelayHours   = 0.02   -- tempo mínimo desde o último grito para poder gritar em perseguição

-- PERFORMANCE
local Apocalipse_TSY_DefaultTickRate            = 6      -- quantos frames entre cada processamento por zumbi (6 ≈ a cada 0.1s em 60 FPS)
local Apocalipse_TSY_DefaultMaxDistance         = 220    -- distância máxima (em tiles) para sequer considerar o zumbi
local Apocalipse_TSY_MaxClusterEvents           = 200    -- hard limit na tabela de clusters (segurança extra)

local Apocalipse_TSY_ClimateManager = nil
local Apocalipse_TSY_Bag            = {}
local Apocalipse_TSY_LastVoiceIndex = nil
local Apocalipse_TSY_ClusterEvents  = {}

local Apocalipse_TSY_CachedWorldHours     = 0
local Apocalipse_TSY_TickCounter          = 0

-- FRAME CACHE — populated once per tick, read per-zombie (eliminates per-zombie per-frame calls)
local Apocalipse_TSY_CachedPlayer         = nil
local Apocalipse_TSY_CachedPX             = 0
local Apocalipse_TSY_CachedPY             = 0
local Apocalipse_TSY_CachedTimeAllowed    = false
local Apocalipse_TSY_CachedVars           = nil
local Apocalipse_TSY_CachedTickRate       = 12
local Apocalipse_TSY_CachedFarRange       = 150
local Apocalipse_TSY_CachedMaxProcessDist = 220
local Apocalipse_TSY_CachedScreechChance  = 60
local Apocalipse_TSY_CachedChaseChance    = 50
local Apocalipse_TSY_CachedEnableNear     = true

local function Apocalipse_TSY_GetSandbox()
    if SandboxVars and SandboxVars.Apocalipse_TSY then
        return SandboxVars.Apocalipse_TSY
    end
    return nil
end

local function Apocalipse_TSY_GetWorldTimeHours()

    return Apocalipse_TSY_CachedWorldHours
end

local function Apocalipse_TSY_GetNightStrength()
    if not Apocalipse_TSY_ClimateManager then
        Apocalipse_TSY_ClimateManager = getClimateManager()
    end
    if Apocalipse_TSY_ClimateManager then
        return Apocalipse_TSY_ClimateManager:getNightStrength()
    end
    return 0
end

local function Apocalipse_TSY_GetPeriodVolumeMult()
    local nightStrength = Apocalipse_TSY_GetNightStrength()
    if nightStrength > Apocalipse_TSY_NightThreshold then
        return Apocalipse_TSY_NightVolumeMult
    else
        return Apocalipse_TSY_DayVolumeMult
    end
end

local function Apocalipse_TSY_TimeAllowed()
    local vars = Apocalipse_TSY_GetSandbox()
    local mode = Apocalipse_TSY_DayNightMode
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

local function Apocalipse_TSY_RefillBag()
    Apocalipse_TSY_Bag = {}
    for i = 1, Apocalipse_TSY_MaxSlots do
        Apocalipse_TSY_Bag[#Apocalipse_TSY_Bag + 1] = i
    end
    for i = #Apocalipse_TSY_Bag, 2, -1 do
        local j = ZombRand(1, i + 1)
        Apocalipse_TSY_Bag[i], Apocalipse_TSY_Bag[j] = Apocalipse_TSY_Bag[j], Apocalipse_TSY_Bag[i]
    end
end

local function Apocalipse_TSY_NextVoice()
    if #Apocalipse_TSY_Bag == 0 then
        Apocalipse_TSY_RefillBag()
    end
    local idx = table.remove(Apocalipse_TSY_Bag)
    if Apocalipse_TSY_LastVoiceIndex ~= nil and Apocalipse_TSY_MaxSlots > 1 and idx == Apocalipse_TSY_LastVoiceIndex then
        if #Apocalipse_TSY_Bag == 0 then
            Apocalipse_TSY_RefillBag()
        end
        local alt = table.remove(Apocalipse_TSY_Bag)
        Apocalipse_TSY_Bag[#Apocalipse_TSY_Bag + 1] = idx
        idx = alt
    end
    Apocalipse_TSY_LastVoiceIndex = idx
    return idx
end

local function Apocalipse_TSY_GetSoundName(index)
    return "Apocalipse_TSY_" .. tostring(index)
end

local function Apocalipse_TSY_Delay(func, delay)
    delay = delay or 1
    local ticks = 0
    local canceled = false
    local function onTick()
        if canceled then
            Events.OnTick.Remove(onTick)
            return
        end
        if ticks < delay then
            ticks = ticks + 1
            return
        end
        Events.OnTick.Remove(onTick)
        if not canceled then
            func()
        end
    end
    Events.OnTick.Add(onTick)
    return function()
        canceled = true
    end
end

local function Apocalipse_TSY_CanClusterScream(x, y, timeNow, vars)
    -- Expired events are pruned once per frame in OnTick; only count active events here.
    local radius     = Apocalipse_TSY_ClusterRadius
    local maxCluster = Apocalipse_TSY_MaxClusterScreams

    if vars then
        if vars.ClusterRadius and vars.ClusterRadius > 0 then
            radius = vars.ClusterRadius
        end
        if vars.MaxClusterScreams and vars.MaxClusterScreams > 0 then
            maxCluster = vars.MaxClusterScreams
        end
    end

    local radiusSq = radius * radius
    local count    = 0

    for i = 1, #Apocalipse_TSY_ClusterEvents do
        local ev = Apocalipse_TSY_ClusterEvents[i]
        local dx = x - ev.x
        local dy = y - ev.y
        if dx * dx + dy * dy <= radiusSq then
            count = count + 1
            if count >= maxCluster then
                return false
            end
        end
    end

    return true
end

local function Apocalipse_TSY_RegisterClusterScream(x, y, timeNow)
    if #Apocalipse_TSY_ClusterEvents >= Apocalipse_TSY_MaxClusterEvents then
        table.remove(Apocalipse_TSY_ClusterEvents, 1)
    end
    Apocalipse_TSY_ClusterEvents[#Apocalipse_TSY_ClusterEvents + 1] = { x = x, y = y, t = timeNow }
end

local function Apocalipse_TSY_PlayFarScream(zombie, voiceIndex, dist, vars)
    local soundName = Apocalipse_TSY_GetSoundName(voiceIndex)
    local maxDist   = Apocalipse_TSY_FarRange
    local baseVol   = Apocalipse_TSY_FarVolume
    local globalVol = Apocalipse_TSY_GlobalVolume

    if vars then
        if vars.FarRange and vars.FarRange > 0 then
            maxDist = vars.FarRange
        end
        if vars.FarVolume and vars.FarVolume > 0 then
            baseVol = vars.FarVolume
        end
        if vars.GlobalVolume and vars.GlobalVolume > 0 then
            globalVol = vars.GlobalVolume
        end
    end

    local periodMult = Apocalipse_TSY_GetPeriodVolumeMult()
    local falloff    = math.min(1.0, dist / maxDist)
    local vol        = globalVol * baseVol * periodMult * (1.0 - falloff * 0.6)

    local sq = zombie:getSquare()
    if sq then
        getSoundManager():PlayWorldSound(soundName, sq, 0, vol, 1.0, false)
    end
end

local function Apocalipse_TSY_ScheduleNearScream(zombie, voiceIndex, vars)
    local soundName = Apocalipse_TSY_GetSoundName(voiceIndex)
    local globalVol = Apocalipse_TSY_GlobalVolume
    local nearMult  = Apocalipse_TSY_NearVolume
    local useWorld  = false

    if vars then
        if vars.GlobalVolume and vars.GlobalVolume > 0 then
            globalVol = vars.GlobalVolume
        end
        if vars.NearVolume and vars.NearVolume > 0 then
            nearMult = vars.NearVolume
        end
        if vars.NearAsWorldSound ~= nil then
            useWorld = vars.NearAsWorldSound
        end
    end

    local periodMult = Apocalipse_TSY_GetPeriodVolumeMult()
    local vol        = globalVol * nearMult * periodMult

    Apocalipse_TSY_Delay(function()
        if zombie
            and not zombie:isDead()
            and (not zombie.isFakeDead or not zombie:isFakeDead())
            and (not zombie.isOnFloor or not zombie:isOnFloor())
        then
            if useWorld then
                local sq = zombie:getSquare()
                if sq then
                    getSoundManager():PlayWorldSound(soundName, sq, 0, vol, 1.0, false)
                end
            else
                zombie:playSound(soundName)
            end
        end
    end, Apocalipse_TSY_NearDelayTicks)
end


local function Apocalipse_TSY_TriggerAlert(playerObj, vars, screamingZombie)
    local enabled = Apocalipse_TSY_AlertEnabledDefault
    local radius  = Apocalipse_TSY_AlertRadiusDefault

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

    -- Mark the screaming zombie to ignore this alert temporarily
    if screamingZombie then
        local modData = screamingZombie:getModData()
        modData.Apocalipse_TSY_IgnoreAlertUntil = Apocalipse_TSY_TickCounter + 100
    end

    local x = playerObj:getX()
    local y = playerObj:getY()

    -- Reduced to single pulse to prevent animation thrashing
    addSound(playerObj, x, y, 0, radius, radius)
end

-- IsSprinter: zero Java-bridge reads.
-- RegionManager.ServerSideProperties writes modData.Apocalipse_TSY_ExpectedSpeed = "sprinter"
-- for every zombie it designates as a sprinter, and RevalidateZombieSpeed keeps it in sync.
-- We trust that flag instead of calling zombie:getVariableString("zombiewalktype").
local function Apocalipse_TSY_IsSprinter(modData)
    return modData.Apocalipse_TSY_ExpectedSpeed == "sprinter"
end




local function Apocalipse_TSY_OnZombieUpdate(zombie)

    if not zombie or zombie:isDead() or (zombie.isFakeDead and zombie:isFakeDead()) then
        return
    end

    if zombie.getVehicle and zombie:getVehicle() ~= nil then
        return
    end

    -- 2. Single modData access (original had a duplicate call that shadowed the first — bug fixed)
    local modData = zombie:getModData()

    -- 3. TickRate throttle BEFORE IsSprinter — avoids the Java bridge call N-1 frames out of every N
    local tickRate = Apocalipse_TSY_CachedTickRate
    if tickRate > 1 then
        local nextTick = modData.Apocalipse_TSY_NextTick or 0
        if Apocalipse_TSY_TickCounter < nextTick then
            return
        end
        modData.Apocalipse_TSY_NextTick = Apocalipse_TSY_TickCounter + tickRate
    end

    -- 4. Permanent done flag: zombie exhausted all screams, skip with a single bool read
    if modData.Apocalipse_TSY_Done then
        return
    end

    -- 5. Frame-cached checks — zero call overhead
    if not Apocalipse_TSY_CachedTimeAllowed then
        return
    end

    local player = Apocalipse_TSY_CachedPlayer
    if not player then
        return
    end

    -- 6. Skip registered module zombies (bosses) — they have their own sound system
    if modData.Apocalipse_TSY_IsModuleZombie then
        return
    end
    
    -- Skip if zombie should ignore alerts (recently screamed)
    if modData.Apocalipse_TSY_IgnoreAlertUntil and Apocalipse_TSY_TickCounter < modData.Apocalipse_TSY_IgnoreAlertUntil then
        return
    end
    
    -- 7. Target check
    if zombie.getTarget then
        local target = zombie:getTarget()
        if target ~= player then
            return
        end
    end

    -- 8. AABB coarse cull — pure math, cached player position, no sqrt
    local maxProcessDist = Apocalipse_TSY_CachedMaxProcessDist
    local zx = zombie:getX()
    local zy = zombie:getY()
    local px = Apocalipse_TSY_CachedPX
    local py = Apocalipse_TSY_CachedPY

    local dx = zx - px
    local dy = zy - py

    if dx > maxProcessDist or dx < -maxProcessDist or dy > maxProcessDist or dy < -maxProcessDist then
        return
    end

    -- 9. IsSprinter — pure modData flag read (zero Java-bridge cost)
    if not Apocalipse_TSY_IsSprinter(modData) then
        return
    end

    -- 10. Precise distance (sqrt)
    local farRange = Apocalipse_TSY_CachedFarRange
    local dist = zombie:DistTo(player)
    if not dist or dist < 0 or dist > farRange then
        return
    end

    -- 11. LOS raycast — most expensive call; reached only when truly in range
    if not zombie:CanSee(player) then
        return
    end

    -- 12. Scream limit check; stamp Done flag to avoid future re-entry cost
    local totalAny = modData.Apocalipse_TSY_ScreamCount or 0
    if Apocalipse_TSY_MaxScreamsPerZombie and Apocalipse_TSY_MaxScreamsPerZombie > 0 then
        if totalAny >= Apocalipse_TSY_MaxScreamsPerZombie then
            modData.Apocalipse_TSY_Done = true
            return
        end
    end

    -- All per-frame config already resolved in OnTick — no per-zombie var lookups needed
    local vars           = Apocalipse_TSY_CachedVars
    local timeNow        = Apocalipse_TSY_GetWorldTimeHours()
    local x              = zx
    local y              = zy
    local lastAny        = modData.Apocalipse_TSY_LastAnyScreamTime or 0
    local screechChance  = Apocalipse_TSY_CachedScreechChance
    local chaseChance    = Apocalipse_TSY_CachedChaseChance
    local enableNearScream = Apocalipse_TSY_CachedEnableNear

    local voiceIndex = modData.Apocalipse_TSY_VoiceIndex
    if not voiceIndex then
        voiceIndex = Apocalipse_TSY_NextVoice()
        modData.Apocalipse_TSY_VoiceIndex = voiceIndex
    end

    if not modData.Apocalipse_TSY_HasFarScreamed then

        if dist > Apocalipse_TSY_NearRange then
            if ZombRand(0, 100) <= screechChance then
                if Apocalipse_TSY_CanClusterScream(x, y, timeNow, vars) then
                    Apocalipse_TSY_PlayFarScream(zombie, voiceIndex, dist, vars)
                    Apocalipse_TSY_RegisterClusterScream(x, y, timeNow)
                    Apocalipse_TSY_TriggerAlert(player, vars, zombie)

                    totalAny = totalAny + 1
                    modData.Apocalipse_TSY_LastAnyScreamTime = timeNow
                    modData.Apocalipse_TSY_ScreamCount       = totalAny
                end
            end
        end

        modData.Apocalipse_TSY_HasFarScreamed = true

    else

        if enableNearScream and not modData.Apocalipse_TSY_HasNearScreamed and dist <= Apocalipse_TSY_NearRange then
            if Apocalipse_TSY_CanClusterScream(x, y, timeNow, vars) then
                Apocalipse_TSY_ScheduleNearScream(zombie, voiceIndex, vars)
                Apocalipse_TSY_RegisterClusterScream(x, y, timeNow)

                totalAny = totalAny + 1
                modData.Apocalipse_TSY_LastAnyScreamTime = timeNow
                modData.Apocalipse_TSY_ScreamCount       = totalAny
            end
            modData.Apocalipse_TSY_HasNearScreamed = true

        else

            local readyForChase = modData.Apocalipse_TSY_HasNearScreamed or (not enableNearScream)

            if readyForChase and dist > Apocalipse_TSY_NearRange then

                if Apocalipse_TSY_ChaseMinDelayHours and Apocalipse_TSY_ChaseMinDelayHours > 0 then
                    if (timeNow - lastAny) < Apocalipse_TSY_ChaseMinDelayHours then
                        return
                    end
                end

                local lastChase = modData.Apocalipse_TSY_LastChaseTime or 0
                local cooldown  = Apocalipse_TSY_ChaseCooldownHours

                if vars then
                    local vCooldown = tonumber(vars.ChaseCooldownHours)
                    if vCooldown and vCooldown > 0 then
                        cooldown = vCooldown
                    end
                end

                if cooldown and cooldown > 0 and timeNow - lastChase >= cooldown and chaseChance and chaseChance > 0 then
                    local roll = ZombRand(0, 100)
                    if roll <= chaseChance then
                        if Apocalipse_TSY_CanClusterScream(x, y, timeNow, vars) then
                            Apocalipse_TSY_PlayFarScream(zombie, voiceIndex, dist, vars)
                            Apocalipse_TSY_RegisterClusterScream(x, y, timeNow)
                            Apocalipse_TSY_TriggerAlert(player, vars, zombie)

                            totalAny = totalAny + 1
                            modData.Apocalipse_TSY_LastChaseTime      = timeNow
                            modData.Apocalipse_TSY_LastAnyScreamTime  = timeNow
                            modData.Apocalipse_TSY_ScreamCount        = totalAny
                        end
                    end
                end
            end
        end
    end
end


local function Apocalipse_TSY_OnZombieDead(zombie)
    local modData = zombie:getModData()
    modData.Apocalipse_TSY_VoiceIndex        = nil
    modData.Apocalipse_TSY_HasFarScreamed    = nil
    modData.Apocalipse_TSY_HasNearScreamed   = nil
    modData.Apocalipse_TSY_LastChaseTime     = nil
    modData.Apocalipse_TSY_LastAnyScreamTime = nil
    modData.Apocalipse_TSY_ScreamCount       = nil
    modData.Apocalipse_TSY_NextTick          = nil
    modData.Apocalipse_TSY_IgnoreAlertUntil  = nil
    modData.Apocalipse_TSY_Done              = nil
end

local function Apocalipse_TSY_OnGameStart()
    Apocalipse_TSY_ClimateManager = getClimateManager()
    Apocalipse_TSY_CachedWorldHours     = getGameTime():getWorldAgeHours()
end

local function Apocalipse_TSY_OnTick()
    Apocalipse_TSY_TickCounter      = Apocalipse_TSY_TickCounter + 1
    Apocalipse_TSY_CachedWorldHours = getGameTime():getWorldAgeHours()

    -- Cache player reference and position (read once, used by every zombie this frame)
    local p = getPlayer()
    Apocalipse_TSY_CachedPlayer = (p and not p:isDead()) and p or nil
    if Apocalipse_TSY_CachedPlayer then
        Apocalipse_TSY_CachedPX = p:getX()
        Apocalipse_TSY_CachedPY = p:getY()
    end

    -- Cache time-allowed flag (depends on sandbox + climate, constant per frame)
    Apocalipse_TSY_CachedTimeAllowed = Apocalipse_TSY_TimeAllowed()

    -- Cache sandbox vars and resolve all per-frame config once
    local vars = Apocalipse_TSY_GetSandbox()
    Apocalipse_TSY_CachedVars = vars

    local tickRate = Apocalipse_TSY_DefaultTickRate
    if vars and vars.TickRate and vars.TickRate > 0 then tickRate = vars.TickRate end
    Apocalipse_TSY_CachedTickRate = tickRate

    local farRange = Apocalipse_TSY_FarRange
    if vars and vars.FarRange and vars.FarRange > 0 then farRange = vars.FarRange end
    Apocalipse_TSY_CachedFarRange = farRange

    local maxDist = Apocalipse_TSY_DefaultMaxDistance
    if vars and vars.MaxProcessDistance and vars.MaxProcessDistance > 0 then maxDist = vars.MaxProcessDistance end
    Apocalipse_TSY_CachedMaxProcessDist = maxDist

    local screechChance = Apocalipse_TSY_DefaultScreechChance
    if vars then
        local v = tonumber(vars.ScreechChance)
        if v and v >= 0 and v <= 100 then screechChance = v end
    end
    Apocalipse_TSY_CachedScreechChance = screechChance

    local chaseChance = Apocalipse_TSY_ChaseScreechChance
    if vars then
        local v = tonumber(vars.ChaseScreechChance)
        if v and v >= 0 and v <= 100 then chaseChance = v end
    end
    Apocalipse_TSY_CachedChaseChance = chaseChance

    local enableNear = true
    if vars and vars.EnableNearScream ~= nil then enableNear = vars.EnableNearScream end
    Apocalipse_TSY_CachedEnableNear = enableNear

    -- Prune expired cluster events once per frame instead of per-zombie
    local cooldown = Apocalipse_TSY_ClusterCooldownHours
    if vars and vars.ClusterCooldownHours and vars.ClusterCooldownHours > 0 then
        cooldown = vars.ClusterCooldownHours
    end
    local timeNow = Apocalipse_TSY_CachedWorldHours
    local i = 1
    while i <= #Apocalipse_TSY_ClusterEvents do
        if timeNow - Apocalipse_TSY_ClusterEvents[i].t > cooldown then
            table.remove(Apocalipse_TSY_ClusterEvents, i)
        else
            i = i + 1
        end
    end
end

if not isServer() then
    Events.OnGameStart.Add(Apocalipse_TSY_OnGameStart)
    Events.OnZombieDead.Add(Apocalipse_TSY_OnZombieDead)
    Events.OnZombieUpdate.Add(Apocalipse_TSY_OnZombieUpdate)
    Events.OnTick.Add(Apocalipse_TSY_OnTick)
end

