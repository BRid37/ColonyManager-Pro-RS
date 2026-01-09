-- RSWarehouse.lua
-- Updated for Advanced Peripherals 0.7: 2025-01-06
-- GitHub Auto-Update Support Added: 2026-01-08

local VERSION = "2.0.0"
local VERSION_FILE = ".rswarehouse_version"

-- Load configuration from config.lua
local function loadConfig()
    if fs.exists("config.lua") then
        local success, config = pcall(dofile, "config.lua")
        if success and config then
            return config
        end
    end
    return nil
end

local userConfig = loadConfig()

local logFile = "RSWarehouse.log"
local logFileBackup = "RSWarehouse.log.bak"
local time_between_runs = (userConfig and userConfig.time_between_runs) or 15
local SCAN_AT_NIGHT = (userConfig and userConfig.scan_at_night ~= nil) and userConfig.scan_at_night or true
local logHandle = nil

-- Log management settings
local MAX_LOG_SIZE = (userConfig and userConfig.max_log_size) or 50000
local MIN_FREE_SPACE = 10000     -- Minimum free space to maintain (10KB)
local LOG_ROTATE_ENABLED = (userConfig and userConfig.log_rotate_enabled ~= nil) and userConfig.log_rotate_enabled or true
local LOG_CHECK_INTERVAL = 50    -- Check disk space every N log writes
local logWriteCount = 0          -- Counter for log writes
local VERBOSE_LOGGING = (userConfig and userConfig.verbose_logging) or false

-- Smart tool handling settings
local SMART_TOOL_HANDLING = (userConfig and userConfig.smart_tool_handling ~= nil) and userConfig.smart_tool_handling or true
local AUTO_FULFILL_TOOLS = (userConfig and userConfig.auto_fulfill_tool_requests ~= nil) and userConfig.auto_fulfill_tool_requests or true

-- Excluded items list (loaded from config, can be modified at runtime)
local excludedItems = {}
local excludedCategories = {}
local EXCLUDED_FILE = "excluded_items.txt"

-- Colony data cache
local colonyCache = {
    citizens = nil,
    buildings = nil,
    lastUpdate = 0
}
local CACHE_DURATION = (userConfig and userConfig.cache_duration) or 60

-- Material costs for smart fulfillment (lower = cheaper)
local materialCosts = (userConfig and userConfig.material_costs) or {
    ["wooden"] = 1, ["wood"] = 1,
    ["gold"] = 1, ["golden"] = 1,
    ["stone"] = 2,
    ["iron"] = 3,
    ["diamond"] = 5,
    ["netherite"] = 10
}

-- Building level to tool tier mapping
local buildingToolTiers = (userConfig and userConfig.building_tool_tiers) or {
    [0] = {"wooden", "wood", "gold", "golden"},
    [1] = {"wooden", "wood", "gold", "golden", "stone"},
    [2] = {"wooden", "wood", "gold", "golden", "stone", "iron"},
    [3] = {"wooden", "wood", "gold", "golden", "stone", "iron", "diamond"},
    [4] = {"wooden", "wood", "gold", "golden", "stone", "iron", "diamond"},
    [5] = {"wooden", "wood", "gold", "golden", "stone", "iron", "diamond", "netherite"}
}

-- Armor level mapping
local buildingArmorTiers = (userConfig and userConfig.building_armor_tiers) or {
    [0] = {"leather"},
    [1] = {"leather", "gold", "golden"},
    [2] = {"leather", "gold", "golden", "chain", "chainmail"},
    [3] = {"leather", "gold", "golden", "chain", "chainmail", "iron"},
    [4] = {"leather", "gold", "golden", "chain", "chainmail", "iron", "diamond"},
    [5] = {"leather", "gold", "golden", "chain", "chainmail", "iron", "diamond", "netherite"}
}

-- Pending crafts tracking - prevents over-crafting when export is blocked
-- Key = item name, Value = { count = amount pending, timestamp = when requested, scansSinceExport = count }
local pendingCrafts = {}
local PENDING_CRAFTS_FILE = ".pending_crafts"
local PENDING_WARNING_SCANS = 3  -- Show warning after this many scans without export
local pendingCraftsWarning = false  -- True when warning should be displayed
local pendingCraftsWarningItems = {}  -- Items that triggered the warning

-- Exported items tracking - items sent to output chest but not yet confirmed in warehouse
-- Key = item name, Value = { count = amount exported, timestamp = when exported }
local exportedItems = {}
local EXPORTED_ITEMS_FILE = ".exported_items"
local EXPORT_CONFIRM_TIMEOUT = 120  -- 2 minutes - if request disappears, assume delivered

-- Initialize current_run globally so displayMainPage can access it
current_run = time_between_runs

-- Night pause state (global so they work across functions)
isNightPaused = false             -- True when paused due to night time
forceUnpause = false              -- True to override night pause until next night cycle

--[[
    Check and Manage Log Space
    @desc   Checks disk space and log file size, rotates if needed
    @return boolean - true if logging can continue, false if disabled
]]
local function checkLogSpace()
    -- Check free space on drive
    local freeSpace = fs.getFreeSpace("/")
    
    -- If critically low on space, clear log immediately
    if freeSpace < MIN_FREE_SPACE then
        print("WARNING: Low disk space (" .. freeSpace .. " bytes). Clearing log.")
        if logHandle then
            logHandle.close()
            logHandle = nil
        end
        -- Delete backup if exists
        if fs.exists(logFileBackup) then
            fs.delete(logFileBackup)
        end
        -- Delete main log
        if fs.exists(logFile) then
            fs.delete(logFile)
        end
        -- Reopen log file
        logHandle = fs.open(logFile, "a")
        if logHandle then
            logHandle.write("[SYSTEM] Log cleared due to low disk space\n")
            logHandle.flush()
        end
        return logHandle ~= nil
    end
    
    -- Check log file size
    if fs.exists(logFile) then
        local logSize = fs.getSize(logFile)
        if logSize > MAX_LOG_SIZE then
            print("Log file size: " .. logSize .. " bytes. Rotating...")
            -- Close current log
            if logHandle then
                logHandle.close()
                logHandle = nil
            end
            -- Delete old backup
            if fs.exists(logFileBackup) then
                fs.delete(logFileBackup)
            end
            -- Rotate: move current to backup
            fs.move(logFile, logFileBackup)
            -- Reopen fresh log
            logHandle = fs.open(logFile, "a")
            if logHandle then
                logHandle.write("[SYSTEM] Log rotated - previous log saved to " .. logFileBackup .. "\n")
                logHandle.flush()
            end
        end
    end
    
    return logHandle ~= nil
end

-- GUI state management
local currentPage = "main"  -- main, logs, stats
local logPageOffset = 0
local statsData = {
  totalScans = 0,
  lastScanTime = 0,
  totalExports = 0,
  totalCrafts = 0,
  successfulExports = 0,
  failedExports = 0,
  citizenRequests = 0,
  workOrders = 0,
  workOrderResources = 0
}

-- Initialize logging
local function initializeLogging()
  local success, err = pcall(function()
    logHandle = fs.open(logFile, "a")
    if logHandle then
      logHandle.write("\n")
      logHandle.write("================================================================================\n")
      logHandle.write(string.format("RSWarehouse started - Day %d at %s\n", os.day(), textutils.formatTime(os.time(), true)))
      logHandle.write("Advanced Peripherals 0.7 Compatible\n")
      logHandle.write("================================================================================\n")
      logHandle.flush()
      print("Logging initialized: " .. logFile)
    else
      print("WARNING: Could not open log file")
    end
  end)
  if not success then
    print("ERROR: Logging initialization failed - " .. tostring(err))
  end
end

initializeLogging()

--[[
    Log Message
    @desc   Write a timestamped message to the log file
    @param  level - Log level (INFO, WARN, ERROR, DEBUG)
    @param  message - Log message
    @param  data - Optional table data to serialize
    @return void
]]
function logMessage(level, message, data)
  if not logHandle then return end
  
  -- Check and manage log space periodically to reduce overhead
  logWriteCount = logWriteCount + 1
  if LOG_ROTATE_ENABLED and logWriteCount >= LOG_CHECK_INTERVAL then
    logWriteCount = 0
    checkLogSpace()
  end
  
  if not logHandle then return end  -- May have been closed during rotation
  
  local timestamp = textutils.formatTime(os.time(), true)
  local day = os.day()
  logHandle.write(string.format("[Day %d %s] [%s] %s\n", day, timestamp, level, message))
  if data then
    logHandle.write("  Data: " .. textutils.serialize(data, { compact = true }) .. "\n")
  end
  -- Don't flush every write - let it batch
end

-- Initialize Monitor
-- see: https://tweaked.cc/peripheral/monitor.html
local monitor = peripheral.find("monitor")
if not monitor then 
  logMessage("ERROR", "Monitor not found - cannot initialize")
  error("Monitor not found.") 
end
monitor.setTextScale(0.5)
monitor.clear()
monitor.setCursorPos(1, 1)
monitor.setCursorBlink(false)
print("Monitor initialized.")
logMessage("INFO", "Monitor initialized successfully")
 
-- Initialize RS Bridge
-- see: https://docs.advanced-peripherals.de/0.7/peripherals/rs_bridge/
local bridge = peripheral.find("rs_bridge")
if not bridge then 
  logMessage("ERROR", "RS Bridge not found - ensure peripheral is connected")
  error("RS Bridge not found.") 
end
print("RS Bridge initialized.")
logMessage("INFO", "RS Bridge initialized successfully")

-- Initialize Colony Integrator
-- see: https://docs.advanced-peripherals.de/0.7/peripherals/colony_integrator/
local colony = peripheral.find("colony_integrator")
if not colony then 
  logMessage("ERROR", "Colony Integrator not found - ensure peripheral is connected")
  error("Colony Integrator not found.") 
end
if not colony.isInColony() then 
  logMessage("ERROR", "Colony Integrator is not in a colony - must be placed within colony boundaries")
  error("Colony Integrator is not in a colony.") 
end
print("Colony Integrator initialized.")
logMessage("INFO", "Colony Integrator initialized successfully", { inColony = true })
 
-- Establish the direction to transport the items into the Warehouse based on
-- where the entanglement block is sitting. Default to empty string.
local storage = "Right"
if not storage then error("Warehouse storage not found.") end
local direction = "back"
print("Warehouse storage initialized.")

----------------------------------------------------------------------------
-- FUNCTIONS
----------------------------------------------------------------------------
--[[
  Table.Empty
  @desc     check to see if a table contains any data
  @return   boolean
]]
function table.empty (self)
    for _, _ in pairs(self) do
        return false
    end
    return true
end

----------------------------------------------------------------------------
-- EXCLUDED ITEMS MANAGEMENT
----------------------------------------------------------------------------
--[[
    Load Excluded Items
    @desc   Load excluded items from file
    @return void
]]
local function loadExcludedItems()
    excludedItems = {}
    excludedCategories = {}
    
    -- Load from config
    if userConfig and userConfig.excluded_items then
        for _, item in ipairs(userConfig.excluded_items) do
            excludedItems[item] = true
        end
    end
    if userConfig and userConfig.excluded_categories then
        for _, cat in ipairs(userConfig.excluded_categories) do
            excludedCategories[cat] = true
        end
    end
    
    -- Load from file (overrides/additions)
    if fs.exists(EXCLUDED_FILE) then
        local file = fs.open(EXCLUDED_FILE, "r")
        local line = file.readLine()
        while line do
            line = line:match("^%s*(.-)%s*$") -- trim
            if line ~= "" and not line:match("^#") then
                excludedItems[line] = true
            end
            line = file.readLine()
        end
        file.close()
    end
    
    logMessage("INFO", "Loaded excluded items", { count = 0 })
end

--[[
    Save Excluded Items
    @desc   Save excluded items to file
    @return void
]]
local function saveExcludedItems()
    local file = fs.open(EXCLUDED_FILE, "w")
    file.write("# RSWarehouse Excluded Items\n")
    file.write("# Add one item name per line\n")
    file.write("# Lines starting with # are comments\n\n")
    
    for item, _ in pairs(excludedItems) do
        -- Only save items not from config
        local inConfig = false
        if userConfig and userConfig.excluded_items then
            for _, configItem in ipairs(userConfig.excluded_items) do
                if configItem == item then
                    inConfig = true
                    break
                end
            end
        end
        if not inConfig then
            file.write(item .. "\n")
        end
    end
    file.close()
    logMessage("INFO", "Saved excluded items")
end

--[[
    Add Excluded Item
    @desc   Add an item to the exclusion list
    @return void
]]
local function addExcludedItem(itemName)
    excludedItems[itemName] = true
    saveExcludedItems()
    logMessage("INFO", "Added excluded item", { item = itemName })
end

--[[
    Remove Excluded Item
    @desc   Remove an item from the exclusion list
    @return void
]]
local function removeExcludedItem(itemName)
    excludedItems[itemName] = nil
    saveExcludedItems()
    logMessage("INFO", "Removed excluded item", { item = itemName })
end

--[[
    Get Excluded Items List
    @desc   Get a sorted list of all excluded items
    @return table
]]
local function getExcludedItemsList()
    local list = {}
    for item, _ in pairs(excludedItems) do
        table.insert(list, item)
    end
    table.sort(list)
    return list
end

--[[
    Is Item Excluded
    @desc   Check if an item should be excluded
    @return boolean
]]
local function isItemExcluded(itemName)
    if excludedItems[itemName] then
        return true
    end
    -- Check categories
    for category, _ in pairs(excludedCategories) do
        if itemName == category then
            return true
        end
    end
    return false
end

----------------------------------------------------------------------------
-- COLONY DATA CACHING
----------------------------------------------------------------------------
--[[
    Update Colony Cache
    @desc   Refresh cached colony data if stale
    @return void
]]
local function updateColonyCache()
    local now = os.clock()
    if colonyCache.lastUpdate > 0 and (now - colonyCache.lastUpdate) < CACHE_DURATION then
        return -- Cache is still fresh
    end
    
    local success, citizens = pcall(function() return colony.getCitizens() end)
    if success and citizens then
        colonyCache.citizens = citizens
    end
    
    local success2, buildings = pcall(function() return colony.getBuildings() end)
    if success2 and buildings then
        colonyCache.buildings = buildings
    end
    
    colonyCache.lastUpdate = now
    logMessage("DEBUG", "Colony cache updated", { citizens = #(colonyCache.citizens or {}), buildings = #(colonyCache.buildings or {}) })
end

--[[
    Get Citizen Work Building Level
    @desc   Get the building level for a citizen's workplace
    @param  citizenName - Name of the citizen
    @return number - Building level (0 if not found)
]]
local function getCitizenWorkBuildingLevel(citizenName)
    updateColonyCache()
    
    if not colonyCache.citizens then return 0 end
    
    -- Find the citizen
    for _, citizen in ipairs(colonyCache.citizens) do
        if citizen.name == citizenName or 
           (citizen.name and citizenName:find(citizen.name)) then
            -- Found the citizen, now find their work building
            if citizen.work and citizen.work.location then
                local workLoc = citizen.work.location
                -- Find matching building
                if colonyCache.buildings then
                    for _, building in ipairs(colonyCache.buildings) do
                        if building.location and
                           building.location.x == workLoc.x and
                           building.location.y == workLoc.y and
                           building.location.z == workLoc.z then
                            return building.level or 0
                        end
                    end
                end
                -- Return level from work data if available
                if citizen.work.level then
                    return citizen.work.level
                end
            end
        end
    end
    return 0
end

--[[
    Get Building Level By Type
    @desc   Get the building level for a specific building type (e.g., "Miner")
    @param  buildingType - Type of building to find
    @return number - Highest building level of that type
]]
local function getBuildingLevelByType(buildingType)
    updateColonyCache()
    
    if not colonyCache.buildings then return 0 end
    
    local maxLevel = 0
    for _, building in ipairs(colonyCache.buildings) do
        if building.type and building.type:lower():find(buildingType:lower()) then
            if building.level and building.level > maxLevel then
                maxLevel = building.level
            end
        end
    end
    return maxLevel
end

----------------------------------------------------------------------------
-- PENDING CRAFTS TRACKING (Prevents over-crafting)
----------------------------------------------------------------------------
--[[
    Load Pending Crafts
    @desc   Load pending crafts from disk (persists across reboots)
    @return void
]]
local function loadPendingCrafts()
    if fs.exists(PENDING_CRAFTS_FILE) then
        local file = fs.open(PENDING_CRAFTS_FILE, "r")
        local content = file.readAll()
        file.close()
        local success, data = pcall(textutils.unserialize, content)
        if success and data then
            pendingCrafts = data
            logMessage("INFO", "Loaded pending crafts from disk", { count = 0 })
        end
    end
end

--[[
    Save Pending Crafts
    @desc   Save pending crafts to disk
    @return void
]]
local function savePendingCrafts()
    local file = fs.open(PENDING_CRAFTS_FILE, "w")
    file.write(textutils.serialize(pendingCrafts))
    file.close()
end

--[[
    Check Pending Crafts Warning
    @desc   Check if any pending crafts have been stuck for too many scans and trigger warning
    @return void
]]
local function checkPendingCraftsWarning()
    pendingCraftsWarningItems = {}
    local hasWarning = false
    
    for itemName, craftInfo in pairs(pendingCrafts) do
        -- Increment scans since last export
        craftInfo.scansSinceExport = (craftInfo.scansSinceExport or 0) + 1
        
        -- Check if this item has been stuck for too long
        if craftInfo.scansSinceExport >= PENDING_WARNING_SCANS and craftInfo.count > 0 then
            hasWarning = true
            table.insert(pendingCraftsWarningItems, {
                name = itemName,
                count = craftInfo.count,
                scans = craftInfo.scansSinceExport
            })
        end
    end
    
    if hasWarning and not pendingCraftsWarning then
        pendingCraftsWarning = true
        logMessage("WARN", "Pending crafts warning triggered - items may be stuck", { items = #pendingCraftsWarningItems })
    end
    
    savePendingCrafts()
end

--[[
    Clear Pending Crafts Warning
    @desc   User acknowledged the warning - clear all pending crafts and exported items
    @return void
]]
local function clearPendingCraftsWarning()
    pendingCrafts = {}
    exportedItems = {}
    pendingCraftsWarning = false
    pendingCraftsWarningItems = {}
    savePendingCrafts()
    saveExportedItems()
    logMessage("INFO", "Pending crafts warning cleared by user - all tracking reset")
end

--[[
    Get Total Pending Count
    @desc   Get total count of items pending in crafts
    @return number
]]
local function getTotalPendingCount()
    local total = 0
    for _, craftInfo in pairs(pendingCrafts) do
        total = total + craftInfo.count
    end
    return total
end

--[[
    Get RS Inventory Count
    @desc   Check how many of an item are currently in the RS system
    @param  itemName - The item name to check (e.g., "minecraft:oak_log")
    @return number - Count of items in RS system
]]
local function getRSInventoryCount(itemName)
    if not bridge then return 0 end
    
    local success, result = pcall(function()
        return bridge.getItem({ name = itemName })
    end)
    
    if success and result then
        if type(result) == "table" and result.amount then
            return result.amount
        elseif type(result) == "table" and result.count then
            return result.count
        end
    end
    return 0
end

--[[
    Get Pending Craft Count
    @desc   Get count of items currently pending in crafts
    @param  itemName - The item name to check
    @return number - Count of items pending
]]
local function getPendingCraftCount(itemName)
    if pendingCrafts[itemName] then
        return pendingCrafts[itemName].count
    end
    return 0
end

--[[
    Add Pending Craft
    @desc   Track a new craft request
    @param  itemName - The item being crafted
    @param  count - How many are being crafted
    @return void
]]
local function addPendingCraft(itemName, count)
    if pendingCrafts[itemName] then
        pendingCrafts[itemName].count = pendingCrafts[itemName].count + count
        pendingCrafts[itemName].timestamp = os.clock()
        -- Don't reset scansSinceExport - we want to track how long items have been stuck
    else
        pendingCrafts[itemName] = { count = count, timestamp = os.clock(), scansSinceExport = 0 }
    end
    savePendingCrafts()
    logMessage("DEBUG", "Added pending craft", { item = itemName, count = count, total = pendingCrafts[itemName].count })
end

--[[
    Clear Pending Craft
    @desc   Remove pending craft tracking for an item (after successful export)
    @param  itemName - The item name
    @param  countExported - How many were successfully exported
    @return void
]]
local function clearPendingCraft(itemName, countExported)
    if pendingCrafts[itemName] then
        pendingCrafts[itemName].count = pendingCrafts[itemName].count - countExported
        -- Reset scan counter - items are flowing again
        pendingCrafts[itemName].scansSinceExport = 0
        
        if pendingCrafts[itemName].count <= 0 then
            pendingCrafts[itemName] = nil
        end
        savePendingCrafts()
        logMessage("DEBUG", "Cleared pending craft", { item = itemName, exported = countExported })
        
        -- Check if warning should be cleared (items are flowing)
        if pendingCraftsWarning then
            local stillStuck = false
            for _, craftInfo in pairs(pendingCrafts) do
                if craftInfo.scansSinceExport >= PENDING_WARNING_SCANS and craftInfo.count > 0 then
                    stillStuck = true
                    break
                end
            end
            if not stillStuck then
                pendingCraftsWarning = false
                pendingCraftsWarningItems = {}
                logMessage("INFO", "Pending crafts warning auto-cleared - items are flowing")
            end
        end
    end
end

----------------------------------------------------------------------------
-- EXPORTED ITEMS TRACKING (Items in transit to warehouse)
----------------------------------------------------------------------------
--[[
    Load Exported Items
    @desc   Load exported items from disk (persists across reboots)
    @return void
]]
local function loadExportedItems()
    if fs.exists(EXPORTED_ITEMS_FILE) then
        local file = fs.open(EXPORTED_ITEMS_FILE, "r")
        local content = file.readAll()
        file.close()
        local success, data = pcall(textutils.unserialize, content)
        if success and data then
            exportedItems = data
            logMessage("INFO", "Loaded exported items from disk")
        end
    end
end

--[[
    Save Exported Items
    @desc   Save exported items to disk
    @return void
]]
local function saveExportedItems()
    local file = fs.open(EXPORTED_ITEMS_FILE, "w")
    file.write(textutils.serialize(exportedItems))
    file.close()
end

--[[
    Get Exported Item Count
    @desc   Get count of items currently exported (in transit)
    @param  itemName - The item name to check
    @return number - Count of items in transit
]]
local function getExportedItemCount(itemName)
    if exportedItems[itemName] then
        return exportedItems[itemName].count
    end
    return 0
end

--[[
    Add Exported Item
    @desc   Track an item that was exported to the output chest
    @param  itemName - The item being exported
    @param  count - How many were exported
    @return void
]]
local function addExportedItem(itemName, count)
    if exportedItems[itemName] then
        exportedItems[itemName].count = exportedItems[itemName].count + count
        exportedItems[itemName].timestamp = os.clock()
    else
        exportedItems[itemName] = { count = count, timestamp = os.clock() }
    end
    saveExportedItems()
    logMessage("DEBUG", "Added exported item", { item = itemName, count = count, total = exportedItems[itemName].count })
end

--[[
    Clear Exported Item
    @desc   Remove exported item tracking when request is fulfilled
    @param  itemName - The item name
    @param  countDelivered - How many were confirmed delivered (request fulfilled)
    @return void
]]
local function clearExportedItem(itemName, countDelivered)
    if exportedItems[itemName] then
        exportedItems[itemName].count = exportedItems[itemName].count - countDelivered
        if exportedItems[itemName].count <= 0 then
            exportedItems[itemName] = nil
        end
        saveExportedItems()
        logMessage("DEBUG", "Cleared exported item", { item = itemName, delivered = countDelivered })
    end
end

--[[
    Get Total Exported Count
    @desc   Get total count of items in transit
    @return number
]]
local function getTotalExportedCount()
    local total = 0
    for _, exportInfo in pairs(exportedItems) do
        total = total + exportInfo.count
    end
    return total
end

--[[
    Reconcile Exported Items
    @desc   Compare current requests with exported items - if request is gone, items were delivered
    @param  currentRequests - List of current colony requests
    @return void
]]
local function reconcileExportedItems(currentRequests)
    -- Build a set of currently requested items
    local requestedItems = {}
    for _, req in ipairs(currentRequests) do
        if req.item and req.item.name then
            if not requestedItems[req.item.name] then
                requestedItems[req.item.name] = 0
            end
            requestedItems[req.item.name] = requestedItems[req.item.name] + req.needed
        end
    end
    
    -- Check each exported item - if no longer requested, assume delivered
    local toRemove = {}
    for itemName, exportInfo in pairs(exportedItems) do
        if not requestedItems[itemName] or requestedItems[itemName] == 0 then
            -- Request is gone - items were delivered
            table.insert(toRemove, itemName)
            logMessage("INFO", "Exported item confirmed delivered (request fulfilled)", { item = itemName, count = exportInfo.count })
        elseif requestedItems[itemName] < exportInfo.count then
            -- Request reduced - partial delivery
            local delivered = exportInfo.count - requestedItems[itemName]
            exportInfo.count = requestedItems[itemName]
            logMessage("INFO", "Exported item partially delivered", { item = itemName, delivered = delivered, remaining = exportInfo.count })
        end
    end
    
    -- Remove fully delivered items
    for _, itemName in ipairs(toRemove) do
        exportedItems[itemName] = nil
    end
    
    if #toRemove > 0 then
        saveExportedItems()
    end
end

--[[
    Calculate True Deficit
    @desc   Calculate how many items are truly needed after accounting for RS inventory and pending crafts
    @param  itemName - The item name
    @param  needed - How many the colony request needs
    @return number - True deficit that needs to be crafted
]]
local function calculateTrueDeficit(itemName, needed)
    -- Check what's already in RS system
    local inRS = getRSInventoryCount(itemName)
    
    -- Check what's already pending in crafts
    local pending = getPendingCraftCount(itemName)
    
    -- Check what's already exported (in transit to warehouse)
    local exported = getExportedItemCount(itemName)
    
    -- Calculate true deficit
    local available = inRS + pending + exported
    local deficit = needed - available
    
    if deficit < 0 then deficit = 0 end
    
    logMessage("DEBUG", "Calculated true deficit", { 
        item = itemName, 
        needed = needed, 
        inRS = inRS, 
        pending = pending,
        exported = exported,
        deficit = deficit 
    })
    
    return deficit
end

-- Load pending crafts and exported items on startup
loadPendingCrafts()
loadExportedItems()

----------------------------------------------------------------------------
-- SMART TOOL/ARMOR HANDLING
----------------------------------------------------------------------------
--[[
    Parse Tool Level From Description
    @desc   Extract the maximum allowed tool level from request description
    @param  desc - Request description string
    @return string - Material tier name or nil
]]
local function parseToolLevelFromDesc(desc)
    if not desc then return nil end
    
    local tierPatterns = {
        { pattern = "with maximal level: Leather", tier = "leather" },
        { pattern = "with maximal level: Gold", tier = "gold" },
        { pattern = "with maximal level: Chain", tier = "chain" },
        { pattern = "with maximal level: Wood or Gold", tier = "wood" },
        { pattern = "with maximal level: Stone", tier = "stone" },
        { pattern = "with maximal level: Iron", tier = "iron" },
        { pattern = "with maximal level: Diamond", tier = "diamond" },
        { pattern = "with maximal level: Netherite", tier = "netherite" }
    }
    
    for _, tierInfo in ipairs(tierPatterns) do
        if desc:find(tierInfo.pattern) then
            return tierInfo.tier
        end
    end
    return nil
end

--[[
    Get Allowed Materials For Level
    @desc   Get list of allowed material tiers for a building level
    @param  level - Building level (0-5)
    @param  isArmor - true for armor, false for tools
    @return table - List of allowed material names
]]
local function getAllowedMaterialsForLevel(level, isArmor)
    local tiers = isArmor and buildingArmorTiers or buildingToolTiers
    level = math.min(level, 5)
    level = math.max(level, 0)
    return tiers[level] or tiers[0]
end

--[[
    Get Cheapest Allowed Material
    @desc   Find the cheapest material that's allowed for the given level
    @param  level - Building level
    @param  isArmor - true for armor, false for tools
    @return string - Material name
]]
local function getCheapestAllowedMaterial(level, isArmor)
    local allowed = getAllowedMaterialsForLevel(level, isArmor)
    local cheapest = nil
    local cheapestCost = 999
    
    for _, material in ipairs(allowed) do
        local cost = materialCosts[material] or 999
        if cost < cheapestCost then
            cheapestCost = cost
            cheapest = material
        end
    end
    
    return cheapest or "wooden"
end

--[[
    Get Smart Tool Alternatives
    @desc   Generate list of acceptable tool items from cheapest to most expensive
    @param  toolType - Type of tool (Pickaxe, Axe, etc.)
    @param  maxTier - Maximum allowed tier from request
    @param  buildingLevel - Building level for tier restrictions
    @return table - List of item names to try, cheapest first
]]
local function getSmartToolAlternatives(toolType, maxTier, buildingLevel)
    local alternatives = {}
    local allowed = getAllowedMaterialsForLevel(buildingLevel or 0, false)
    
    -- Build list of materials sorted by cost
    local materialList = {}
    for _, material in ipairs(allowed) do
        local cost = materialCosts[material] or 999
        table.insert(materialList, { name = material, cost = cost })
    end
    table.sort(materialList, function(a, b) return a.cost < b.cost end)
    
    -- Generate item names
    local toolNameMap = {
        ["Pickaxe"] = { "minecraft:%s_pickaxe" },
        ["Axe"] = { "minecraft:%s_axe" },
        ["Shovel"] = { "minecraft:%s_shovel" },
        ["Hoe"] = { "minecraft:%s_hoe" },
        ["Sword"] = { "minecraft:%s_sword" }
    }
    
    local patterns = toolNameMap[toolType]
    if not patterns then return alternatives end
    
    for _, mat in ipairs(materialList) do
        for _, pattern in ipairs(patterns) do
            -- Handle naming variations
            local materialName = mat.name
            if materialName == "wood" then materialName = "wooden" end
            if materialName == "gold" then materialName = "golden" end
            
            local itemName = string.format(pattern, materialName)
            table.insert(alternatives, itemName)
        end
    end
    
    return alternatives
end

--[[
    Get Smart Armor Alternatives
    @desc   Generate list of acceptable armor items from cheapest to most expensive
    @param  armorType - Type of armor (Helmet, Chestplate, etc.)
    @param  buildingLevel - Building level for tier restrictions
    @return table - List of item names to try, cheapest first
]]
local function getSmartArmorAlternatives(armorType, buildingLevel)
    local alternatives = {}
    local allowed = getAllowedMaterialsForLevel(buildingLevel or 0, true)
    
    -- Build list of materials sorted by cost
    local materialList = {}
    for _, material in ipairs(allowed) do
        local cost = materialCosts[material] or 999
        table.insert(materialList, { name = material, cost = cost })
    end
    table.sort(materialList, function(a, b) return a.cost < b.cost end)
    
    -- Armor naming patterns
    local armorNameMap = {
        ["Helmet"] = { "minecraft:%s_helmet" },
        ["Cap"] = { "minecraft:leather_helmet" },
        ["Chestplate"] = { "minecraft:%s_chestplate" },
        ["Tunic"] = { "minecraft:leather_chestplate" },
        ["Leggings"] = { "minecraft:%s_leggings" },
        ["Pants"] = { "minecraft:leather_leggings" },
        ["Boots"] = { "minecraft:%s_boots" }
    }
    
    local patterns = armorNameMap[armorType]
    if not patterns then return alternatives end
    
    for _, mat in ipairs(materialList) do
        for _, pattern in ipairs(patterns) do
            local materialName = mat.name
            if materialName == "gold" then materialName = "golden" end
            if materialName == "chain" then materialName = "chainmail" end
            
            -- Skip if pattern doesn't have placeholder and material isn't first
            if not pattern:find("%%s") then
                if mat == materialList[1] then
                    table.insert(alternatives, pattern)
                end
            else
                local itemName = string.format(pattern, materialName)
                table.insert(alternatives, itemName)
            end
        end
    end
    
    return alternatives
end

-- Initialize excluded items on load
loadExcludedItems()

--[[
    Write To Log
    @desc   Write the specified `table` to the file with a separator (only when verbose)
    @return void
]]
function writeToLog(data, blockTop, blockBottom)
  if not logHandle then return end
  if not VERBOSE_LOGGING then return end  -- Skip detailed logging for performance
  logHandle.write("\n")
  logHandle.write(blockTop)
  logHandle.write("\n")
  logHandle.write(textutils.serialize(data, { allow_repetitions = true }))
  logHandle.write("\n")
  logHandle.write(blockBottom)
  logHandle.write("\n")
  -- Don't flush here - let it batch
end

--[[
    Flush Log
    @desc   Flush log buffer to disk (call periodically, not every write)
    @return void
]]
function flushLog()
  if logHandle then
    logHandle.flush()
  end
end

--[[
    Process Work Request Item
    @desc Determine if this item can be delivered to the warehouse from the storage
    @return boolean, string (canProcess, requestType: "normal", "tool", "armor", "manual")
]]
function processWorkRequestItem(request)
  -- Check user-defined excluded items first
  if isItemExcluded(request.name) then 
    return false, "manual" 
  end
  
  -- Check excluded categories
  for category, _ in pairs(excludedCategories) do
    if request.name == category then
      return false, "manual"
    end
  end
  
  -- Tool requests - can be smart-fulfilled if enabled
  if string.find(request.desc or "", "Tool of class") then 
    if SMART_TOOL_HANDLING and AUTO_FULFILL_TOOLS then
      return true, "tool"
    end
    return false, "tool" 
  end
  
  -- Individual tool types
  local toolTypes = {"Hoe", "Shovel", "Axe", "Pickaxe", "Sword"}
  for _, toolType in ipairs(toolTypes) do
    if string.find(request.name, toolType) then
      if SMART_TOOL_HANDLING then
        return true, "tool"
      end
      return false, "tool"
    end
  end
  
  -- Bow and Shield
  if string.find(request.name, "Bow") or string.find(request.name, "Shield") then 
    if SMART_TOOL_HANDLING then
      return true, "tool"
    end
    return false, "tool" 
  end
  
  -- Armor types
  local armorTypes = {"Helmet", "Leather Cap", "Chestplate", "Tunic", "Pants", "Leggings", "Boots"}
  for _, armorType in ipairs(armorTypes) do
    if string.find(request.name, armorType) then
      if SMART_TOOL_HANDLING then
        return true, "armor"
      end
      return false, "armor"
    end
  end
  
  -- Always excluded items (system requirements)
  if request.name == "Rallying Banner" then return false, "manual" end
  if request.name == "Crafter" then return false, "manual" end
  if request.name == "Compostable" then return false, "manual" end
  if request.name == "Fertilizer" then return false, "manual" end
  if request.name == "Flowers" then return false, "manual" end
  if request.name == "Food" then return false, "manual" end
  if request.name == "Fuel" then return false, "manual" end
  if request.name == "Smeltable Ore" then return false, "manual" end
  if request.name == "Stack List" then return false, "manual" end
  
  return true, "normal"
end

--[[
    Try Smart Tool Fulfillment
    @desc   Attempt to fulfill a tool request with the cheapest acceptable option
    @param  request - The work request data
    @param  bridge - RS Bridge peripheral
    @param  direction - Export direction
    @return number - Amount provided
]]
function trySmartToolFulfillment(request, bridge, direction)
  if not SMART_TOOL_HANDLING then return 0 end
  
  -- Determine tool type from request name
  local toolType = nil
  for _, t in ipairs({"Pickaxe", "Axe", "Shovel", "Hoe", "Sword"}) do
    if request.name:find(t) then
      toolType = t
      break
    end
  end
  
  if not toolType then return 0 end
  
  -- Get building level from citizen
  local buildingLevel = 0
  if request.colonist and request.colonist.fullName then
    buildingLevel = getCitizenWorkBuildingLevel(request.colonist.fullName)
  end
  
  -- Parse max tier from description
  local maxTier = parseToolLevelFromDesc(request.desc)
  
  -- Get alternatives sorted by cost (cheapest first)
  local alternatives = getSmartToolAlternatives(toolType, maxTier, buildingLevel)
  
  logMessage("DEBUG", "Smart tool alternatives", { 
    toolType = toolType, 
    buildingLevel = buildingLevel, 
    alternatives = #alternatives 
  })
  
  -- Try each alternative until one works
  for _, itemName in ipairs(alternatives) do
    local exportItem = { name = itemName, count = request.needed }
    local success, result = pcall(function() 
      return bridge.exportItem(exportItem, direction) 
    end)
    
    if success and result then
      local provided = 0
      if type(result) == "number" then
        provided = result
      elseif type(result) == "table" and result.count then
        provided = result.count
      end
      
      if provided > 0 then
        logMessage("INFO", "Smart tool fulfilled", { 
          requested = request.name, 
          provided = itemName, 
          count = provided 
        })
        return provided
      end
    end
  end
  
  return 0
end

--[[
    Try Smart Armor Fulfillment
    @desc   Attempt to fulfill an armor request with the cheapest acceptable option
    @param  request - The work request data
    @param  bridge - RS Bridge peripheral
    @param  direction - Export direction
    @return number - Amount provided
]]
function trySmartArmorFulfillment(request, bridge, direction)
  if not SMART_TOOL_HANDLING then return 0 end
  
  -- Determine armor type from request name
  local armorType = nil
  for _, t in ipairs({"Helmet", "Cap", "Chestplate", "Tunic", "Leggings", "Pants", "Boots"}) do
    if request.name:find(t) then
      armorType = t
      break
    end
  end
  
  if not armorType then return 0 end
  
  -- Get building level from citizen
  local buildingLevel = 0
  if request.colonist and request.colonist.fullName then
    buildingLevel = getCitizenWorkBuildingLevel(request.colonist.fullName)
  end
  
  -- Get alternatives sorted by cost (cheapest first)
  local alternatives = getSmartArmorAlternatives(armorType, buildingLevel)
  
  logMessage("DEBUG", "Smart armor alternatives", { 
    armorType = armorType, 
    buildingLevel = buildingLevel, 
    alternatives = #alternatives 
  })
  
  -- Try each alternative until one works
  for _, itemName in ipairs(alternatives) do
    local exportItem = { name = itemName, count = request.needed }
    local success, result = pcall(function() 
      return bridge.exportItem(exportItem, direction) 
    end)
    
    if success and result then
      local provided = 0
      if type(result) == "number" then
        provided = result
      elseif type(result) == "table" and result.count then
        provided = result.count
      end
      
      if provided > 0 then
        logMessage("INFO", "Smart armor fulfilled", { 
          requested = request.name, 
          provided = itemName, 
          count = provided 
        })
        return provided
      end
    end
  end
  
  return 0
end

--[[
    Monitor Print Row Justified
    @desc   Print a line of data to the in-game monitor
    @return void
]]
function mPrintRowJustified(mon, y, pos, text, textcolor)
    w, h = mon.getSize()
    fg = colors.white
    bg = colors.black
 
    if pos == "left" then x = 1 end
    if pos == "center" then x = math.floor((w - #text) / 2) end
    if pos == "right" then x = w - #text end
  
    mon.setTextColor(textcolor)
    mon.setCursorPos(x, y)
    mon.write(text)
    mon.setTextColor(fg)
    mon.setBackgroundColor(bg)
end

--[[
    Draw Button
    @desc   Draw a clickable button on the monitor (supports multi-row height)
    @param  height - optional, defaults to 1
    @return button object with position data
]]
function drawButton(mon, x, y, width, text, bgColor, textColor, height)
    height = height or 1
    mon.setBackgroundColor(bgColor)
    mon.setTextColor(textColor)
    
    -- Draw button background (multiple rows if height > 1)
    for row = 0, height - 1 do
        for i = 0, width - 1 do
            mon.setCursorPos(x + i, y + row)
            mon.write(" ")
        end
    end
    
    -- Center text in button (vertically and horizontally)
    local textX = x + math.floor((width - #text) / 2)
    local textY = y + math.floor(height / 2)
    mon.setCursorPos(textX, textY)
    mon.write(text)
    
    -- Reset colors
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    
    return {x = x, y = y, width = width, height = height, text = text}
end

--[[
    Check Button Click
    @desc   Check if coordinates are within button bounds
    @return boolean
]]
function isButtonClicked(button, clickX, clickY)
    if not button then return false end
    return clickX >= button.x and clickX < button.x + button.width 
       and clickY >= button.y and clickY < button.y + button.height
end
 
--[[
    Display Logs Page
    @desc   Show recent log entries with pagination
    @return table of buttons
]]
function displayLogsPage(mon)
    mon.clear()
    local w, h = mon.getSize()
    local buttons = {}
    
    mPrintRowJustified(mon, 1, "center", "=== LOG VIEWER ===", colors.yellow)
    
    -- Read log file
    if fs.exists(logFile) then
        local f = fs.open(logFile, "r")
        local content = f.readAll()
        f.close()
        
        local lines = {}
        for line in content:gmatch("[^\n]+") do
            table.insert(lines, line)
        end
        
        -- Display lines with pagination
        local displayLines = h - 4
        local startLine = math.max(1, #lines - logPageOffset - displayLines + 1)
        local endLine = math.min(#lines - logPageOffset, #lines)
        
        local row = 3
        for i = endLine, startLine, -1 do
            if row >= h - 1 then break end
            local line = lines[i]
            local truncated = line:sub(1, w - 2)
            
            -- Color code log levels
            local color = colors.white
            if line:find("%[ERROR%]") then color = colors.red
            elseif line:find("%[WARN%]") then color = colors.orange
            elseif line:find("%[INFO%]") then color = colors.lightGray
            elseif line:find("%[DEBUG%]") then color = colors.gray
            end
            
            mon.setTextColor(color)
            mon.setCursorPos(2, row)
            mon.write(truncated)
            row = row + 1
        end
        
        -- Pagination info
        mon.setTextColor(colors.white)
        local pageInfo = string.format("Showing %d-%d of %d", startLine, endLine, #lines)
        mPrintRowJustified(mon, h - 1, "center", pageInfo, colors.lightGray)
    else
        mPrintRowJustified(mon, 3, "center", "No log file found", colors.red)
    end
    
    -- Navigation buttons
    buttons.up = drawButton(mon, 2, h, 8, "UP", colors.blue, colors.white)
    buttons.down = drawButton(mon, 12, h, 8, "DOWN", colors.blue, colors.white)
    buttons.back = drawButton(mon, w - 10, h, 10, "BACK", colors.gray, colors.white)
    
    return buttons
end

--[[
    Display Stats Page
    @desc   Show detailed statistics
    @return table of buttons
]]
function displayStatsPage(mon)
    mon.clear()
    local w, h = mon.getSize()
    local buttons = {}
    
    mPrintRowJustified(mon, 1, "center", "=== STATISTICS ===", colors.cyan)
    
    local row = 3
    mPrintRowJustified(mon, row, "left", "Total Scans: " .. statsData.totalScans, colors.white)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "Last Scan: " .. textutils.formatTime(statsData.lastScanTime, false), colors.white)
    row = row + 2
    
    mPrintRowJustified(mon, row, "left", "Request Types:", colors.yellow)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Citizen Requests: " .. statsData.citizenRequests, colors.white)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Work Orders: " .. statsData.workOrders, colors.white)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Building Resources: " .. statsData.workOrderResources, colors.white)
    row = row + 2
    
    mPrintRowJustified(mon, row, "left", "Export Operations:", colors.yellow)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Total: " .. statsData.totalExports, colors.white)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Successful: " .. statsData.successfulExports, colors.green)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Failed: " .. statsData.failedExports, colors.red)
    row = row + 2
    
    mPrintRowJustified(mon, row, "left", "Craft Operations:", colors.yellow)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Total Scheduled: " .. statsData.totalCrafts, colors.white)
    row = row + 2
    
    -- System info
    mPrintRowJustified(mon, row, "left", "System Info:", colors.yellow)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Day: " .. os.day(), colors.white)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Time: " .. textutils.formatTime(os.time(), false), colors.white)
    row = row + 2
    
    -- Disk space info
    mPrintRowJustified(mon, row, "left", "Disk Space:", colors.yellow)
    row = row + 1
    local freeSpace = fs.getFreeSpace("/")
    local logSize = fs.exists(logFile) and fs.getSize(logFile) or 0
    local freeColor = freeSpace < MIN_FREE_SPACE and colors.red or (freeSpace < MIN_FREE_SPACE * 3 and colors.orange or colors.green)
    mPrintRowJustified(mon, row, "left", "  Free: " .. math.floor(freeSpace / 1000) .. " KB", freeColor)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Log Size: " .. math.floor(logSize / 1000) .. " KB / " .. math.floor(MAX_LOG_SIZE / 1000) .. " KB", colors.white)
    
    -- Back button
    buttons.back = drawButton(mon, w - 10, h, 10, "BACK", colors.gray, colors.white)
    
    return buttons
end

--[[
    Display Settings Page
    @desc   Show scan configuration options with toggle buttons
    @return table of buttons
]]
function displaySettingsPage(mon)
    mon.clear()
    local w, h = mon.getSize()
    local buttons = {}
    
    mPrintRowJustified(mon, 1, "center", "=== SCAN SETTINGS ===", colors.purple)
    
    local row = 3
    
    -- Scan Interval
    mPrintRowJustified(mon, row, "left", "Scan Interval:", colors.yellow)
    row = row + 1
    mPrintRowJustified(mon, row, "left", "  Current: " .. time_between_runs .. " seconds", colors.white)
    row = row + 1
    buttons.interval_down = drawButton(mon, 4, row, 5, " - ", colors.red, colors.white)
    mon.setCursorPos(10, row)
    mon.setTextColor(colors.white)
    mon.write(tostring(time_between_runs) .. "s")
    buttons.interval_up = drawButton(mon, 16, row, 5, " + ", colors.green, colors.white)
    row = row + 2
    
    -- Night Scanning
    mPrintRowJustified(mon, row, "left", "Scan at Night:", colors.yellow)
    row = row + 1
    local nightStatus = SCAN_AT_NIGHT and "ENABLED" or "DISABLED"
    local nightColor = SCAN_AT_NIGHT and colors.green or colors.red
    buttons.toggle_night = drawButton(mon, 4, row, 12, nightStatus, nightColor, colors.white)
    row = row + 2
    
    -- Verbose Logging
    mPrintRowJustified(mon, row, "left", "Verbose Logging:", colors.yellow)
    row = row + 1
    local verboseStatus = VERBOSE_LOGGING and "ENABLED" or "DISABLED"
    local verboseColor = VERBOSE_LOGGING and colors.green or colors.red
    buttons.toggle_verbose = drawButton(mon, 4, row, 12, verboseStatus, verboseColor, colors.white)
    row = row + 2
    
    -- Log Rotation
    mPrintRowJustified(mon, row, "left", "Log Rotation:", colors.yellow)
    row = row + 1
    local rotateStatus = LOG_ROTATE_ENABLED and "ENABLED" or "DISABLED"
    local rotateColor = LOG_ROTATE_ENABLED and colors.green or colors.red
    buttons.toggle_rotate = drawButton(mon, 4, row, 12, rotateStatus, rotateColor, colors.white)
    row = row + 2
    
    -- Smart Tool Handling
    mPrintRowJustified(mon, row, "left", "Smart Tools:", colors.yellow)
    row = row + 1
    local smartStatus = SMART_TOOL_HANDLING and "ENABLED" or "DISABLED"
    local smartColor = SMART_TOOL_HANDLING and colors.green or colors.red
    buttons.toggle_smart = drawButton(mon, 4, row, 12, smartStatus, smartColor, colors.white)
    row = row + 2
    
    -- Excluded Items Management
    mPrintRowJustified(mon, row, "left", "Excluded Items:", colors.yellow)
    row = row + 1
    local excludedCount = 0
    for _ in pairs(excludedItems) do excludedCount = excludedCount + 1 end
    buttons.excluded = drawButton(mon, 4, row, 16, "MANAGE (" .. excludedCount .. ")", colors.blue, colors.white)
    row = row + 2
    
    -- Version info
    mPrintRowJustified(mon, row, "left", "Version: " .. VERSION, colors.lightGray)
    
    -- Back button
    buttons.back = drawButton(mon, w - 10, h, 10, "BACK", colors.gray, colors.white)
    
    return buttons
end

-- Excluded items page state
local excludedPageOffset = 0
local excludedInputMode = false
local excludedInputBuffer = ""

--[[
    Display Excluded Items Page
    @desc   Show and manage excluded items list
    @return table of buttons
]]
function displayExcludedPage(mon)
    mon.clear()
    local w, h = mon.getSize()
    local buttons = {}
    
    mPrintRowJustified(mon, 1, "center", "=== EXCLUDED ITEMS ===", colors.blue)
    
    local row = 3
    
    -- Instructions
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.lightGray)
    mon.write("Items here won't be auto-fulfilled")
    row = row + 2
    
    -- Get excluded items list
    local items = getExcludedItemsList()
    local itemCount = #items
    
    -- Display items with pagination
    local displayLines = h - 10
    local startIdx = excludedPageOffset + 1
    local endIdx = math.min(excludedPageOffset + displayLines, itemCount)
    
    if itemCount == 0 then
        mon.setCursorPos(2, row)
        mon.setTextColor(colors.gray)
        mon.write("No excluded items configured")
        row = row + 1
    else
        buttons.itemButtons = {}
        for i = startIdx, endIdx do
            local item = items[i]
            mon.setCursorPos(2, row)
            mon.setTextColor(colors.white)
            
            -- Truncate if needed
            local displayName = item
            if #displayName > w - 12 then
                displayName = displayName:sub(1, w - 15) .. "..."
            end
            mon.write(displayName)
            
            -- Delete button for each item
            local delBtn = drawButton(mon, w - 8, row, 6, "DEL", colors.red, colors.white)
            delBtn.itemName = item
            table.insert(buttons.itemButtons, delBtn)
            
            row = row + 1
        end
    end
    
    -- Pagination info
    row = h - 5
    mon.setTextColor(colors.lightGray)
    mon.setCursorPos(2, row)
    if itemCount > 0 then
        mon.write(string.format("Showing %d-%d of %d items", startIdx, endIdx, itemCount))
    end
    row = row + 1
    
    -- Navigation and action buttons
    row = h - 3
    if excludedPageOffset > 0 then
        buttons.prev = drawButton(mon, 2, row, 8, "PREV", colors.blue, colors.white)
    end
    if endIdx < itemCount then
        buttons.next = drawButton(mon, 12, row, 8, "NEXT", colors.blue, colors.white)
    end
    
    -- Add new item button
    buttons.add = drawButton(mon, w - 20, row, 10, "ADD NEW", colors.green, colors.white)
    
    -- Back button
    buttons.back = drawButton(mon, w - 10, h, 10, "BACK", colors.gray, colors.white)
    
    return buttons
end

--[[
    Display Pending Crafts Warning Page
    @desc   Full-screen warning when items are stuck - takes over display
    @return table of buttons
]]
function displayPendingWarningPage(mon)
    mon.clear()
    local w, h = mon.getSize()
    local buttons = {}
    
    -- Red warning header
    mon.setBackgroundColor(colors.red)
    for y = 1, 3 do
        mon.setCursorPos(1, y)
        mon.write(string.rep(" ", w))
    end
    mon.setCursorPos(1, 2)
    mon.setTextColor(colors.white)
    local warningTitle = "!! STORAGE OUTPUT WARNING !!"
    mon.setCursorPos(math.floor((w - #warningTitle) / 2) + 1, 2)
    mon.write(warningTitle)
    mon.setBackgroundColor(colors.black)
    
    local row = 5
    
    -- Warning message
    mon.setTextColor(colors.orange)
    mon.setCursorPos(2, row)
    mon.write("Items have been crafted but NOT exported!")
    row = row + 1
    mon.setCursorPos(2, row)
    mon.write("The output chest may be blocked or full.")
    row = row + 2
    
    -- Instructions
    mon.setTextColor(colors.yellow)
    mon.setCursorPos(2, row)
    mon.write("Please check:")
    row = row + 1
    mon.setTextColor(colors.white)
    mon.setCursorPos(4, row)
    mon.write("1. RS Bridge output chest is connected")
    row = row + 1
    mon.setCursorPos(4, row)
    mon.write("2. Items can flow to MineColonies warehouse")
    row = row + 1
    mon.setCursorPos(4, row)
    mon.write("3. No pipe/hopper blockages")
    row = row + 2
    
    -- List stuck items
    mon.setTextColor(colors.cyan)
    mon.setCursorPos(2, row)
    mon.write("Stuck Items (" .. #pendingCraftsWarningItems .. "):")
    row = row + 1
    
    local maxItems = math.min(#pendingCraftsWarningItems, h - row - 4)
    for i = 1, maxItems do
        local item = pendingCraftsWarningItems[i]
        mon.setTextColor(colors.white)
        mon.setCursorPos(4, row)
        local displayName = item.name
        if #displayName > w - 20 then
            displayName = displayName:sub(1, w - 23) .. "..."
        end
        mon.write(item.count .. "x " .. displayName)
        mon.setTextColor(colors.gray)
        mon.write(" (" .. item.scans .. " scans)")
        row = row + 1
    end
    
    if #pendingCraftsWarningItems > maxItems then
        mon.setTextColor(colors.gray)
        mon.setCursorPos(4, row)
        mon.write("... and " .. (#pendingCraftsWarningItems - maxItems) .. " more items")
        row = row + 1
    end
    
    -- Total counts
    row = h - 4
    mon.setTextColor(colors.orange)
    mon.setCursorPos(2, row)
    mon.write("Pending crafts: " .. getTotalPendingCount() .. " items")
    row = row + 1
    mon.setTextColor(colors.cyan)
    mon.setCursorPos(2, row)
    mon.write("In transit to warehouse: " .. getTotalExportedCount() .. " items")
    
    -- Clear button - big and prominent
    row = h - 1
    buttons.clear_warning = drawButton(mon, math.floor(w/2) - 12, row, 24, "CLEAR WARNING & RESET", colors.green, colors.white)
    
    return buttons
end

--[[
    Display Add Excluded Item Page
    @desc   Terminal input for adding new excluded item
    @return table of buttons
]]
function displayAddExcludedPage(mon)
    mon.clear()
    local w, h = mon.getSize()
    local buttons = {}
    
    mPrintRowJustified(mon, 1, "center", "=== ADD EXCLUDED ITEM ===", colors.green)
    
    local row = 4
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.yellow)
    mon.write("Enter item name in terminal")
    row = row + 2
    
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.lightGray)
    mon.write("Current input:")
    row = row + 1
    
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.white)
    mon.write("> " .. excludedInputBuffer .. "_")
    row = row + 3
    
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.gray)
    mon.write("Press ENTER to confirm")
    row = row + 1
    mon.setCursorPos(2, row)
    mon.write("Press ESC or click CANCEL to abort")
    
    -- Confirm and Cancel buttons
    buttons.confirm = drawButton(mon, 2, h - 2, 10, "CONFIRM", colors.green, colors.white)
    buttons.cancel = drawButton(mon, w - 12, h - 2, 10, "CANCEL", colors.red, colors.white)
    
    return buttons
end

--[[
    Display Legend Page
    @desc   Show explanation of status symbols and colors
    @return table of buttons
]]
function displayLegendPage(mon)
    mon.clear()
    local w, h = mon.getSize()
    local buttons = {}
    
    mPrintRowJustified(mon, 1, "center", "=== STATUS LEGEND ===", colors.yellow)
    
    local row = 3
    
    -- Status Icons
    mPrintRowJustified(mon, row, "left", "Status Icons:", colors.yellow)
    row = row + 1
    
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.green)
    mon.write("[OK]")
    mon.setTextColor(colors.white)
    mon.write(" - Fully supplied from storage")
    row = row + 1
    
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.yellow)
    mon.write("[>>]")
    mon.setTextColor(colors.white)
    mon.write(" - Crafting job scheduled")
    row = row + 1
    
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.orange)
    mon.write("[..]")
    mon.setTextColor(colors.white)
    mon.write(" - Partial fill, waiting for crafting")
    row = row + 1
    
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.red)
    mon.write("[XX]")
    mon.setTextColor(colors.white)
    mon.write(" - Failed: Not in storage, no pattern")
    row = row + 1
    
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.orange)
    mon.write("[!>]")
    mon.setTextColor(colors.white)
    mon.write(" - Partial fill, crafting failed")
    row = row + 1
    
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.blue)
    mon.write("[??]")
    mon.setTextColor(colors.white)
    mon.write(" - Manual: Needs player action")
    row = row + 2
    
    -- Progress Format
    mPrintRowJustified(mon, row, "left", "Progress Format:", colors.yellow)
    row = row + 1
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.lightGray)
    mon.write("  [XX] 5/10 = 5 provided of 10 needed")
    row = row + 2
    
    -- Color Meanings  
    mPrintRowJustified(mon, row, "left", "Quick Reference:", colors.yellow)
    row = row + 1
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.green)
    mon.write("  GREEN")
    mon.setTextColor(colors.white)
    mon.write(" = Success")
    mon.setCursorPos(w/2, row)
    mon.setTextColor(colors.yellow)
    mon.write("YELLOW")
    mon.setTextColor(colors.white)
    mon.write(" = Crafting")
    row = row + 1
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.orange)
    mon.write("  ORANGE")
    mon.setTextColor(colors.white)
    mon.write(" = Partial")
    mon.setCursorPos(w/2, row)
    mon.setTextColor(colors.red)
    mon.write("RED")
    mon.setTextColor(colors.white)
    mon.write(" = Failed")
    row = row + 1
    mon.setCursorPos(2, row)
    mon.setTextColor(colors.blue)
    mon.write("  BLUE")
    mon.setTextColor(colors.white)
    mon.write(" = Manual")
    
    -- Back button
    buttons.back = drawButton(mon, w - 10, h, 10, "BACK", colors.gray, colors.white, 2)
    
    return buttons
end

--[[
    Display Timer
    @desc   Update the time on the monitor
    @return void
]]
function displayTimer(mon, t)
    now = os.time()
    cycle = "day"
    cycle_color = colors.orange
    if now >= 4 and now < 6 then
        cycle = "sunrise"
        cycle_color = colors.yellow
    elseif now >= 6 and now < 18 then
        cycle = "day"
        cycle_color = colors.lightBlue
    elseif now >= 18 and now < 19.5 then
        cycle = "sunset"
        cycle_color = colors.magenta
    elseif now >= 19.5 or now < 5 then
        cycle = "night"
        cycle_color = colors.red
    end
 
    timer_color = colors.green
    if t < 15 then timer_color = colors.yellow end
    if t < 5 then timer_color = colors.orange end
 
    mPrintRowJustified(mon, 1, "left", string.format("Time: %s [%s]    ", textutils.formatTime(now, false), cycle), cycle_color)
    
    -- Show timer based on actual pause state, not just cycle
    local showPaused = isNightPaused and not forceUnpause and not SCAN_AT_NIGHT
    if showPaused then 
      mPrintRowJustified(mon, 1, "right", "    Remaining: PAUSED", colors.red)
    else 
      mPrintRowJustified(mon, 1, "right", string.format("    Remaining: %ss", t), timer_color)
    end
end

--[[
    Create Colonist Data
    @desc   Build a table of Colonist making the request
    @return table
]]
function createColonistData(colonist)
  title_words = {}
  words_in_name = 0
  colonist_job = ""
  word_count = 1
  
  for word in colonist:gmatch("%S+") do
    table.insert(title_words, word)
    words_in_name = words_in_name + 1
  end

  if words_in_name >= 3 then colonist_name = title_words[words_in_name-2] .. " " .. title_words[words_in_name]
  else colonist_name = colonist end

  repeat
    if colonist_job ~= "" then colonist_job = colonist_job .. " " end
    colonist_job = colonist_job .. title_words[word_count]
    word_count = word_count + 1
  until word_count > words_in_name - 3
  
  return  { fullName = colonist, titleWords = title_words, job = colonist_job, name = colonist_name, wordsInName = words_in_name }
end

--[[
    Get Work Request List (from colony)
    @desc   Build a table of the work request data from the colony (citizen requests)
    @return table
]]
function getWorkRequestList(colony)
    requestList = {}
    workRequests = colony.getRequests()
    
    logMessage("INFO", "Retrieved citizen work requests from colony", { count = #workRequests })
    statsData.citizenRequests = #workRequests
    
    for w in pairs(workRequests) do
        writeToLog(workRequests[w], "--- Citizen Request start ---", "--- Citizen Request end ---")
        name = workRequests[w].name
        colonist = createColonistData(workRequests[w].target)
        desc = workRequests[w].desc
        item = {}
        
        if workRequests[w].items and workRequests[w].items[1] then
          if not workRequests[w].items[1].nbt or table.empty(workRequests[w].items[1].nbt) then
            item = { name = workRequests[w].items[1].name, count =  workRequests[w].count, displayName = workRequests[w].items[1].displayName}
          else
            item = { name = workRequests[w].items[1].name, count = workRequests[w].count, displayName = workRequests[w].items[1].displayName, nbt =  workRequests[w].items[1].nbt}
          end
          logMessage("DEBUG", "Parsed citizen request item", { name = name, itemName = item.name, count = item.count, hasNBT = item.nbt ~= nil })
        else
          logMessage("WARN", "Citizen request has no items array", { name = name, target = workRequests[w].target })
        end
        needed = workRequests[w].count

        local newRecord = {}
        newRecord.name = name
        newRecord.desc = desc
        newRecord.needed = needed
        newRecord.item = item
        newRecord.colonist = colonist
        newRecord.requestType = "citizen"
        newRecord.requestFor = colonist.fullName
        table.insert(requestList, newRecord)
        writeToLog(newRecord, "--- Citizen Record start ---", "--- Citizen Record end ---")
      end
  return requestList
end

--[[
    Get Work Order Resources (from colony)
    @desc   Build a table of resources needed for building work orders
    @return table
]]
function getWorkOrderResourceList(colony)
    local resourceList = {}
    local workOrders = colony.getWorkOrders()
    
    logMessage("INFO", "Retrieved work orders from colony", { count = #workOrders })
    statsData.workOrders = #workOrders
    
    for _, order in ipairs(workOrders) do
        writeToLog(order, "--- Work Order start ---", "--- Work Order end ---")
        
        -- Only process claimed work orders (being actively worked on)
        if order.isClaimed then
            local resources = colony.getWorkOrderResources(order.id)
            
            if resources then
                logMessage("DEBUG", "Work order resources found", { orderId = order.id, type = order.workOrderType, building = order.type })
                
                for _, resource in ipairs(resources) do
                    -- Only process items that are needed and not available
                    if resource.needed and not resource.available then
                        local item = {}
                        if resource.item then
                            item = { 
                                name = resource.item, 
                                count = resource.needed,
                                displayName = resource.displayName or resource.item
                            }
                        end
                        
                        local newRecord = {}
                        newRecord.name = resource.displayName or resource.item or "Unknown"
                        newRecord.desc = "Work order: " .. order.workOrderType
                        newRecord.needed = resource.needed
                        newRecord.item = item
                        newRecord.requestType = "workorder"
                        newRecord.requestFor = order.type .. " (Level " .. (order.targetLevel or "?") .. ")"
                        newRecord.workOrderId = order.id
                        newRecord.builder = order.builder or "Unassigned"
                        
                        table.insert(resourceList, newRecord)
                        writeToLog(newRecord, "--- Work Order Resource start ---", "--- Work Order Resource end ---")
                        statsData.workOrderResources = statsData.workOrderResources + 1
                    end
                end
            else
                logMessage("WARN", "No resources found for work order", { orderId = order.id })
            end
        end
    end
    
    logMessage("INFO", "Processed work order resources", { totalResources = #resourceList })
    return resourceList
end

--[[
    Display List
    @desc   Update the monitor with the work request items currently in the system
    @return void
]]
function displayList(mon, listName, itemList)
  mPrintRowJustified(mon, row, "center", listName, colors.white)
  row = row + 1
  for e in pairs(itemList) do
      record = itemList[e]
      local w, h = mon.getSize()
      
      -- Build status indicator based on status field
      local statusIcon = ""
      local statusColor = record.color
      if record.status == "done" then
          statusIcon = "[OK] "
          statusColor = colors.green
      elseif record.status == "partial" then
          statusIcon = "[>>] "
          statusColor = colors.yellow
      elseif record.status == "crafting" then
          statusIcon = "[..] "
          statusColor = colors.yellow
      elseif record.status == "failed" then
          statusIcon = "[XX] "
          statusColor = colors.red
      elseif record.status == "partial_fail" then
          statusIcon = "[!>] "
          statusColor = colors.orange
      elseif record.status == "manual" then
          statusIcon = "[??] "
          statusColor = colors.blue
      else
          statusIcon = "[  ] "
      end
      
      -- Show status, progress (provided/needed), and item name
      local progressText = string.format("%d/%d", record.provided, record.needed)
      text = statusIcon .. progressText .. " " .. record.name
      
      mon.setCursorPos(1, row)
      mon.setTextColor(statusColor)
      mon.write(statusIcon)
      
      -- Progress in white or green if complete
      if record.provided >= record.needed then
          mon.setTextColor(colors.green)
      else
          mon.setTextColor(colors.white)
      end
      mon.write(progressText .. " ")
      
      -- Item name in status color
      mon.setTextColor(record.color)
      mon.write(record.name)
      
      -- Show what it's for on right (citizen name or building type)
      local requestedBy = record.colonist or record.requestFor or "Unknown"
      local rightText = requestedBy
      
      -- Truncate if too long to fit
      local usedWidth = #statusIcon + #progressText + 1 + #record.name + 2
      local maxWidth = w - usedWidth
      if #rightText > maxWidth then
        rightText = rightText:sub(1, maxWidth - 1)
      end
      
      mon.setTextColor(colors.lightGray)
      mon.setCursorPos(w - #rightText, row)
      mon.write(rightText)
      
      mon.setTextColor(colors.white)
      row = row + 1
  end
  row = row + 1
end

--[[
    Display Main Page with Navigation Buttons
    @desc   Show work requests and add GUI navigation buttons
    @return table of buttons
]]
function displayMainPage(mon, builder_list, nonbuilder_list, equipment_list, workorder_list)
  mon.clear()
  local w, h = mon.getSize()
  local buttons = {}
  
  -- Row 1: Title centered
  mPrintRowJustified(mon, 1, "center", "RSWarehouse", colors.cyan)
  
  -- Row 2: Status info - left side shows last scan, right shows next/status
  mon.setCursorPos(2, 2)
  mon.setTextColor(colors.lightGray)
  mon.write("Last: " .. textutils.formatTime(statsData.lastScanTime, false))
  
  -- Right side - show pause status or countdown
  local statusText = ""
  local statusColor = colors.lightGray
  if isNightPaused and not forceUnpause and not SCAN_AT_NIGHT then
    statusText = "PAUSED (Night)"
    statusColor = colors.red
  else
    statusText = "Next: " .. current_run .. "s"
  end
  mon.setCursorPos(w - #statusText - 1, 2)
  mon.setTextColor(statusColor)
  mon.write(statusText)
  mon.setTextColor(colors.white)
  
  -- Row 3: Separator line
  mon.setCursorPos(1, 3)
  mon.setTextColor(colors.gray)
  mon.write(string.rep("-", w))
  mon.setTextColor(colors.white)
  
  row = 4
  
  -- Citizen requests
  if not table.empty(builder_list) then displayList(mon, "Builder Requests", builder_list) end
  if not table.empty(nonbuilder_list) then displayList(mon, "Nonbuilder Requests", nonbuilder_list) end
  if not table.empty(equipment_list) then displayList(mon, "Equipment", equipment_list) end
  
  -- Work order resources
  if not table.empty(workorder_list) then 
    if row > 4 then row = row + 1 end
    displayList(mon, "Building Resources", workorder_list) 
  end

  if row == 4 then 
    mPrintRowJustified(mon, row + 2, "center", "No Open Requests", colors.white)
  end
  
  -- Calculate button dimensions - use 2 rows for height, evenly spaced
  local btnHeight = 2
  local btnY = h - btnHeight + 1  -- Start position for 2-row buttons
  local btnWidth = math.floor((w - 10) / 5)  -- 5 buttons with spacing
  
  -- Show force unpause button if paused at night (above the nav buttons)
  if isNightPaused and not forceUnpause and not SCAN_AT_NIGHT then
    buttons.force_unpause = drawButton(mon, 2, btnY - 2, w - 4, "FORCE SCAN", colors.red, colors.white, 1)
  end
  
  -- Navigation buttons - 2 rows tall, evenly spaced
  local spacing = 2
  local startX = 2
  buttons.logs = drawButton(mon, startX, btnY, btnWidth, "LOGS", colors.orange, colors.white, btnHeight)
  startX = startX + btnWidth + spacing
  buttons.stats = drawButton(mon, startX, btnY, btnWidth, "STATS", colors.cyan, colors.white, btnHeight)
  startX = startX + btnWidth + spacing
  buttons.legend = drawButton(mon, startX, btnY, btnWidth, "LEGEND", colors.yellow, colors.white, btnHeight)
  startX = startX + btnWidth + spacing
  buttons.settings = drawButton(mon, startX, btnY, btnWidth, "CONFIG", colors.purple, colors.white, btnHeight)
  buttons.refresh = drawButton(mon, w - btnWidth - 1, btnY, btnWidth, "REFRESH", colors.green, colors.white, btnHeight)
  
  return buttons
end

-- Color References:
-- RED:     Export and craft both failed (item not in storage and no pattern available).
-- ORANGE:  Partial export succeeded but crafting failed (pattern not found).
-- YELLOW:  Crafting job scheduled (either partial fulfillment or full crafting).
-- GREEN:   Order fully filled from existing storage.
-- BLUE:    Player needs to manually fill the order (equipment, Compostables, Fuel, Food, etc.).
--[[
    Scan Work Requests
    @desc   Manages all of the open work requests in the system and attempts to fulfill them from the inventory
    @desc   Not called at night (as determined by the server) since requests cannot be fulfilled anyway
    @return void
]]
function scanWorkRequests(mon, bridge, direction)
    
    print("\nScan starting at", textutils.formatTime(os.time(), false) .. " (" .. os.time() ..").")
    logMessage("INFO", "=== SCAN STARTED ===", { time = os.time(), day = os.day() })
    
    -- Check for stuck pending crafts and trigger warning if needed
    checkPendingCraftsWarning()
    
    statsData.totalScans = statsData.totalScans + 1
    statsData.lastScanTime = os.time()
    
    builder_list = {}
    nonbuilder_list = {}
    equipment_list = {}
    workorder_list = {}
    
    -- Get citizen requests
    requestList = getWorkRequestList(colony)
    
    -- Get work order resources
    workOrderResourceList = getWorkOrderResourceList(colony)
    
    -- Combine both lists for processing
    local allRequests = {}
    for _, req in ipairs(requestList) do
        table.insert(allRequests, req)
    end
    for _, req in ipairs(workOrderResourceList) do
        table.insert(allRequests, req)
    end
    
    -- Reconcile exported items - remove tracking for items that have been delivered
    reconcileExportedItems(allRequests)
    
    logMessage("INFO", "Processing combined requests", { citizen = #requestList, workOrders = #workOrderResourceList, total = #allRequests })
    
    for j, data in ipairs(allRequests) do
        color = colors.blue
        provided = 0
        local status = "pending"  -- Track status: done, partial, crafting, failed, partial_fail, manual

        local canProcess, itemType = processWorkRequestItem(data)
        
        if canProcess then
            local requestInfo = { name = data.name, needed = data.needed, type = data.requestType, itemType = itemType }
            if data.colonist then
                requestInfo.requestedBy = data.colonist.fullName
            else
                requestInfo.requestedBy = data.requestFor
            end
            logMessage("INFO", "Processing request", requestInfo)
            statsData.totalExports = statsData.totalExports + 1
            
            local success, result, err
            
            -- Use smart fulfillment for tools and armor
            if itemType == "tool" and SMART_TOOL_HANDLING then
                provided = trySmartToolFulfillment(data, bridge, direction)
                if provided > 0 then
                    success = true
                    result = provided
                end
            elseif itemType == "armor" and SMART_TOOL_HANDLING then
                provided = trySmartArmorFulfillment(data, bridge, direction)
                if provided > 0 then
                    success = true
                    result = provided
                end
            end
            
            -- If smart fulfillment didn't work or wasn't used, try normal export
            if provided == 0 then
                -- Pre-export verification: Check if items still exist in RS
                -- User may have taken items between scan start and this export attempt
                local currentInRS = 0
                if data.item and data.item.name then
                    currentInRS = getRSInventoryCount(data.item.name)
                end
                
                if currentInRS > 0 then
                    -- Items still available - proceed with export
                    -- Wrap exportItem in pcall to prevent crashes from peripheral disconnects
                    success, result, err = pcall(function() return bridge.exportItem(data.item, direction) end)
                    if not success then
                        -- pcall failed - peripheral error
                        logMessage("ERROR", "Export failed due to peripheral error", { item = data.name, error = tostring(result) })
                        result = nil
                        err = "peripheral disconnect"
                    end
                    
                    -- Handle both number return (legacy) and table return (newer AP versions)
                    if result then
                        if type(result) == "number" then
                            provided = result
                        elseif type(result) == "table" and result.count then
                            provided = result.count
                        else
                            provided = 0
                        end
                    end
                else
                    -- Items were removed from RS (user took them) - auto-craft needed amount
                    logMessage("WARN", "Items no longer in RS - user may have taken them", { item = data.name, needed = data.needed })
                    
                    if data.item and data.item.name then
                        -- Calculate true deficit for the full amount needed
                        local trueDeficit = calculateTrueDeficit(data.item.name, data.needed)
                        
                        if trueDeficit > 0 then
                            local craftFilter = { name = data.item.name, count = trueDeficit }
                            if data.item.nbt then
                                craftFilter.nbt = data.item.nbt
                            end
                            
                            logMessage("INFO", "Auto-crafting items that were removed from RS", { item = data.name, count = trueDeficit })
                            local craftSuccess, craftResult = pcall(function() return bridge.craftItem(craftFilter) end)
                            if craftSuccess and craftResult == true then
                                print("[Auto-Craft]", trueDeficit, "x", data.name, "(items removed)")
                                statsData.totalCrafts = statsData.totalCrafts + 1
                                addPendingCraft(data.item.name, trueDeficit)
                                logMessage("INFO", "Auto-crafting scheduled for removed items", { item = data.name, count = trueDeficit })
                                color = colors.yellow
                                status = "crafting"
                            elseif not craftSuccess then
                                print("[Craft Error]", data.name, "- peripheral disconnect")
                                logMessage("ERROR", "Auto-craft failed due to peripheral error", { item = data.name, error = tostring(craftResult) })
                                color = colors.red
                                status = "failed"
                            else
                                print("[No Pattern]", data.name, "- items removed, no pattern")
                                logMessage("WARN", "Items removed and no crafting pattern available", { item = data.name, needed = data.needed })
                                color = colors.red
                                status = "failed"
                            end
                        else
                            -- Items already pending or exported
                            logMessage("INFO", "Items removed but already pending/exported", { item = data.name, needed = data.needed, trueDeficit = trueDeficit })
                            color = colors.yellow
                            status = "crafting"
                        end
                    end
                    -- Skip to next item since we handled this case
                    provided = 0
                end
            end
            
            if provided and provided > 0 then
                statsData.successfulExports = statsData.successfulExports + 1
                logMessage("INFO", "Export successful", { item = data.name, exported = provided, needed = data.needed })
                
                -- Track exported items (in transit to warehouse)
                if data.item and data.item.name then
                    addExportedItem(data.item.name, provided)
                    -- Clear pending craft tracking for exported items
                    clearPendingCraft(data.item.name, provided)
                end
                
                -- If we didn't fulfill the full request, try to craft the remainder
                if provided < data.needed and data.item.name then
                    local remaining = data.needed - provided
                    
                    -- Calculate true deficit (accounts for items in RS and pending crafts)
                    local trueDeficit = calculateTrueDeficit(data.item.name, remaining)
                    
                    if trueDeficit > 0 then
                        local craftFilter = { name = data.item.name, count = trueDeficit }
                        if data.item.nbt then
                            craftFilter.nbt = data.item.nbt
                        end
                        
                        -- Try to craft - wrap in pcall to prevent crashes from peripheral disconnects
                        logMessage("INFO", "Attempting to craft remaining items", { item = data.name, remaining = remaining, trueDeficit = trueDeficit })
                        local success, craftResult = pcall(function() return bridge.craftItem(craftFilter) end)
                        if success and craftResult == true then
                            print("[Crafting]", trueDeficit, "x", data.name)
                            statsData.totalCrafts = statsData.totalCrafts + 1
                            addPendingCraft(data.item.name, trueDeficit)
                            logMessage("INFO", "Crafting scheduled", { item = data.name, count = trueDeficit })
                            color = colors.yellow
                            status = "crafting"
                        elseif not success then
                            -- pcall failed - peripheral error or disconnect
                            print("[Craft Error]", data.name, "- peripheral disconnect")
                            logMessage("ERROR", "Crafting failed due to peripheral error", { item = data.name, error = tostring(craftResult) })
                            color = colors.orange
                            status = "partial_fail"
                        else
                            -- craftItem returned false/nil - no pattern exists
                            print("[No Pattern]", data.name, "- partial fill only")
                            logMessage("WARN", "No crafting pattern available for remaining items", { item = data.name, provided = provided, needed = data.needed })
                            color = colors.orange
                            status = "partial_fail"
                        end
                    else
                        -- Items already in RS or pending - no need to craft more
                        logMessage("INFO", "Items already in RS or pending craft", { item = data.name, remaining = remaining, trueDeficit = trueDeficit })
                        color = colors.yellow
                        status = "crafting"
                    end
                elseif provided >= data.needed then
                    logMessage("INFO", "Request fully satisfied from storage", { item = data.name, provided = provided })
                    color = colors.green
                    status = "done"
                else
                    color = colors.lightGray
                    status = "partial"
                end
            else
                statsData.failedExports = statsData.failedExports + 1
                logMessage("WARN", "Export failed - item not in storage", { item = data.name, error = err or "not in storage" })
                -- Export failed, try crafting the full amount
                if data.item.name then
                    -- Calculate true deficit (accounts for items in RS and pending crafts)
                    local trueDeficit = calculateTrueDeficit(data.item.name, data.needed)
                    
                    if trueDeficit > 0 then
                        local craftFilter = { name = data.item.name, count = trueDeficit }
                        if data.item.nbt then
                            craftFilter.nbt = data.item.nbt
                        end
                        
                        -- Try to craft - wrap in pcall to prevent crashes from peripheral disconnects
                        logMessage("INFO", "Attempting to craft full amount", { item = data.name, needed = data.needed, trueDeficit = trueDeficit })
                        local success, craftResult = pcall(function() return bridge.craftItem(craftFilter) end)
                        if success and craftResult == true then
                            print("[Crafting]", trueDeficit, "x", data.name)
                            statsData.totalCrafts = statsData.totalCrafts + 1
                            addPendingCraft(data.item.name, trueDeficit)
                            logMessage("INFO", "Crafting scheduled", { item = data.name, count = trueDeficit })
                            color = colors.yellow
                            status = "crafting"
                        elseif not success then
                            -- pcall failed - peripheral error or disconnect
                            print("[Craft Error]", data.name, "- peripheral disconnect")
                            logMessage("ERROR", "Crafting failed due to peripheral error", { item = data.name, error = tostring(craftResult) })
                            color = colors.red
                            status = "failed"
                        else
                            -- craftItem returned false/nil - no pattern exists
                            print("[No Pattern]", data.name, "- not in storage, no pattern")
                            logMessage("WARN", "Item not in storage and no crafting pattern available", { item = data.name, needed = data.needed })
                            color = colors.red
                            status = "failed"
                        end
                    else
                        -- Items already in RS or pending craft - no need to craft more
                        logMessage("INFO", "Items already in RS or pending craft, skipping new craft", { item = data.name, needed = data.needed, trueDeficit = trueDeficit })
                        color = colors.yellow
                        status = "crafting"
                    end
                else
                    print("[Export Error]", data.name, err or "unknown error")
                    logMessage("ERROR", "Export failed and no item name available for crafting", { name = data.name, error = err })
                    color = colors.red
                    status = "failed"
                end
            end
           
        else 
           local requestedBy = data.colonist and data.colonist.fullName or data.requestFor
           nameString = data.name .. " [" .. requestedBy .. "]"
           print("[Skipped]", nameString)
           logMessage("INFO", "Item skipped - manual fulfillment required", { name = data.name, desc = data.desc, requestedBy = requestedBy, type = data.requestType })
           status = "manual"
        end
        -- ---------------------------------------------------------------------
        -- Build the newList data
        -- ---------------------------------------------------------------------
        local expectedList = ""
        local displayFor = ""
        
        -- Check if this is a work order or citizen request
        if data.requestType == "workorder" then
            expectedList = "WorkOrder"
            displayFor = data.requestFor
            listName = data.name
        else
            -- Citizen request
            expectedList = "Builder"
            displayFor = data.colonist.name
            
            if not string.find(data.colonist.fullName, "Builder") then
                expectedList = ""
                displayFor = data.colonist.job .. " " .. data.colonist.name
                if data.colonist.wordsInName < 3 then
                    displayFor = data.colonist.name
                end
            end
              
            listName = data.name
            if string.find(data.desc, "level") then
                expectedList = "Equipment"
                level = "Any Level"
                if string.find(data.desc, "with maximal level: Leather") then level = "Leather" end
                if string.find(data.desc, "with maximal level: Gold") then level = "Gold" end
                if string.find(data.desc, "with maximal level: Chain") then level = "Chain" end
                if string.find(data.desc, "with maximal level: Wood or Gold") then level = "Wood or Gold" end
                if string.find(data.desc, "with maximal level: Stone") then level = "Stone" end
                if string.find(data.desc, "with maximal level: Iron") then level = "Iron" end
                if string.find(data.desc, "with maximal level: Diamond") then level = "Diamond" end
                listName = level .. " " .. data.name
                if level == "Any Level" then listName = data.name .. " of any level" end
            end
        end
          
        newList = { name=listName, colonist=displayFor, requestFor=data.requestFor, needed=data.needed, provided=provided, color=color, status=status}
        
        if expectedList == "WorkOrder" then
            table.insert(workorder_list, newList)
        elseif expectedList == "Equipment" then
            table.insert(equipment_list, newList)
        elseif expectedList == "Builder" then
            table.insert(builder_list, newList)
        else
            table.insert(nonbuilder_list, newList)
        end
        -- ---------------------------------------------------------------------
    end

  local summary = {
    totalRequests = #allRequests,
    citizenRequests = #requestList,
    workOrderResources = #workOrderResourceList,
    builderRequests = #builder_list,
    nonbuilderRequests = #nonbuilder_list,
    equipmentRequests = #equipment_list,
    buildingRequests = #workorder_list
  }
  print("Scan completed at", textutils.formatTime(os.time(), false) .. " (" .. os.time() ..").") 
  logMessage("INFO", "=== SCAN COMPLETED ===", summary)
  flushLog()  -- Flush all buffered log writes at end of scan
  
  return builder_list, nonbuilder_list, equipment_list, workorder_list
end


--[[
    MAIN
    @desc   establish the run times and execute the work request management
    @return void
]]
-- Initialize display state
current_run = time_between_runs  -- Reset to initial value (global variable)
local builder_list, nonbuilder_list, equipment_list, workorder_list = scanWorkRequests(monitor, bridge, direction)
local currentButtons = displayMainPage(monitor, builder_list, nonbuilder_list, equipment_list, workorder_list)
displayTimer(monitor, current_run)
local TIMER = os.startTimer(1)

logMessage("INFO", "GUI initialized - interactive mode enabled")

while true do
  local e = {os.pullEvent()}
  
  if e[1] == "timer" and e[2] == TIMER then
    now = os.time()
    
    -- Check if we need to show pending crafts warning (takes over display)
    if pendingCraftsWarning and currentPage ~= "warning" then
      currentPage = "warning"
      currentButtons = displayPendingWarningPage(monitor)
      logMessage("WARN", "Displaying pending crafts warning to user")
    end
    
    -- Only update timer on main page
    if currentPage == "main" then
      -- Check if it's daytime (5 AM to 7:30 PM in Minecraft time)
      local isDaytime = (now >= 5 and now < 19.5)
      
      -- Determine if we should scan
      local shouldScan = false
      if isDaytime then
        -- Daytime - always scan, reset force unpause flag
        shouldScan = true
        isNightPaused = false
        if forceUnpause then
          forceUnpause = false  -- Reset force flag when day starts
          logMessage("INFO", "Force unpause reset - daytime started")
        end
      else
        -- Night time - check settings
        if SCAN_AT_NIGHT then
          shouldScan = true
          isNightPaused = false
        elseif forceUnpause then
          shouldScan = true
          isNightPaused = false  -- Show as not paused while force is active
        else
          shouldScan = false
          isNightPaused = true
        end
      end
      
      if shouldScan then
        current_run = current_run - 1
        if current_run <= 0 then
          local scanStart = os.clock()
          builder_list, nonbuilder_list, equipment_list, workorder_list = scanWorkRequests(monitor, bridge, direction)
          local scanTime = os.clock() - scanStart
          print(string.format("Scan took %.2f seconds", scanTime))
          
          -- Check if warning was triggered during scan
          if pendingCraftsWarning then
            currentPage = "warning"
            currentButtons = displayPendingWarningPage(monitor)
          else
            currentButtons = displayMainPage(monitor, builder_list, nonbuilder_list, equipment_list, workorder_list)
          end
          current_run = time_between_runs
        end
      else
        -- Update display to show paused state
        currentButtons = displayMainPage(monitor, builder_list, nonbuilder_list, equipment_list, workorder_list)
      end
      displayTimer(monitor, current_run)
    elseif currentPage == "warning" then
      -- Refresh warning display periodically
      currentButtons = displayPendingWarningPage(monitor)
    end
    TIMER = os.startTimer(1)
    
  elseif e[1] == "monitor_touch" then
    local clickX, clickY = e[3], e[4]
    -- Removed DEBUG logging for touch events to improve responsiveness
    
    -- Warning page takes priority
    if currentPage == "warning" then
      if currentButtons.clear_warning and isButtonClicked(currentButtons.clear_warning, clickX, clickY) then
        clearPendingCraftsWarning()
        currentPage = "main"
        currentButtons = displayMainPage(monitor, builder_list, nonbuilder_list, equipment_list, workorder_list)
        displayTimer(monitor, current_run)
        logMessage("INFO", "User cleared pending crafts warning - returning to main page")
      end
      
    elseif currentPage == "main" then
      -- Check main page buttons
      
      -- Force unpause button (only exists when night paused)
      if currentButtons.force_unpause and isButtonClicked(currentButtons.force_unpause, clickX, clickY) then
        forceUnpause = true
        isNightPaused = false
        logMessage("INFO", "Force unpause activated - scanning will continue until next night cycle")
        -- Trigger immediate scan
        builder_list, nonbuilder_list, equipment_list, workorder_list = scanWorkRequests(monitor, bridge, direction)
        currentButtons = displayMainPage(monitor, builder_list, nonbuilder_list, equipment_list, workorder_list)
        current_run = time_between_runs
        
      elseif isButtonClicked(currentButtons.logs, clickX, clickY) then
        currentPage = "logs"
        logPageOffset = 0
        currentButtons = displayLogsPage(monitor)
        logMessage("INFO", "Switched to logs page")
        
      elseif isButtonClicked(currentButtons.stats, clickX, clickY) then
        currentPage = "stats"
        currentButtons = displayStatsPage(monitor)
        logMessage("INFO", "Switched to stats page")
        
      elseif isButtonClicked(currentButtons.legend, clickX, clickY) then
        currentPage = "legend"
        currentButtons = displayLegendPage(monitor)
        logMessage("INFO", "Switched to legend page")
        
      elseif isButtonClicked(currentButtons.settings, clickX, clickY) then
        currentPage = "settings"
        currentButtons = displaySettingsPage(monitor)
        logMessage("INFO", "Switched to settings page")
        
      elseif isButtonClicked(currentButtons.refresh, clickX, clickY) then
        -- Manual refresh
        os.cancelTimer(TIMER)
        builder_list, nonbuilder_list, equipment_list, workorder_list = scanWorkRequests(monitor, bridge, direction)
        currentButtons = displayMainPage(monitor, builder_list, nonbuilder_list, equipment_list, workorder_list)
        current_run = time_between_runs
        displayTimer(monitor, current_run)
        TIMER = os.startTimer(1)
        logMessage("INFO", "Manual refresh triggered")
      end
      
    elseif currentPage == "logs" then
      -- Check logs page buttons
      if isButtonClicked(currentButtons.up, clickX, clickY) then
        logPageOffset = logPageOffset + 5
        currentButtons = displayLogsPage(monitor)
        
      elseif isButtonClicked(currentButtons.down, clickX, clickY) then
        logPageOffset = math.max(0, logPageOffset - 5)
        currentButtons = displayLogsPage(monitor)
        
      elseif isButtonClicked(currentButtons.back, clickX, clickY) then
        currentPage = "main"
        currentButtons = displayMainPage(monitor, builder_list, nonbuilder_list, equipment_list, workorder_list)
        displayTimer(monitor, current_run)
        logMessage("INFO", "Returned to main page")
      end
      
    elseif currentPage == "stats" then
      -- Check stats page buttons
      if isButtonClicked(currentButtons.back, clickX, clickY) then
        currentPage = "main"
        currentButtons = displayMainPage(monitor, builder_list, nonbuilder_list, equipment_list, workorder_list)
        displayTimer(monitor, current_run)
        logMessage("INFO", "Returned to main page")
      end
      
    elseif currentPage == "legend" then
      -- Check legend page buttons
      if isButtonClicked(currentButtons.back, clickX, clickY) then
        currentPage = "main"
        currentButtons = displayMainPage(monitor, builder_list, nonbuilder_list, equipment_list, workorder_list)
        displayTimer(monitor, current_run)
        logMessage("INFO", "Returned to main page")
      end
      
    elseif currentPage == "settings" then
      -- Check settings page buttons
      if isButtonClicked(currentButtons.interval_down, clickX, clickY) then
        time_between_runs = math.max(5, time_between_runs - 5)
        currentButtons = displaySettingsPage(monitor)
        logMessage("INFO", "Scan interval decreased", { interval = time_between_runs })
        
      elseif isButtonClicked(currentButtons.interval_up, clickX, clickY) then
        time_between_runs = math.min(120, time_between_runs + 5)
        currentButtons = displaySettingsPage(monitor)
        logMessage("INFO", "Scan interval increased", { interval = time_between_runs })
        
      elseif isButtonClicked(currentButtons.toggle_night, clickX, clickY) then
        SCAN_AT_NIGHT = not SCAN_AT_NIGHT
        currentButtons = displaySettingsPage(monitor)
        logMessage("INFO", "Night scanning toggled", { enabled = SCAN_AT_NIGHT })
        
      elseif isButtonClicked(currentButtons.toggle_verbose, clickX, clickY) then
        VERBOSE_LOGGING = not VERBOSE_LOGGING
        currentButtons = displaySettingsPage(monitor)
        logMessage("INFO", "Verbose logging toggled", { enabled = VERBOSE_LOGGING })
        
      elseif isButtonClicked(currentButtons.toggle_rotate, clickX, clickY) then
        LOG_ROTATE_ENABLED = not LOG_ROTATE_ENABLED
        currentButtons = displaySettingsPage(monitor)
        logMessage("INFO", "Log rotation toggled", { enabled = LOG_ROTATE_ENABLED })
        
      elseif isButtonClicked(currentButtons.toggle_smart, clickX, clickY) then
        SMART_TOOL_HANDLING = not SMART_TOOL_HANDLING
        currentButtons = displaySettingsPage(monitor)
        logMessage("INFO", "Smart tool handling toggled", { enabled = SMART_TOOL_HANDLING })
        
      elseif isButtonClicked(currentButtons.excluded, clickX, clickY) then
        currentPage = "excluded"
        excludedPageOffset = 0
        currentButtons = displayExcludedPage(monitor)
        logMessage("INFO", "Switched to excluded items page")
        
      elseif isButtonClicked(currentButtons.back, clickX, clickY) then
        currentPage = "main"
        currentButtons = displayMainPage(monitor, builder_list, nonbuilder_list, equipment_list, workorder_list)
        displayTimer(monitor, current_run)
        logMessage("INFO", "Returned to main page")
      end
      
    elseif currentPage == "excluded" then
      -- Check excluded items page buttons
      if isButtonClicked(currentButtons.back, clickX, clickY) then
        currentPage = "settings"
        currentButtons = displaySettingsPage(monitor)
        logMessage("INFO", "Returned to settings page")
        
      elseif isButtonClicked(currentButtons.prev, clickX, clickY) then
        excludedPageOffset = math.max(0, excludedPageOffset - 10)
        currentButtons = displayExcludedPage(monitor)
        
      elseif isButtonClicked(currentButtons.next, clickX, clickY) then
        excludedPageOffset = excludedPageOffset + 10
        currentButtons = displayExcludedPage(monitor)
        
      elseif isButtonClicked(currentButtons.add, clickX, clickY) then
        currentPage = "add_excluded"
        excludedInputBuffer = ""
        currentButtons = displayAddExcludedPage(monitor)
        print("Enter item name to exclude:")
        logMessage("INFO", "Switched to add excluded item page")
        
      else
        -- Check delete buttons for individual items
        if currentButtons.itemButtons then
          for _, btn in ipairs(currentButtons.itemButtons) do
            if isButtonClicked(btn, clickX, clickY) then
              removeExcludedItem(btn.itemName)
              currentButtons = displayExcludedPage(monitor)
              logMessage("INFO", "Removed excluded item", { item = btn.itemName })
              break
            end
          end
        end
      end
      
    elseif currentPage == "add_excluded" then
      -- Check add excluded item page buttons
      if isButtonClicked(currentButtons.cancel, clickX, clickY) then
        currentPage = "excluded"
        excludedInputBuffer = ""
        currentButtons = displayExcludedPage(monitor)
        logMessage("INFO", "Cancelled adding excluded item")
        
      elseif isButtonClicked(currentButtons.confirm, clickX, clickY) then
        if excludedInputBuffer ~= "" then
          addExcludedItem(excludedInputBuffer)
          print("Added: " .. excludedInputBuffer)
        end
        currentPage = "excluded"
        excludedInputBuffer = ""
        currentButtons = displayExcludedPage(monitor)
      end
    end
    
  elseif e[1] == "char" and currentPage == "add_excluded" then
    -- Handle character input for adding excluded items
    excludedInputBuffer = excludedInputBuffer .. e[2]
    currentButtons = displayAddExcludedPage(monitor)
    
  elseif e[1] == "key" and currentPage == "add_excluded" then
    local key = e[2]
    if key == keys.backspace then
      excludedInputBuffer = excludedInputBuffer:sub(1, -2)
      currentButtons = displayAddExcludedPage(monitor)
    elseif key == keys.enter then
      if excludedInputBuffer ~= "" then
        addExcludedItem(excludedInputBuffer)
        print("Added: " .. excludedInputBuffer)
      end
      currentPage = "excluded"
      excludedInputBuffer = ""
      currentButtons = displayExcludedPage(monitor)
    elseif key == keys.escape then
      currentPage = "excluded"
      excludedInputBuffer = ""
      currentButtons = displayExcludedPage(monitor)
    end
  end
end
