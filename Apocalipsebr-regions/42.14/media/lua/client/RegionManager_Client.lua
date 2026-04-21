-- ============================================================================
-- File: media/lua/client/RegionManager_Client.lua
-- Client-side UI and notifications
-- ============================================================================

if not isClient() then return end

require "RegionManager_Config"

RegionManager.Client = RegionManager.Client or {}

---@type ClientZoneData[]|nil
RegionManager.Client.zoneData = nil -- Store zone boundary data

local function log(msg)
    RegionManager.Log("Client", msg)
end

-- Show zone notification
---@param zoneName string
---@param message string
---@param color? ColorRGB
---@param isEntry boolean
local function showZoneNotification(zoneName, message, color, isEntry)
    local player = getPlayer()
    if not player then return end
    
    -- Use game's HaloNote system for notifications
    local r = color and color.r or 1.0
    local g = color and color.g or 1.0
    local b = color and color.b or 1.0
    
    player:Say(message, r, g, b, UIFont.Medium, 3, "radio")
    
    -- Log to console
    local prefix = isEntry and "[ENTERED]" or "[LEFT]"
    log(prefix .. " " .. zoneName)
end

-- Handle server commands
---@param module string
---@param command string
---@param args table
local function OnServerCommand(module, command, args)
    if module ~= "RegionManager" then return end
    
    if command == "ZoneInfo" then
        -- Display zone info UI
        log("Current zones: " .. #args.zones)
        for _, zone in ipairs(args.zones) do
            log("  - " .. zone.name)
        end
        
    elseif command == "ExportComplete" then
        local player = getPlayer()
        if player then
            player:Say("Region configuration exported successfully!", 0, 1, 0, UIFont.Medium, 3, "radio")
        end
        
    elseif command == "AllZoneBoundaries" then
        -- Receive all zone boundary data from server
        RegionManager.Client.zoneData = args.zones or {}
        log("Received " .. tostring(#RegionManager.Client.zoneData) .. " zone boundaries from server")
        log("Zone outlines will be drawn continuously via OnPostRender")

        -- Reset client tick zone state so entry/exit events re-fire for new zones
        if RegionManager.ClientTick and RegionManager.ClientTick.resetZoneState then
            RegionManager.ClientTick.resetZoneState()
        end

    elseif command == "RegionAdded" then
        -- New region was successfully added
        local player = getPlayer()
        if player then
            local msg = "Region '" .. (args.name or args.id) .. "' created successfully! All zones reloaded."
            player:Say(msg, 0.3, 1, 0.3, UIFont.Medium, 3, "radio")
        end
        log("Region added: " .. tostring(args.id))

    elseif command == "RegionAddFailed" then
        -- Region creation failed
        local player = getPlayer()
        if player then
            local msg = "Failed to create region: " .. (args.reason or "Unknown error")
            player:Say(msg, 1, 0.3, 0.3, UIFont.Medium, 3, "radio")
        end
        log("Region add failed: " .. tostring(args.reason))
    end
end

-- Request zone info for current position
local function requestZoneInfo()
    local player = getPlayer()
    if not player then return end
    
    sendClientCommand("RegionManager", "RequestZoneInfo", {
        x = player:getX(),
        y = player:getY()
    })
end

-- Debug command to show current zones
local function showCurrentZones()
    requestZoneInfo()
end


-- Event registration
Events.OnServerCommand.Add(OnServerCommand)

-- Register debug command (optional)
-- You can call this from console: /showzones
if isDebugEnabled() then
    RegionManager.Client.ShowZones = showCurrentZones
end

log("RegionManager Client module loaded")

return RegionManager.Client