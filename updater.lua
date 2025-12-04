local http = require("socket.http")
local socket = require("socket")
local ltn12 = require("ltn12")
local json = require("dkjson")
local lfs = require("lfs")

-- Try to load luasec for HTTPS, fallback to HTTP if not available
local https
local has_https = pcall(function() https = require("ssl.https") end)

-- HornetMM Updater Configuration
local CONFIG = {
    app_name = "HornetMM",
    updater_version = "1.0.0",
    github_repo = "username/hornetmm",  -- Update with your repo
    asset_pattern = "%.exe$",  -- Match .exe files
    install_dir = ".",
    backup_dir = "backups",
    version_file = "version.txt"
}

-- Utilities
local function print_header()
    print([[
+=======================================+
|                                       |
|         HornetMM Updater v1.0         |
|                                       |
+=======================================+
]])
    print(string.format("Repository: %s", CONFIG.github_repo))
    print()
end

local function animate_loading(message, duration)
    local start_time = socket.gettime()
    local i = 0
    
    while socket.gettime() - start_time < duration do
        i = (i % 3) + 1
        io.write("\r" .. message .. string.rep(".", i) .. "   ")
        io.flush()
        socket.sleep(0.3)
    end
    io.write("\r" .. message .. "... Done!   \n")
end

-- Version file management (from your original code)
local function write_version_file()
    local content = ""
    
    local readFile = io.open(CONFIG.version_file, "r")
    if readFile then
        content = readFile:read("*all")
        readFile:close()
    end
    
    if content == "" then
        local writeFile = io.open(CONFIG.version_file, "w")
        if not writeFile then
            error("Failed to create " .. CONFIG.version_file)
        end
        
        writeFile:write("# Write your version of HornetMM by going into settings, About.\n")
        writeFile:write("version=\n")
        writeFile:close()
    end
end

local function read_current_version()
    local file = io.open(CONFIG.version_file, "r")
    if not file then return nil end
    
    for line in file:lines() do
        local key, val = line:match("(%w+)%s*=%s*([%d%.]+)")
        if key == "version" then
            file:close()
            return val
        end
    end
    
    file:close()
    return nil
end

local function update_version_file(new_version)
    local lines = {}
    local file = io.open(CONFIG.version_file, "r")
    
    if file then
        for line in file:lines() do
            if line:match("^version%s*=") then
                table.insert(lines, "version=" .. new_version)
            else
                table.insert(lines, line)
            end
        end
        file:close()
    else
        lines = {
            "# HornetMM Version",
            "version=" .. new_version
        }
    end
    
    file = io.open(CONFIG.version_file, "w")
    if file then
        file:write(table.concat(lines, "\n") .. "\n")
        file:close()
        return true
    end
    
    return false
end

-- Version comparison
local function parse_version(version_string)
    if not version_string then return {major = 0, minor = 0, patch = 0, original = "0.0.0"} end
    
    local v = tostring(version_string):gsub("^v", "")
    local major, minor, patch = v:match("(%d+)%.(%d+)%.?(%d*)")
    
    return {
        major = tonumber(major) or 0,
        minor = tonumber(minor) or 0,
        patch = tonumber(patch) or 0,
        original = version_string
    }
end

local function compare_versions(v1, v2)
    local ver1 = parse_version(v1)
    local ver2 = parse_version(v2)
    
    if ver1.major ~= ver2.major then
        return ver1.major > ver2.major and 1 or -1
    end
    if ver1.minor ~= ver2.minor then
        return ver1.minor > ver2.minor and 1 or -1
    end
    if ver1.patch ~= ver2.patch then
        return ver1.patch > ver2.patch and 1 or -1
    end
    return 0
end

-- GitHub API functions
local function get_latest_release()
    if not has_https then
        return nil, "HTTPS support not available. Please install luasec: luarocks install luasec"
    end
    
    local url = string.format(
        "https://api.github.com/repos/%s/releases/latest",
        CONFIG.github_repo
    )
    
    local response_body = {}
    local res, code = https.request{
        url = url,
        sink = ltn12.sink.table(response_body),
        headers = {
            ["User-Agent"] = "HornetMM-Updater/" .. CONFIG.updater_version,
            ["Accept"] = "application/vnd.github.v3+json"
        }
    }
    
    if code ~= 200 then
        return nil, "Failed to fetch release info. HTTP code: " .. tostring(code)
    end
    
    local data, pos, err = json.decode(table.concat(response_body))
    if err then
        return nil, "Failed to parse JSON: " .. err
    end
    
    return data
end

local function find_asset(release, pattern)
    if not release.assets then
        return nil, "No assets found in release"
    end
    
    for _, asset in ipairs(release.assets) do
        if asset.name:match(pattern) then
            return asset
        end
    end
    
    return nil, "No matching asset found"
end

-- Download functions
local function download_with_progress(url, filepath)
    if not has_https then
        return false, "HTTPS support not available"
    end
    
    print("Downloading: " .. filepath)
    
    local file = io.open(filepath, "wb")
    if not file then
        return false, "Cannot create file: " .. filepath
    end
    
    local downloaded = 0
    local last_update = 0
    
    local res, code = https.request{
        url = url,
        headers = {
            ["User-Agent"] = "HornetMM-Updater/" .. CONFIG.updater_version,
            ["Accept"] = "application/octet-stream"
        },
        sink = function(chunk, err)
            if chunk then
                file:write(chunk)
                downloaded = downloaded + #chunk
                
                if downloaded - last_update > 102400 then
                    io.write(string.format("\rDownloaded: %.2f MB", downloaded / (1024 * 1024)))
                    io.flush()
                    last_update = downloaded
                end
            end
            return 1
        end
    }
    
    print()
    file:close()
    
    if code == 200 or code == 302 then
        print("Download complete!")
        return true
    else
        os.remove(filepath)
        return false, "Download failed with code: " .. tostring(code)
    end
end

-- Backup and installation
local function create_backup(filename)
    lfs.mkdir(CONFIG.backup_dir)
    
    local source_path = CONFIG.install_dir .. "/" .. filename
    local backup_path = CONFIG.backup_dir .. "/" .. filename .. "." .. os.date("%Y%m%d_%H%M%S")
    
    local source = io.open(source_path, "rb")
    if not source then
        return true  -- No file to backup
    end
    
    print("Creating backup: " .. backup_path)
    local backup = io.open(backup_path, "wb")
    if not backup then
        source:close()
        return false, "Cannot create backup file"
    end
    
    backup:write(source:read("*a"))
    source:close()
    backup:close()
    
    return true
end

local function install_update(asset, temp_file, new_version)
    local target_file = CONFIG.install_dir .. "/" .. asset.name
    
    -- Create backup
    local success, err = create_backup(asset.name)
    if not success then
        print("Warning: " .. err)
        io.write("Continue without backup? (y/n): ")
        if io.read():lower() ~= "y" then
            return false
        end
    end
    
    -- Remove old file if exists
    if lfs.attributes(target_file) then
        local removed, err = os.remove(target_file)
        if not removed then
            return false, "Cannot remove old file: " .. err
        end
    end
    
    -- Move temp file to target
    local success, err = os.rename(temp_file, target_file)
    if not success then
        return false, "Cannot install update: " .. err
    end
    
    -- Update version file
    if not update_version_file(new_version) then
        print("Warning: Could not update version file")
    end
    
    print("Update installed successfully!")
    return true
end

-- Main update logic
local function check_and_update()
    -- Initialize version file
    write_version_file()
    
    -- Read current version
    local current_version = read_current_version()
    if not current_version then
        print("Error: Could not read current version from " .. CONFIG.version_file)
        print("Please set your version in the file.")
        return false
    end
    
    print("Current version: " .. current_version)
    
    -- Animated loading
    animate_loading("Looking for updates", 2)
    
    -- Get latest release
    local release, err = get_latest_release()
    if not release then
        print("Error: " .. err)
        return false
    end
    
    local latest_version = release.tag_name:gsub("^v", "")
    print("Latest version: " .. latest_version)
    
    -- Compare versions
    local comparison = compare_versions(latest_version, current_version)
    
    if comparison <= 0 then
        print("\nYou're already on the latest version!")
        return true
    end
    
    print("\n*** New version available! ***")
    print(string.rep("=", 50))
    print("Release: " .. release.name)
    print("Version: " .. latest_version)
    print("Published: " .. release.published_at)
    
    if release.body and release.body ~= "" then
        print("\nChangelog:")
        print(string.rep("-", 50))
        print(release.body)
        print(string.rep("-", 50))
    end
    
    -- Find matching asset
    local asset, err = find_asset(release, CONFIG.asset_pattern)
    if not asset then
        print("\nError: " .. err)
        return false
    end
    
    print("\nAsset: " .. asset.name)
    print(string.format("Size: %.2f MB", asset.size / (1024 * 1024)))
    
    -- Confirm
    io.write("\nDownload and install? (y/n): ")
    local answer = io.read()
    
    if answer:lower() ~= "y" then
        print("Update cancelled.")
        return false
    end
    
    -- Download
    local temp_file = os.tmpname() .. "_" .. asset.name
    local success, err = download_with_progress(asset.browser_download_url, temp_file)
    
    if not success then
        print("\nError: " .. err)
        return false
    end
    
    -- Install
    success, err = install_update(asset, temp_file, latest_version)
    if not success then
        print("\nError: " .. err)
        os.remove(temp_file)
        return false
    end
    
    -- Cleanup
    os.remove(temp_file)
    
    print("\n" .. string.rep("=", 50))
    print("HornetMM Update Complete!")
    print(string.rep("=", 50))
    print("Please restart HornetMM to use version " .. latest_version)
    
    return true
end

-- Main menu
local function main()
    print_header()
    
    print("1. Check for updates")
    print("2. Show current version")
    print("3. Exit")
    print()
    io.write("Select option: ")
    
    local choice = io.read()
    print()
    
    if choice == "1" then
        check_and_update()
    elseif choice == "2" then
        write_version_file()
        local version = read_current_version()
        if version then
            print("Current version: " .. version)
        else
            print("Version not set in " .. CONFIG.version_file)
        end
    elseif choice == "3" then
        print("Goodbye!")
        return
    else
        print("Invalid option")
    end
    
    print("\nPress Enter to continue...")
    io.read()
end

-- Run
main()