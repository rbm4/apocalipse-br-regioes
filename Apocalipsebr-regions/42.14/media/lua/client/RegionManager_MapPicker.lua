-- ============================================================================
-- File: media/lua/client/RegionManager_MapPicker.lua
-- Admin map picker for creating new regions by selecting two points on the map
-- ============================================================================

if not isClient() then return end

require "RegionManager_Config"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISTickBox"

RegionManager.MapPicker = RegionManager.MapPicker or {}

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)

-- ============================================================================
-- Main Map Picker Panel
-- ============================================================================
ISRegionMapPicker = ISPanel:derive("ISRegionMapPicker")

-- Selection states
local STATE_PICK_FIRST  = 0
local STATE_PICK_SECOND = 1
local STATE_READY       = 2

function ISRegionMapPicker:initialise()
    ISPanel.initialise(self)
end

function ISRegionMapPicker:createChildren()
    ISPanel.createChildren(self)

    local pad = 10
    local btnWid = 120
    local btnHgt = math.max(25, FONT_HGT_SMALL + 6)
    local fieldHgt = math.max(22, FONT_HGT_SMALL + 6)
    local labelW = 100

    -- Title
    self.titleLabel = ISLabel:new(pad, pad, FONT_HGT_MEDIUM, "Create New Region - Map Picker", 1, 1, 1, 1, UIFont.Medium, true)
    self.titleLabel:initialise()
    self:addChild(self.titleLabel)

    -- ========== Map area ==========
    local mapY = pad + FONT_HGT_MEDIUM + pad
    local formHeight = 200  -- space for form at bottom
    local mapHeight = self.height - mapY - formHeight - btnHgt - pad * 3

    self.mapX = pad
    self.mapY = mapY
    self.mapW = self.width - pad * 2
    self.mapH = mapHeight

    -- Create the world map widget
    -- IMPORTANT: set dimensions BEFORE adding data (addData checks width/height > 0)
    self.worldMap = UIWorldMap.new(nil)
    self.worldMap:setX(self:getAbsoluteX() + self.mapX)
    self.worldMap:setY(self:getAbsoluteY() + self.mapY)
    self.worldMap:setWidth(self.mapW)
    self.worldMap:setHeight(self.mapH)
    self.worldMap:setDoStencil(true)

    local api = self.worldMap:getAPIv1()
    api:setBoolean("ClampBaseZoomToPoint5", false)
    api:setBoolean("Isometric", false)
    api:setBoolean("Features", true)
    api:setBoolean("ImagePyramid", true)

    -- Load map data from all available map directories
    self:loadMapData(api)

    -- ========== Status bar ==========
    local statusY = mapY + mapHeight + 4
    self.statusLabel = ISLabel:new(pad, statusY, FONT_HGT_SMALL, "Click on the map to select the FIRST corner of the region.", 1, 1, 0.5, 1, UIFont.Small, true)
    self.statusLabel:initialise()
    self:addChild(self.statusLabel)

    self.coordLabel = ISLabel:new(pad, statusY + FONT_HGT_SMALL + 2, FONT_HGT_SMALL, "Coordinates: (none)", 0.7, 0.7, 0.7, 1, UIFont.Small, true)
    self.coordLabel:initialise()
    self:addChild(self.coordLabel)

    -- ========== Form fields ==========
    local formY = statusY + FONT_HGT_SMALL * 2 + pad

    -- Row 1: Region Name
    local row1Y = formY
    self.nameLabel = ISLabel:new(pad, row1Y, fieldHgt, "Region Name:", 1, 1, 1, 1, UIFont.Small, true)
    self.nameLabel:initialise()
    self:addChild(self.nameLabel)

    self.nameEntry = ISTextEntryBox:new("", pad + labelW, row1Y, 200, fieldHgt)
    self.nameEntry:initialise()
    self.nameEntry:instantiate()
    self:addChild(self.nameEntry)

    -- Row 2: Region ID (auto-generated)
    local row2Y = row1Y + fieldHgt + 4
    self.idLabel = ISLabel:new(pad, row2Y, fieldHgt, "Region ID:", 1, 1, 1, 1, UIFont.Small, true)
    self.idLabel:initialise()
    self:addChild(self.idLabel)

    self.idEntry = ISTextEntryBox:new("", pad + labelW, row2Y, 200, fieldHgt)
    self.idEntry:initialise()
    self.idEntry:instantiate()
    self:addChild(self.idEntry)

    -- Row 3: Categories (tick boxes arranged horizontally)
    local row3Y = row2Y + fieldHgt + 6
    self.catLabel = ISLabel:new(pad, row3Y, fieldHgt, "Categories:", 1, 1, 1, 1, UIFont.Small, true)
    self.catLabel:initialise()
    self:addChild(self.catLabel)

    -- Build category tick boxes
    self.categoryNames = {}
    for catName, _ in pairs(RegionManager.Config.Categories) do
        if catName ~= "AUTOSAFE" and catName ~= "CUSTOM" then
            table.insert(self.categoryNames, catName)
        end
    end
    table.sort(self.categoryNames)

    -- Use two rows of tick boxes to fit within the panel
    local catX = pad + labelW
    local catColW = 130
    local catRow1Y = row3Y
    local catRow2Y = row3Y + FONT_HGT_SMALL + 6

    self.catTickBox = ISTickBox:new(catX, catRow1Y, self.width - catX - pad, FONT_HGT_SMALL + 4, "", nil, nil)
    self.catTickBox:initialise()
    self.catTickBox:instantiate()
    self.catTickBox.choicesColor = {r=1, g=1, b=1, a=1}
    for i, catName in ipairs(self.categoryNames) do
        self.catTickBox:addOption(catName)
    end
    self:addChild(self.catTickBox)

    -- ========== Action buttons ==========
    local btnY = self.height - btnHgt - pad

    self.resetBtn = ISButton:new(pad, btnY, btnWid, btnHgt, "Reset Selection", self, ISRegionMapPicker.onReset)
    self.resetBtn:initialise()
    self.resetBtn:instantiate()
    self.resetBtn.borderColor = {r=1, g=1, b=1, a=0.4}
    self:addChild(self.resetBtn)

    self.submitBtn = ISButton:new(pad + btnWid + pad, btnY, btnWid, btnHgt, "Submit", self, ISRegionMapPicker.onSubmit)
    self.submitBtn:initialise()
    self.submitBtn:instantiate()
    self.submitBtn.borderColor = {r=0.3, g=1, b=0.3, a=0.6}
    self:addChild(self.submitBtn)

    self.cancelBtn = ISButton:new(self.width - btnWid - pad, btnY, btnWid, btnHgt, "Cancel", self, ISRegionMapPicker.onCancel)
    self.cancelBtn:initialise()
    self.cancelBtn:instantiate()
    self.cancelBtn.borderColor = {r=1, g=0.3, b=0.3, a=0.6}
    self:addChild(self.cancelBtn)

    -- ========== Initialize state ==========
    self.selectionState = STATE_PICK_FIRST
    self.point1 = nil  -- {x, y}
    self.point2 = nil  -- {x, y}

    -- Center map on player position
    local player = getPlayer()
    if player then
        local api2 = self.worldMap:getAPIv1()
        api2:centerOn(player:getX(), player:getY())
    end
end

-- ============================================================================
-- Load map data from game directories
-- ============================================================================
function ISRegionMapPicker:loadMapData(api)
    local loaded = 0

    -- Get map directories from the live world (MP-safe, unlike getMapDirectoryTable)
    -- IsoWorld.instance:getMap() returns semicolon-separated dir names e.g. "Muldraugh, KY;West Point, KY"
    local ok, mapStr = pcall(function() return IsoWorld.instance:getMap() end)
    if ok and mapStr and mapStr ~= "" then
        for dirName in string.gmatch(mapStr, "[^;]+") do
            dirName = dirName:match("^%s*(.-)%s*$") -- trim whitespace

            local dataPath = "media/maps/" .. dirName .. "/worldmap.xml"
            local imgPath = "media/maps/" .. dirName

            local ok1 = pcall(function() api:addData(dataPath) end)
            local ok2 = pcall(function() api:addImages(imgPath) end)
            pcall(function() api:endDirectoryData() end)

            if ok1 or ok2 then
                loaded = loaded + 1
                print("[RegionManager MapPicker] Loaded map data: " .. dirName)
            end
        end
    end

    -- Fallback: try the default map if nothing loaded
    if loaded == 0 then
        pcall(function() api:addData("media/maps/Muldraugh, KY/worldmap.xml") end)
        pcall(function() api:addImages("media/maps/Muldraugh, KY") end)
        pcall(function() api:endDirectoryData() end)
        print("[RegionManager MapPicker] Loaded fallback map data: Muldraugh, KY")
    end

    -- Set bounds from world metaGrid if available (most reliable in-game)
    local boundsOk = pcall(function() api:setBoundsFromWorld() end)
    if not boundsOk then
        pcall(function() api:setBoundsFromData() end)
    end

    print("[RegionManager MapPicker] Map data loaded, data count: " .. tostring(api:getDataCount()))
end

-- ============================================================================
-- Rendering — map widget + selection overlay
-- ============================================================================
function ISRegionMapPicker:prerender()
    ISPanel.prerender(self)

    -- Draw the map background area
    self:drawRect(self.mapX, self.mapY, self.mapW, self.mapH, 1, 0.05, 0.05, 0.05)
end

function ISRegionMapPicker:render()
    ISPanel.render(self)

    -- Render the world map widget within our map area
    local absX = self:getAbsoluteX() + self.mapX
    local absY = self:getAbsoluteY() + self.mapY
    self.worldMap:setX(absX)
    self.worldMap:setY(absY)
    self.worldMap:setWidth(self.mapW)
    self.worldMap:setHeight(self.mapH)
    self.worldMap:render()

    local api = self.worldMap:getAPIv1()

    -- Draw existing zones on map as semi-transparent overlays
    if RegionManager.Client and RegionManager.Client.zoneData then
        for _, zone in ipairs(RegionManager.Client.zoneData) do
            local b = zone.bounds
            local uiX1 = api:worldToUIX(b.minX, b.minY) + self.mapX
            local uiY1 = api:worldToUIY(b.minX, b.minY) + self.mapY
            local uiX2 = api:worldToUIX(b.maxX, b.maxY) + self.mapX
            local uiY2 = api:worldToUIY(b.maxX, b.maxY) + self.mapY

            local rx = math.min(uiX1, uiX2)
            local ry = math.min(uiY1, uiY2)
            local rw = math.abs(uiX2 - uiX1)
            local rh = math.abs(uiY2 - uiY1)

            local c = zone.color or {r=0.5, g=0.5, b=0.5}
            self:drawRect(rx, ry, rw, rh, 0.15, c.r, c.g, c.b)
            self:drawRectBorder(rx, ry, rw, rh, 0.6, c.r, c.g, c.b)
        end
    end

    -- Draw selection markers and rectangle
    if self.point1 then
        local p1uiX = api:worldToUIX(self.point1.x, self.point1.y) + self.mapX
        local p1uiY = api:worldToUIY(self.point1.x, self.point1.y) + self.mapY
        -- Draw crosshair marker at point 1
        self:drawRect(p1uiX - 4, p1uiY - 1, 9, 3, 0.9, 0, 1, 0)
        self:drawRect(p1uiX - 1, p1uiY - 4, 3, 9, 0.9, 0, 1, 0)
    end

    if self.point2 then
        local p2uiX = api:worldToUIX(self.point2.x, self.point2.y) + self.mapX
        local p2uiY = api:worldToUIY(self.point2.x, self.point2.y) + self.mapY
        -- Draw crosshair marker at point 2
        self:drawRect(p2uiX - 4, p2uiY - 1, 9, 3, 0.9, 1, 0.3, 0)
        self:drawRect(p2uiX - 1, p2uiY - 4, 3, 9, 0.9, 1, 0.3, 0)
    end

    -- Draw selection rectangle between both points
    if self.point1 and self.point2 then
        local p1uiX = api:worldToUIX(self.point1.x, self.point1.y) + self.mapX
        local p1uiY = api:worldToUIY(self.point1.x, self.point1.y) + self.mapY
        local p2uiX = api:worldToUIX(self.point2.x, self.point2.y) + self.mapX
        local p2uiY = api:worldToUIY(self.point2.x, self.point2.y) + self.mapY

        local rx = math.min(p1uiX, p2uiX)
        local ry = math.min(p1uiY, p2uiY)
        local rw = math.abs(p2uiX - p1uiX)
        local rh = math.abs(p2uiY - p1uiY)

        -- Semi-transparent green fill
        self:drawRect(rx, ry, rw, rh, 0.2, 0, 1, 0)
        -- Bright green border
        self:drawRectBorder(rx, ry, rw, rh, 0.9, 0, 1, 0)
    elseif self.point1 and self:isMouseOverMap() then
        -- Live preview: draw rectangle from point1 to mouse cursor
        local api2 = self.worldMap:getAPIv1()
        local mouseWorldX = api2:mouseToWorldX()
        local mouseWorldY = api2:mouseToWorldY()

        local p1uiX = api:worldToUIX(self.point1.x, self.point1.y) + self.mapX
        local p1uiY = api:worldToUIY(self.point1.x, self.point1.y) + self.mapY
        local mUiX = api:worldToUIX(mouseWorldX, mouseWorldY) + self.mapX
        local mUiY = api:worldToUIY(mouseWorldX, mouseWorldY) + self.mapY

        local rx = math.min(p1uiX, mUiX)
        local ry = math.min(p1uiY, mUiY)
        local rw = math.abs(mUiX - p1uiX)
        local rh = math.abs(mUiY - p1uiY)

        -- Semi-transparent yellow preview
        self:drawRect(rx, ry, rw, rh, 0.12, 1, 1, 0)
        self:drawRectBorder(rx, ry, rw, rh, 0.5, 1, 1, 0)
    end

    -- Draw map border on top of everything
    self:drawRectBorder(self.mapX, self.mapY, self.mapW, self.mapH, 0.8, 0.4, 0.4, 0.4)

    -- Update coordinate label with mouse position
    if self:isMouseOverMap() then
        local api3 = self.worldMap:getAPIv1()
        local mwx = api3:mouseToWorldX()
        local mwy = api3:mouseToWorldY()
        local coordText = string.format("Mouse: (%d, %d)", math.floor(mwx), math.floor(mwy))
        if self.point1 then
            coordText = coordText .. string.format("  |  Point 1: (%d, %d)", math.floor(self.point1.x), math.floor(self.point1.y))
        end
        if self.point2 then
            coordText = coordText .. string.format("  |  Point 2: (%d, %d)", math.floor(self.point2.x), math.floor(self.point2.y))
        end
        self.coordLabel:setName(coordText)
    end
end

-- ============================================================================
-- Mouse handling
-- ============================================================================
function ISRegionMapPicker:isMouseOverMap()
    local mx = self:getMouseX()
    local my = self:getMouseY()
    return mx >= self.mapX and mx <= self.mapX + self.mapW and
           my >= self.mapY and my <= self.mapY + self.mapH
end

function ISRegionMapPicker:onMouseDown(x, y)
    -- Let dragging work via the map (panning)
    if self:isMouseOverMap() then
        self.isPanningMap = true
        self.panStartX = x
        self.panStartY = y
        self.panDragDist = 0
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function ISRegionMapPicker:onMouseUp(x, y)
    if self.isPanningMap then
        self.isPanningMap = false
        -- Only register a click if the mouse didn't drag significantly (< 5px)
        if self.panDragDist < 5 and self:isMouseOverMap() then
            self:handleMapClick()
        end
        return true
    end
    return ISPanel.onMouseUp(self, x, y)
end

function ISRegionMapPicker:onMouseMove(dx, dy)
    if self.isPanningMap then
        self.panDragDist = (self.panDragDist or 0) + math.abs(dx) + math.abs(dy)
        local api = self.worldMap:getAPIv1()
        api:moveView(-dx, -dy)
        return true
    end
    return ISPanel.onMouseMove(self, dx, dy)
end

function ISRegionMapPicker:onMouseMoveOutside(dx, dy)
    if self.isPanningMap then
        self.panDragDist = (self.panDragDist or 0) + math.abs(dx) + math.abs(dy)
        local api = self.worldMap:getAPIv1()
        api:moveView(-dx, -dy)
        return true
    end
    return ISPanel.onMouseMoveOutside(self, dx, dy)
end

function ISRegionMapPicker:onMouseWheel(del)
    if self:isMouseOverMap() then
        local api = self.worldMap:getAPIv1()
        local mx = self:getMouseX() - self.mapX
        local my = self:getMouseY() - self.mapY
        api:zoomAt(mx, my, -del * 8)
        return true
    end
    return false
end

function ISRegionMapPicker:handleMapClick()
    local api = self.worldMap:getAPIv1()
    local worldX = api:mouseToWorldX()
    local worldY = api:mouseToWorldY()

    if self.selectionState == STATE_PICK_FIRST then
        self.point1 = { x = worldX, y = worldY }
        self.point2 = nil
        self.selectionState = STATE_PICK_SECOND
        self.statusLabel:setName("Click on the map to select the SECOND corner of the region.")
        self.statusLabel.r = 1; self.statusLabel.g = 0.7; self.statusLabel.b = 0.3
        print("[RegionManager MapPicker] Point 1 selected: " .. math.floor(worldX) .. ", " .. math.floor(worldY))

    elseif self.selectionState == STATE_PICK_SECOND then
        self.point2 = { x = worldX, y = worldY }
        self.selectionState = STATE_READY
        self.statusLabel:setName("Both corners selected. Fill in the form and click Submit.")
        self.statusLabel.r = 0.3; self.statusLabel.g = 1; self.statusLabel.b = 0.3
        print("[RegionManager MapPicker] Point 2 selected: " .. math.floor(worldX) .. ", " .. math.floor(worldY))

        -- Auto-generate ID from name if name is filled
        self:updateIdFromName()

    elseif self.selectionState == STATE_READY then
        -- Allow re-picking second point while in ready state
        self.point2 = { x = worldX, y = worldY }
        self.statusLabel:setName("Second corner updated. Fill in the form and click Submit.")
        print("[RegionManager MapPicker] Point 2 updated: " .. math.floor(worldX) .. ", " .. math.floor(worldY))
    end
end

-- ============================================================================
-- Form helpers
-- ============================================================================
function ISRegionMapPicker:updateIdFromName()
    local name = self.nameEntry:getText()
    if name and name ~= "" then
        -- Convert name to snake_case id
        local id = name:lower():gsub("%s+", "_"):gsub("[^%w_]", "")
        self.idEntry:setText(id)
    end
end

function ISRegionMapPicker:getSelectedCategories()
    local categories = {}
    for i, catName in ipairs(self.categoryNames) do
        if self.catTickBox:isSelected(i) then
            table.insert(categories, catName)
        end
    end
    return categories
end

-- ============================================================================
-- Button callbacks
-- ============================================================================
function ISRegionMapPicker:onReset()
    self.point1 = nil
    self.point2 = nil
    self.selectionState = STATE_PICK_FIRST
    self.statusLabel:setName("Click on the map to select the FIRST corner of the region.")
    self.statusLabel.r = 1; self.statusLabel.g = 1; self.statusLabel.b = 0.5
    self.coordLabel:setName("Coordinates: (none)")
end

function ISRegionMapPicker:onSubmit()
    local player = getPlayer()
    if not player then return end

    -- Validate
    if not self.point1 or not self.point2 then
        player:Say("Select both corners on the map first!", 1, 0.3, 0.3, UIFont.Small, 2, "radio")
        return
    end

    local name = self.nameEntry:getText()
    if not name or name == "" then
        player:Say("Enter a region name!", 1, 0.3, 0.3, UIFont.Small, 2, "radio")
        return
    end

    -- Auto-generate ID if empty
    self:updateIdFromName()
    local id = self.idEntry:getText()
    if not id or id == "" then
        player:Say("Enter a region ID!", 1, 0.3, 0.3, UIFont.Small, 2, "radio")
        return
    end

    local categories = self:getSelectedCategories()
    if #categories == 0 then
        player:Say("Select at least one category!", 1, 0.3, 0.3, UIFont.Small, 2, "radio")
        return
    end

    -- Build region definition and send to server
    local regionDef = {
        id = id,
        name = name,
        x1 = math.floor(self.point1.x),
        y1 = math.floor(self.point1.y),
        x2 = math.floor(self.point2.x),
        y2 = math.floor(self.point2.y),
        z = 0,
        enabled = true,
        categories = categories,
        customProperties = {}
    }

    sendClientCommand("RegionManager", "AddRegion", regionDef)
    player:Say("Submitting new region: " .. name .. "...", 0.7, 0.7, 1, UIFont.Small, 2, "radio")

    print("[RegionManager MapPicker] Sent AddRegion command: " .. id)
end

function ISRegionMapPicker:onCancel()
    self:close()
end

function ISRegionMapPicker:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

-- ============================================================================
-- Constructor
-- ============================================================================
function ISRegionMapPicker:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    o.backgroundColor = {r=0, g=0, b=0, a=0.95}
    o.moveWithMouse = true
    o.isPanningMap = false
    o.panDragDist = 0
    return o
end

-- ============================================================================
-- Public API
-- ============================================================================
function RegionManager.MapPicker.Open()
    local player = getPlayer()
    if not player then return end

    if not isDebugEnabled() then return end

    local width = 900
    local height = 850
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2

    local panel = ISRegionMapPicker:new(x, y, width, height)
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)

    print("[RegionManager MapPicker] Panel opened by: " .. player:getUsername())
end

print("[RegionManager MapPicker] Map picker module loaded")

return RegionManager.MapPicker
