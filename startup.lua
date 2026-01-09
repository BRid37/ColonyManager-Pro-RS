-- ColonyManager-Pro-RS Startup Script
-- Auto-generated startup file for boot configuration
-- This file runs ColonyManager-Pro-RS on computer boot with auto-update checking

local VERSION = "2.0.0"

-- Print startup banner
term.clear()
term.setCursorPos(1, 1)
print("========================================")
print("  ColonyManager-Pro-RS v" .. VERSION)
print("  MineColonies + Refined Storage")
print("========================================")
print("")

-- Check for updates on boot
print("Checking for updates...")
if fs.exists("updater.lua") then
    local success, err = pcall(function()
        dofile("updater.lua")
        if checkForUpdates then
            local updated = checkForUpdates()
            if updated then
                print("")
                print("Update installed! Rebooting in 3 seconds...")
                sleep(3)
                os.reboot()
            else
                print("No updates available.")
            end
        end
    end)
    if not success then
        print("Update check failed: " .. tostring(err))
        print("Continuing with current version...")
    end
else
    print("Updater not found, skipping update check.")
    print("Run installer to enable auto-updates.")
end

print("")

-- Verify required files exist
local requiredFiles = {
    "RSWarehouse.lua"
}

local missingFiles = {}
for _, file in ipairs(requiredFiles) do
    if not fs.exists(file) then
        table.insert(missingFiles, file)
    end
end

if #missingFiles > 0 then
    print("ERROR: Missing required files:")
    for _, file in ipairs(missingFiles) do
        print("  - " .. file)
    end
    print("")
    print("Please run the installer or download")
    print("the missing files from GitHub.")
    print("")
    print("Press any key to exit...")
    os.pullEvent("key")
    return
end

-- Start the main program
print("Starting ColonyManager-Pro-RS...")
sleep(1)

-- Run in protected mode to catch errors
local success, err = pcall(function()
    shell.run("RSWarehouse.lua")
end)

if not success then
    print("")
    print("========================================")
    print("ColonyManager-Pro-RS crashed!")
    print("========================================")
    print("Error: " .. tostring(err))
    print("")
    print("Check the log file for details.")
    print("Press any key to restart...")
    os.pullEvent("key")
    os.reboot()
end
