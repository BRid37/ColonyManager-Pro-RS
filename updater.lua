-- RSWarehouse Auto-Updater
-- Checks GitHub for newer commits and updates if available

local VERSION_FILE = ".rswarehouse_version"
local CONFIG_FILE = "config.lua"

-- Load configuration
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local success, config = pcall(dofile, CONFIG_FILE)
        if success and config then
            return config
        end
    end
    -- Default config if file doesn't exist
    return {
        github_repo = "YOUR_GITHUB_USERNAME/RSWarehouse",
        github_branch = "main"
    }
end

-- Get the current saved version (commit SHA)
local function getCurrentVersion()
    if fs.exists(VERSION_FILE) then
        local file = fs.open(VERSION_FILE, "r")
        local version = file.readLine()
        file.close()
        return version
    end
    return nil
end

-- Save the current version
local function saveVersion(sha)
    local file = fs.open(VERSION_FILE, "w")
    file.write(sha)
    file.close()
end

-- Fetch latest commit SHA from GitHub API
local function getLatestCommitSHA(repo, branch)
    local url = "https://api.github.com/repos/" .. repo .. "/commits/" .. branch
    
    local headers = {
        ["Accept"] = "application/vnd.github.v3+json",
        ["User-Agent"] = "ComputerCraft-RSWarehouse"
    }
    
    local response = http.get(url, headers)
    if response then
        local body = response.readAll()
        response.close()
        
        -- Parse JSON to get SHA
        -- Simple pattern matching for sha field
        local sha = body:match('"sha"%s*:%s*"([a-f0-9]+)"')
        return sha
    end
    return nil
end

-- Download a file from GitHub raw content
local function downloadFile(repo, branch, filename)
    local url = "https://raw.githubusercontent.com/" .. repo .. "/" .. branch .. "/" .. filename
    
    local response = http.get(url)
    if response then
        local content = response.readAll()
        response.close()
        
        -- Backup existing file
        if fs.exists(filename) then
            if fs.exists(filename .. ".bak") then
                fs.delete(filename .. ".bak")
            end
            fs.copy(filename, filename .. ".bak")
        end
        
        -- Write new file
        local file = fs.open(filename, "w")
        file.write(content)
        file.close()
        return true
    end
    return false
end

-- Get list of files to update from GitHub
local function getFileList(repo, branch)
    -- Default files to update (config.lua is NOT updated to preserve user settings)
    return {
        "RSWarehouse.lua",
        "updater.lua"
    }
end

-- Main update check function
function checkForUpdates()
    local config = loadConfig()
    local repo = config.github_repo
    local branch = config.github_branch or "main"
    
    if repo == "YOUR_GITHUB_USERNAME/RSWarehouse" then
        print("Update check skipped: Configure github_repo in config.lua")
        return false
    end
    
    print("Checking for updates...")
    print("Repository: " .. repo)
    
    -- Get latest commit SHA
    local latestSHA = getLatestCommitSHA(repo, branch)
    if not latestSHA then
        print("Could not fetch latest version from GitHub")
        return false
    end
    
    local currentSHA = getCurrentVersion()
    print("Current version: " .. (currentSHA and currentSHA:sub(1, 7) or "unknown"))
    print("Latest version:  " .. latestSHA:sub(1, 7))
    
    -- Check if update is needed
    if currentSHA == latestSHA then
        print("Already up to date!")
        return false
    end
    
    print("")
    print("New version available! Updating...")
    
    -- Download updated files
    local files = getFileList(repo, branch)
    local allSuccess = true
    
    for _, filename in ipairs(files) do
        print("  Updating " .. filename .. "...")
        if downloadFile(repo, branch, filename) then
            print("    OK")
        else
            print("    FAILED")
            allSuccess = false
        end
    end
    
    if allSuccess then
        -- Save new version
        saveVersion(latestSHA)
        print("")
        print("Update complete!")
        return true
    else
        print("")
        print("Update partially failed. Some files may need manual update.")
        -- Still save version to avoid repeated failed attempts
        saveVersion(latestSHA)
        return true
    end
end

-- Force update function (ignores version check)
function forceUpdate()
    local config = loadConfig()
    local repo = config.github_repo
    local branch = config.github_branch or "main"
    
    if repo == "YOUR_GITHUB_USERNAME/RSWarehouse" then
        print("Update failed: Configure github_repo in config.lua")
        return false
    end
    
    print("Force updating from GitHub...")
    
    local latestSHA = getLatestCommitSHA(repo, branch)
    local files = getFileList(repo, branch)
    local allSuccess = true
    
    for _, filename in ipairs(files) do
        print("  Downloading " .. filename .. "...")
        if downloadFile(repo, branch, filename) then
            print("    OK")
        else
            print("    FAILED")
            allSuccess = false
        end
    end
    
    if latestSHA then
        saveVersion(latestSHA)
    end
    
    return allSuccess
end

-- Get update info without downloading
function getUpdateInfo()
    local config = loadConfig()
    local repo = config.github_repo
    local branch = config.github_branch or "main"
    
    local latestSHA = getLatestCommitSHA(repo, branch)
    local currentSHA = getCurrentVersion()
    
    return {
        currentVersion = currentSHA,
        latestVersion = latestSHA,
        updateAvailable = (latestSHA ~= nil and currentSHA ~= latestSHA),
        repo = repo,
        branch = branch
    }
end

-- If run directly (not as module), perform update check
if not ... then
    if checkForUpdates() then
        print("")
        print("Rebooting to apply updates...")
        sleep(2)
        os.reboot()
    end
end
