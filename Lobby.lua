-- ============================================================================
-- CAMERA TD // DEDICATED LOBBY MODULE (Lobby.lua v6.0)
-- Features:
--   1. Cancellable Countdown Auto-Join + 4-Pad Free Elevator Resolver
--   2. Live Match Modifiers Sync & Clear (Hp_Mobs, Speed_Mobs)
--   3. Fast Auto-Summon (1x / 10x) + Animation Skip
--   4. Pre-Match Macro & Gamemode Configuration (shared JSON with Match.lua)
-- ============================================================================

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local GITHUB_LOADER_URL = "https://raw.githubusercontent.com/sergohappwils/CameraTD/refs/heads/main/Macro"
local OBSIDIAN_REPO     = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local FOLDER            = "CameraTD_Macro"
local DELAY_FILE        = FOLDER .. "/startup_delay.txt"
local CACHE_DIR         = FOLDER .. "/cache"
local LOADER_CACHE      = CACHE_DIR .. "/loader_cache.luau"

-- ==================== 1. SINGLETON CLEANUP GUARD ====================
local ENV = (getgenv and getgenv()) or _G
if ENV.__CAM_TD_CONTROLLER then
    pcall(function()
        ENV.__CAM_TD_CONTROLLER.Unload()
    end)
    task.wait(0.2)
end

local Controller = { Running = true, Connections = {}, Unloaded = false }
ENV.__CAM_TD_CONTROLLER = Controller

local function trackConn(conn)
    if conn then
        table.insert(Controller.Connections, conn)
    end
    return conn
end

-- ==================== 2. SERVICES & LOGGING ====================
local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualUser = nil
pcall(function() VirtualUser = game:GetService("VirtualUser") end)

local LP = Players.LocalPlayer or Players.PlayerAdded:Wait()

local MACRO_FOLDER     = FOLDER .. "/macros"
local SETTINGS_FILE    = FOLDER .. "/" .. LP.Name .. "_settings.json"
local SHARED_SKIP_FILE = FOLDER .. "/shared_skip_waves.txt"
local LOG_FILE         = FOLDER .. "/" .. LP.Name .. "_log.txt"

local function ensureFolders()
    pcall(function()
        if makefolder and isfolder then
            if not isfolder(FOLDER) then makefolder(FOLDER) end
            if not isfolder(MACRO_FOLDER) then makefolder(MACRO_FOLDER) end
            if not isfolder(CACHE_DIR) then makefolder(CACHE_DIR) end
        end
    end)
end
ensureFolders()

local logEntries     = {}
local StatusLabels   = {}
local lastLabelTexts = {}

local function cleanStr(val)
    if type(val) ~= "string" then return tostring(val or "") end
    return val:gsub("^<%s*", ""):gsub("%s*>$", ""):match("^%s*(.-)%s*$") or ""
end

local function setLabel(labelObj, text)
    if not labelObj then return end
    local str = tostring(text or "")
    if lastLabelTexts[labelObj] == str then return end
    lastLabelTexts[labelObj] = str
    pcall(function()
        labelObj:SetText(str)
    end)
end

local function addLog(text, isError)
    local prefix = isError and "[ERROR] " or ""
    local line = os.date("%H:%M:%S") .. " | " .. prefix .. tostring(text)
    table.insert(logEntries, 1, line)
    if #logEntries > 30 then
        logEntries[31] = nil
    end
    pcall(function()
        if appendfile and isfile and isfile(LOG_FILE) then
            appendfile(LOG_FILE, line .. "\n")
        elseif writefile then
            writefile(LOG_FILE, line .. "\n")
        end
    end)
    if isError then
        warn("[CameraTD Lobby] " .. tostring(text))
    else
        print("[CameraTD Lobby] " .. tostring(text))
    end
    if StatusLabels.Console then
        setLabel(StatusLabels.Console, table.concat(logEntries, "\n"))
    end
end

local function safeCall(context, fn, ...)
    local args = { ... }
    local ok, res = xpcall(function()
        return fn(table.unpack(args))
    end, function(err)
        return tostring(err)
    end)
    if not ok then
        addLog(context .. " error: " .. tostring(res), true)
        return false, res
    end
    return true, res
end

-- ==================== 3. SHARED SETTINGS & MACRO PROFILES ====================
local function saveJSON(path, data)
    local ok = false
    pcall(function()
        if writefile then
            ensureFolders()
            writefile(path, HttpService:JSONEncode(data))
            ok = true
        end
    end)
    return ok
end

local function loadJSON(path)
    if not isfile or not readfile then return nil end
    local exists = false
    pcall(function() exists = isfile(path) end)
    if not exists then return nil end
    local ok, res = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
    return (ok and type(res) == "table") and res or nil
end

local function listMacroFiles()
    local names, seen = {}, {}
    pcall(function()
        if listfiles and isfolder and isfolder(MACRO_FOLDER) then
            for _, file in ipairs(listfiles(MACRO_FOLDER)) do
                local name = tostring(file):gsub("\\", "/"):match("([^/]+)%.json$")
                if name and not seen[name] then
                    seen[name] = true
                    table.insert(names, name)
                end
            end
        end
    end)
    table.sort(names)
    if #names == 0 then
        table.insert(names, "Farm")
    end
    return names
end

local bootDelay = 7
pcall(function()
    if isfile and readfile and isfile(DELAY_FILE) then
        local num = tonumber(readfile(DELAY_FILE):match("([%d%.]+)"))
        if num and num >= 1 and num <= 60 then bootDelay = num end
    end
end)

local DEFAULTS = {
    -- Lobby Settings
    autoJoinMatch       = false,
    selectedMap         = "Toilet City",
    joinMethod          = "Teleport",
    joinCountdown       = 7,
    useModifiers        = false,
    selectedModifiers   = {},
    autoSummon          = false,
    summonCrate         = "Basic Crate",
    summonAmount        = "10x",
    autoDismissLoading  = true,

    -- In-Game Settings (Shared with Match.lua)
    autoSpeed           = true,
    speedChoice         = 2,
    autoVoteMode        = true,
    selectedMode        = "Insane",
    autoSkip            = true,
    noSkipWaves         = "",
    syncSkipMultiAcc    = true,
    autoReplay          = true,
    autoPlay            = true,
    autoSaveRec         = true,
    disableVFX          = false,
    macroName           = "Farm",
    fpsCap              = 15,
    autoExecute         = true,
    startupDelay        = bootDelay
}

local S = loadJSON(SETTINGS_FILE) or {}
for k, v in pairs(DEFAULTS) do
    if S[k] == nil then S[k] = v end
end

S.selectedMap  = cleanStr(S.selectedMap)
S.joinMethod   = cleanStr(S.joinMethod)
S.summonCrate  = cleanStr(S.summonCrate)
S.summonAmount = cleanStr(S.summonAmount)
S.selectedMode = cleanStr(S.selectedMode)
S.macroName    = cleanStr(S.macroName)

local function normalizeModifiersTable(rawMods)
    local dict = {}
    if type(rawMods) == "table" then
        for k, v in pairs(rawMods) do
            if type(k) == "number" and type(v) == "string" then
                dict[v] = true
            elseif type(k) == "string" and v == true then
                dict[k] = true
            end
        end
    end
    return dict
end

local function modifiersDictToArray(dict)
    local arr = {}
    if type(dict) == "table" then
        for k, v in pairs(dict) do
            if type(k) == "string" and v == true then
                table.insert(arr, k)
            elseif type(k) == "number" and type(v) == "string" then
                table.insert(arr, v)
            end
        end
    end
    table.sort(arr)
    return arr
end

S.selectedModifiers = normalizeModifiersTable(S.selectedModifiers)
if not S.useModifiers then
    S.selectedModifiers = {}
end

S.teleportQueued = ENV.__CAM_TD_TP_ARMED == true

local function saveS()
    pcall(function()
        local t = {}
        for k in pairs(DEFAULTS) do
            t[k] = S[k]
        end
        saveJSON(SETTINGS_FILE, t)
        if writefile then
            ensureFolders()
            writefile(DELAY_FILE, tostring(S.startupDelay or 7))
            if S.syncSkipMultiAcc then
                writefile(SHARED_SKIP_FILE, tostring(S.noSkipWaves or ""))
            end
        end
    end)
end
saveS()

-- ==================== 4. LOAD OBSIDIAN UI LIBRARY ====================
local Library, ThemeManager, SaveManager
safeCall("LoadObsidianLibrary", function()
    Library      = loadstring(game:HttpGet(OBSIDIAN_REPO .. "Library.lua"))()
    ThemeManager = loadstring(game:HttpGet(OBSIDIAN_REPO .. "addons/ThemeManager.lua"))()
    SaveManager  = loadstring(game:HttpGet(OBSIDIAN_REPO .. "addons/SaveManager.lua"))()
end)

if not Library then
    warn("[CameraTD Lobby] Critical: Could not load Obsidian Library.")
    return
end

local Options = Library.Options
local Toggles = Library.Toggles
Library.ForceCheckbox = false
Library.ShowToggleFrameInKeybinds = true

local function notify(title, desc, duration)
    pcall(function()
        Library:Notify({
            Title       = tostring(title),
            Description = tostring(desc),
            Time        = duration or 4
        })
    end)
end

-- ==================== 5. TELEPORT AUTO-EXECUTE & FPS CAP ====================
local function armAutoExecute(showLog)
    local qFunc = queue_on_teleport
        or queueonteleport
        or (syn and syn.queue_on_teleport)
        or (fluxus and fluxus.queue_on_teleport)
        or (delta and delta.queue_on_teleport)
        or (ENV and (ENV.queue_on_teleport or ENV.queueonteleport))

    if not qFunc then
        if showLog then addLog("Executor missing queue_on_teleport", true) end
        return false
    end

    if not S.teleportQueued then
        local payload = string.format([[
            if not game:IsLoaded() then game.Loaded:Wait() end
            local ok, src = pcall(function()
                return game:HttpGet(%q .. "?t=" .. tostring(os.time()))
            end)
            if ok and type(src) == "string" and #src > 60 then
                if writefile then pcall(writefile, %q, src) end
                local fn = loadstring(src)
                if fn then task.spawn(fn) return end
            end
            if isfile and readfile and isfile(%q) then
                local fn = loadstring(readfile(%q))
                if fn then task.spawn(fn) end
            end
        ]], GITHUB_LOADER_URL, LOADER_CACHE, LOADER_CACHE, LOADER_CACHE)

        local ok, err = pcall(qFunc, payload)
        if ok then
            S.teleportQueued = true
            ENV.__CAM_TD_TP_ARMED = true
            if showLog then
                addLog("✅ Auto-Execute Armed (Loader + Cache)!")
                notify("Auto-Execute", "Armed for next teleport!", 3)
            end
            return true
        else
            if showLog then addLog("❌ Auto-Exec Error: " .. tostring(err), true) end
            return false
        end
    else
        if showLog then
            addLog("✅ Auto-Execute is already armed!")
            notify("Auto-Execute", "Already armed for teleport!", 3)
        end
        return true
    end
end

if S.autoExecute then
    armAutoExecute(false)
end

trackConn(LP.OnTeleport:Connect(function()
    if S.autoExecute and not S.teleportQueued then
        armAutoExecute(false)
    end
end))

trackConn(LP.Idled:Connect(function()
    pcall(function()
        if VirtualUser then
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new(100, 100))
        end
    end)
end))

local function applyFPSCap(fps)
    local cap = math.clamp(math.floor(tonumber(fps) or S.fpsCap or 15), 5, 144)
    pcall(function()
        local setfps = setfpscap or set_fps_cap
        if setfps then setfps(cap) end
    end)
end
applyFPSCap(S.fpsCap)

task.spawn(function()
    while Controller.Running do
        applyFPSCap(S.fpsCap)
        task.wait(2.5)
    end
end)

-- ==================== 6. LOBBY REMOTES & ELEVATOR HELPERS ====================
local LobbyRemotes       = {}
local LobbyEngineReady   = false
local activeElevatorName = nil
local ConfigModule       = nil

local function getNetworkRemote(name)
    local found = nil
    pcall(function()
        if shared and shared.Modules and shared.Modules.Network and type(shared.Modules.Network.Get) == "function" then
            found = shared.Modules.Network.Get(name)
        end
        if not found then
            local net = RS:FindFirstChild("ModuleLoader")
                and RS.ModuleLoader:FindFirstChild("Shared")
                and RS.ModuleLoader.Shared:FindFirstChild("Network")
            if net then
                for _, folder in ipairs(net:GetChildren()) do
                    if folder:IsA("Folder") then
                        local r = folder:FindFirstChild(name)
                        if r then
                            found = r
                            break
                        end
                    end
                end
            end
        end
    end)
    return found
end

local function getActiveUIModifiersList()
    local modToggleOn = (Toggles and Toggles.UseModifiersToggle and Toggles.UseModifiersToggle.Value == true) or (S.useModifiers == true)
    if not modToggleOn then
        return {}
    end
    local uiVal = (Options and Options.ElevatorModifiersDropdown and Options.ElevatorModifiersDropdown.Value) or S.selectedModifiers
    return modifiersDictToArray(uiVal)
end

local function syncElevatorModifiersLive(elevName)
    local targetElev = elevName or activeElevatorName
    if not targetElev then return end
    local modRf = LobbyRemotes.ElevatorSetModifiers or getNetworkRemote("ElevatorSetModifiers")
    if not modRf then return end
    local modList = getActiveUIModifiersList()
    pcall(function()
        modRf:InvokeServer(targetElev, modList)
    end)
end

local loadingDismissedOnce = false
local function dismissLobbyLoadingScreen()
    if loadingDismissedOnce then return end
    pcall(function()
        local pg = LP:FindFirstChildOfClass("PlayerGui")
        if not pg then return end
        local loadingGui = pg:FindFirstChild("LoadingGui")
        if not loadingGui then
            loadingDismissedOnce = true
            return
        end
        local playBtn = loadingGui:FindFirstChild("Play")
        if playBtn and playBtn:IsA("GuiButton") and playBtn.Visible and playBtn.Interactable then
            loadingDismissedOnce = true
            if firesignal then
                pcall(function() firesignal(playBtn.Activated) end)
            end
            addLog("Clicked Lobby Play button automatically.")
        end
    end)
end

local function getAvailableLobbyMaps()
    local maps, seen = {}, {}
    local defaultMaps = { "Toilet City", "Desert", "Cameraman HQ", "Halloween Town" }
    pcall(function()
        local ef = workspace:FindFirstChild("Elevators")
        if ef then
            for _, elev in ipairs(ef:GetChildren()) do
                if elev:IsA("Model") then
                    local mName = elev:GetAttribute("Map")
                    if type(mName) == "string" and mName ~= "" and not seen[mName] then
                        seen[mName] = true
                        table.insert(maps, mName)
                    end
                end
            end
        end
    end)
    for _, dm in ipairs(defaultMaps) do
        if not seen[dm] then
            seen[dm] = true
            table.insert(maps, dm)
        end
    end
    local cleanSelected = cleanStr(S.selectedMap)
    if cleanSelected ~= "" and not seen[cleanSelected] then
        table.insert(maps, cleanSelected)
    end
    table.sort(maps)
    return maps
end

local function getAvailableSummonCrates()
    local crates, seen = {}, {}
    pcall(function()
        if not ConfigModule then
            ConfigModule = (shared and shared.Modules and shared.Modules.Config)
                or (RS:FindFirstChild("ModuleLoader") and RS.ModuleLoader:FindFirstChild("Configs") and RS.ModuleLoader.Configs:FindFirstChild("Config") and require(RS.ModuleLoader.Configs.Config))
        end
        if ConfigModule and ConfigModule.GameSettings and type(ConfigModule.GameSettings.SummonCrates) == "table" then
            for _, c in ipairs(ConfigModule.GameSettings.SummonCrates) do
                if type(c) == "table" and type(c.Name) == "string" and not seen[c.Name] then
                    seen[c.Name] = true
                    table.insert(crates, c.Name)
                end
            end
        end
    end)
    for _, fallback in ipairs({ "Basic Crate", "Mythic Crate" }) do
        if not seen[fallback] then
            seen[fallback] = true
            table.insert(crates, fallback)
        end
    end
    return crates
end

local function isOtherPlayerInsidePart(part)
    if not part or not part:IsA("BasePart") then return false end
    local half = part.Size * 0.5
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and plr.Character then
            local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                local rel = part.CFrame:PointToObjectSpace(hrp.Position)
                if math.abs(rel.X) <= (half.X + 1.5) and math.abs(rel.Y) <= (half.Y + 4) and math.abs(rel.Z) <= (half.Z + 1.5) then
                    return true
                end
            end
        end
    end
    return false
end

local function findEmptyElevatorForMap(mapName)
    mapName = cleanStr(mapName)
    local ef = workspace:FindFirstChild("Elevators")
    if not ef then return nil end

    for _, elev in ipairs(ef:GetChildren()) do
        if elev:IsA("Model") and elev:GetAttribute("Map") == mapName then
            local hostId = tonumber(elev:GetAttribute("Host")) or 0
            local pCount = tonumber(elev:GetAttribute("Players")) or 0
            if hostId == LP.UserId and pCount <= 1 then
                return elev
            end
        end
    end

    for _, elev in ipairs(ef:GetChildren()) do
        if elev:IsA("Model") and elev:GetAttribute("Map") == mapName then
            local pCount = tonumber(elev:GetAttribute("Players")) or 0
            local hostId = tonumber(elev:GetAttribute("Host")) or 0
            local areaPart = elev:FindFirstChild("Area") or elev:FindFirstChild("BasePart") or elev.PrimaryPart
            if pCount == 0 and hostId == 0 and not isOtherPlayerInsidePart(areaPart) then
                return elev
            end
        end
    end

    return nil
end

local function getLobbyCoins()
    local coins = 0
    pcall(function()
        local hud = LP:FindFirstChild("PlayerGui") and LP.PlayerGui:FindFirstChild("HUD")
        local amtLbl = hud and hud:FindFirstChild("Currencies")
            and hud.Currencies:FindFirstChild("Money")
            and hud.Currencies.Money:FindFirstChild("CurrencyFrame")
            and hud.Currencies.Money.CurrencyFrame:FindFirstChild("AmountLabel")
        if amtLbl and amtLbl:IsA("TextLabel") and amtLbl.Text ~= "" then
            local num = tonumber(amtLbl.Text:gsub("[^%d]", ""))
            if num then
                coins = num
                return
            end
        end
        local ls = LP:FindFirstChild("leaderstats")
        local cObj = ls and (ls:FindFirstChild("Coins") or ls:FindFirstChild("Money"))
        if cObj then
            coins = tonumber(tostring(cObj.Value):gsub("[^%d]", "")) or 0
        end
    end)
    return coins
end

-- ==================== 7. BUILD OBSIDIAN WINDOW & TABS (LOBBY EDITION) ====================
local Window = Library:CreateWindow({
    Title                = "⚡ CAMERA TD // LOBBY STUDIO v6.0",
    Footer               = "v6.0 Modular Lobby Engine | Auto-Join & Summon",
    Position             = UDim2.fromOffset(28, 70),
    Size                 = UDim2.fromOffset(660, 490),
    NotifySide           = "Right",
    ShowCustomCursor     = false,
    Center               = false,
    AutoShow             = true,
    Resizable            = true,
    MobileButtonsSide    = "Left",
    ToggleKeybind        = Enum.KeyCode.RightControl
})

local Tabs = {
    Lobby    = Window:AddTab("Lobby Auto", "compass"),
    PreMatch = Window:AddTab("Match Pre-Config", "zap"),
    PerfExec = Window:AddTab("Perf & Exec", "cpu"),
    Settings = Window:AddTab("Logs & UI", "settings")
}

-- ---------- TAB 1: LOBBY AUTOMATION ----------
local JoinGroup   = Tabs.Lobby:AddLeftGroupbox("Auto Join Match", "door-open")
local SummonGroup = Tabs.Lobby:AddRightGroupbox("Fast Auto Summon", "package-open")

StatusLabels.LobbyState = JoinGroup:AddLabel("Lobby Status: Initializing...", true)
StatusLabels.Countdown  = JoinGroup:AddLabel("Join Timer: Idle", true)
JoinGroup:AddDivider()

local initialMaps = getAvailableLobbyMaps()
JoinGroup:AddDropdown("SelectedMapDropdown", {
    Values   = initialMaps,
    Default  = table.find(initialMaps, S.selectedMap) or 1,
    Multi    = false,
    Text     = "Select Map",
    Callback = function(Value)
        if type(Value) == "string" and Value ~= "" then
            S.selectedMap = cleanStr(Value)
            saveS()
        end
    end
})

local joinMethods = { "Teleport", "Remote Instant" }
JoinGroup:AddDropdown("JoinMethodDropdown", {
    Values   = joinMethods,
    Default  = table.find(joinMethods, S.joinMethod) or 1,
    Multi    = false,
    Text     = "Join Method",
    Callback = function(Value)
        if type(Value) == "string" and Value ~= "" then
            S.joinMethod = cleanStr(Value)
            saveS()
        end
    end
})

JoinGroup:AddToggle("UseModifiersToggle", {
    Text    = "Enable Match Modifiers",
    Default = S.useModifiers == true,
    Callback = function(Value)
        S.useModifiers = Value
        if not Value then
            S.selectedModifiers = {}
            if Options.ElevatorModifiersDropdown then
                pcall(function() Options.ElevatorModifiersDropdown:SetValue({}) end)
            end
        end
        saveS()
        syncElevatorModifiersLive()
    end
})

local initialModifiersArray = S.useModifiers and modifiersDictToArray(S.selectedModifiers) or {}
JoinGroup:AddDropdown("ElevatorModifiersDropdown", {
    Values   = { "Hp_Mobs", "Speed_Mobs" },
    Default  = initialModifiersArray,
    Multi    = true,
    Text     = "Select Modifiers",
    Callback = function(Value)
        if type(Value) == "table" then
            S.selectedModifiers = normalizeModifiersTable(Value)
            saveS()
            syncElevatorModifiersLive()
        end
    end
})

JoinGroup:AddButton({
    Text = "🧹 Clear Modifiers",
    Func = function()
        S.useModifiers = false
        S.selectedModifiers = {}
        if Toggles.UseModifiersToggle then
            pcall(function() Toggles.UseModifiersToggle:SetValue(false) end)
        end
        if Options.ElevatorModifiersDropdown then
            pcall(function() Options.ElevatorModifiersDropdown:SetValue({}) end)
        end
        saveS()
        syncElevatorModifiersLive()
        notify("Modifiers Cleared", "All match modifiers disabled & cleared.", 3)
    end
}):AddButton({
    Text = "↻ Refresh Maps",
    Func = function()
        safeCall("RefreshMapList", function()
            local maps = getAvailableLobbyMaps()
            Options.SelectedMapDropdown:SetValues(maps)
            if table.find(maps, S.selectedMap) then
                Options.SelectedMapDropdown:SetValue(S.selectedMap)
            end
            notify("Maps Refreshed", "Found " .. tostring(#maps) .. " maps.", 3)
        end)
    end
})

JoinGroup:AddDivider()

JoinGroup:AddSlider("JoinCountdownSlider", {
    Text     = "Join Countdown",
    Default  = tonumber(S.joinCountdown) or 7,
    Min      = 1,
    Max      = 15,
    Rounding = 0,
    Suffix   = "s",
    Callback = function(Value)
        S.joinCountdown = Value
        saveS()
    end
})

JoinGroup:AddToggle("AutoJoinMatchToggle", {
    Text    = "Auto Teleport & Start",
    Default = S.autoJoinMatch,
    Callback = function(Value)
        S.autoJoinMatch = Value
        saveS()
        if not Value then
            setLabel(StatusLabels.Countdown, "Join Timer: ⏹ Cancelled / Off")
        end
    end
})

-- Summon Groupbox
StatusLabels.SummonState = SummonGroup:AddLabel("Summon Status: Idle", true)
SummonGroup:AddDivider()

local initialCrates = getAvailableSummonCrates()
SummonGroup:AddDropdown("SummonCrateDropdown", {
    Values   = initialCrates,
    Default  = table.find(initialCrates, S.summonCrate) or 1,
    Multi    = false,
    Text     = "Summon Crate",
    Callback = function(Value)
        if type(Value) == "string" and Value ~= "" then
            S.summonCrate = cleanStr(Value)
            saveS()
        end
    end
})

local summonAmounts = { "1x", "10x" }
SummonGroup:AddDropdown("SummonAmountDropdown", {
    Values   = summonAmounts,
    Default  = table.find(summonAmounts, S.summonAmount) or 2,
    Multi    = false,
    Text     = "Summon Amount",
    Callback = function(Value)
        if type(Value) == "string" and Value ~= "" then
            S.summonAmount = cleanStr(Value)
            saveS()
        end
    end
})

SummonGroup:AddToggle("AutoSummonToggle", {
    Text    = "Fast Auto Summon",
    Default = S.autoSummon,
    Callback = function(Value)
        S.autoSummon = Value
        saveS()
        if not Value then
            setLabel(StatusLabels.SummonState, "Summon Status: ⏹ Stopped")
        end
    end
})

SummonGroup:AddButton({
    Text = "Summon 1x",
    Func = function()
        task.spawn(function()
            safeCall("ManualSummon1x", function()
                local rf = LobbyRemotes.SummonTowers or getNetworkRemote("SummonTowers")
                if not rf then
                    notify("Summon", "SummonTowers remote not ready.", 3)
                    return
                end
                local res = rf:InvokeServer(cleanStr(S.summonCrate or "Basic Crate"), 1)
                if type(res) == "table" and #res > 0 then
                    addLog("Summoned 1x: Got " .. tostring(res[1].Name or "Unit"))
                end
            end)
        end)
    end
}):AddButton({
    Text = "Summon 10x",
    Func = function()
        task.spawn(function()
            safeCall("ManualSummon10x", function()
                local rf = LobbyRemotes.SummonTowers or getNetworkRemote("SummonTowers")
                if not rf then
                    notify("Summon", "SummonTowers remote not ready.", 3)
                    return
                end
                local res = rf:InvokeServer(cleanStr(S.summonCrate or "Basic Crate"), 10)
                if type(res) == "table" and #res > 0 then
                    addLog("Summoned 10x: Got " .. tostring(#res) .. " units!")
                end
            end)
        end)
    end
})

SummonGroup:AddDivider()
SummonGroup:AddToggle("AutoDismissLoadingToggle", {
    Text    = "Skip Loading Screen",
    Default = S.autoDismissLoading,
    Callback = function(Value)
        S.autoDismissLoading = Value
        saveS()
        if Value then dismissLobbyLoadingScreen() end
    end
})

-- ---------- TAB 2: PRE-MATCH CONFIG (SHARED WITH MATCH.LUA) ----------
local PreMacroGroup = Tabs.PreMatch:AddLeftGroupbox("Pre-Select Match Macro", "clapperboard")
local PreAutoGroup  = Tabs.PreMatch:AddRightGroupbox("Pre-Configure Match Auto", "bot")

local macroList = listMacroFiles()
PreMacroGroup:AddDropdown("LobbyMacroSelect", {
    Values   = macroList,
    Default  = table.find(macroList, S.macroName) or 1,
    Multi    = false,
    Text     = "Active Macro Profile",
    Tooltip  = "Saved to shared settings; Match.lua will automatically run this profile on Wave 1!",
    Callback = function(Value)
        local clean = cleanStr(Value)
        if clean ~= "" then
            S.macroName = clean
            saveS()
        end
    end
})

PreMacroGroup:AddToggle("PreAutoPlayMacroToggle", {
    Text    = "Auto Macro On Wave 1",
    Default = S.autoPlay,
    Callback = function(Value)
        S.autoPlay = Value
        saveS()
    end
})

PreMacroGroup:AddToggle("PreAutoReplayToggle", {
    Text    = "Auto Play Again",
    Default = S.autoReplay,
    Callback = function(Value)
        S.autoReplay = Value
        saveS()
    end
})

PreAutoGroup:AddToggle("PreAutoVoteToggle", {
    Text    = "Auto Vote Gamemode",
    Default = S.autoVoteMode,
    Callback = function(Value)
        S.autoVoteMode = Value
        saveS()
    end
})

local gamemodes = { "Easy", "Normal", "Hard", "Insane", "Nightmare", "HalloweenEasy", "HalloweenHard" }
PreAutoGroup:AddDropdown("PreVoteModeDropdown", {
    Values   = gamemodes,
    Default  = table.find(gamemodes, S.selectedMode) or 4,
    Multi    = false,
    Text     = "Gamemode Selection",
    Callback = function(Value)
        if type(Value) == "string" and Value ~= "" then
            S.selectedMode = cleanStr(Value)
            saveS()
        end
    end
})

PreAutoGroup:AddToggle("PreAutoSkipToggle", {
    Text    = "Auto Skip Wave",
    Default = S.autoSkip,
    Callback = function(Value)
        S.autoSkip = Value
        saveS()
    end
})

PreAutoGroup:AddInput("PreNoSkipWavesInput", {
    Text             = "Stop Skip Waves (e.g. 5-15, 49+)",
    Default          = tostring(S.noSkipWaves or ""),
    Numeric          = false,
    Finished         = false,
    ClearTextOnFocus = false,
    Callback = function(Value)
        S.noSkipWaves = tostring(Value or ""):match("^%s*(.-)%s*$") or ""
        saveS()
    end
})

-- ---------- TAB 3: PERFORMANCE & AUTO-EXECUTE ----------
local ExecGroup = Tabs.PerfExec:AddLeftGroupbox("Teleport Auto-Execute", "rocket")
local PerfGroup = Tabs.PerfExec:AddRightGroupbox("FPS Cap", "gauge")

ExecGroup:AddToggle("AutoExecuteToggle", {
    Text    = "Auto Execute On Hop",
    Default = S.autoExecute,
    Callback = function(Value)
        S.autoExecute = Value
        saveS()
        if Value then armAutoExecute(true) end
    end
})

ExecGroup:AddSlider("StartupDelaySlider", {
    Text     = "Startup Load Delay",
    Default  = tonumber(S.startupDelay) or 7,
    Min      = 1,
    Max      = 60,
    Rounding = 0,
    Suffix   = "s",
    Callback = function(Value)
        S.startupDelay = Value
        saveS()
    end
})

ExecGroup:AddButton({
    Text = "⚡ Arm Auto-Execute Now",
    Func = function()
        S.autoExecute = true
        S.teleportQueued = false
        ENV.__CAM_TD_TP_ARMED = false
        saveS()
        armAutoExecute(true)
    end
})

PerfGroup:AddSlider("FpsCapSlider", {
    Text     = "Hardware FPS Limit",
    Default  = tonumber(S.fpsCap) or 15,
    Min      = 5,
    Max      = 144,
    Rounding = 0,
    Suffix   = " FPS",
    Callback = function(Value)
        S.fpsCap = Value
        saveS()
        applyFPSCap(Value)
    end
})

-- ---------- TAB 4: LOGS & UI SETTINGS ----------
local LogGroup  = Tabs.Settings:AddLeftGroupbox("Live Console Log", "terminal")
local MenuGroup = Tabs.Settings:AddRightGroupbox("Menu Controls", "wrench")

LogGroup:AddButton({
    Text = "Clear Console Log",
    Func = function()
        table.clear(logEntries)
        setLabel(StatusLabels.Console, "Console cleared.")
    end
})
StatusLabels.Console = LogGroup:AddLabel("Initializing Lobby Studio...", true)

MenuGroup:AddLabel("Menu Keybind"):AddKeyPicker("MenuKeybind", {
    Default = "RightControl",
    NoUI    = true,
    Text    = "Menu Keybind"
})
Library.ToggleKeybind = Options.MenuKeybind

MenuGroup:AddButton({
    Text = "Unload Script",
    Func = function()
        Controller.Unload()
    end
})

function Controller.Unload()
    if Controller.Unloaded then return end
    Controller.Unloaded = true
    Controller.Running  = false
    saveS()
    for _, c in ipairs(Controller.Connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(Controller.Connections)
    pcall(function() Library:Unload() end)
end

Library:OnUnload(function()
    Controller.Unload()
end)

-- ==================== 8. LOBBY ENGINE LINKER, AUTO-SUMMON & AUTO-JOIN LOOPS ====================
task.spawn(function()
    while Controller.Running do
        safeCall("LobbyLinker", function()
            if S.autoDismissLoading then
                dismissLobbyLoadingScreen()
            end
            if not LobbyEngineReady then
                LobbyRemotes.SummonTowers         = getNetworkRemote("SummonTowers")
                LobbyRemotes.ElevatorEnter        = getNetworkRemote("ElevatorEnter")
                LobbyRemotes.ElevatorLeave        = getNetworkRemote("ElevatorLeave")
                LobbyRemotes.ElevatorStart        = getNetworkRemote("ElevatorStart")
                LobbyRemotes.ElevatorSetModifiers = getNetworkRemote("ElevatorSetModifiers")

                if LobbyRemotes.SummonTowers and LobbyRemotes.ElevatorEnter then
                    LobbyEngineReady = true
                    local maps = getAvailableLobbyMaps()
                    if Options.SelectedMapDropdown then
                        pcall(function()
                            Options.SelectedMapDropdown:SetValues(maps)
                            if table.find(maps, S.selectedMap) then
                                Options.SelectedMapDropdown:SetValue(S.selectedMap)
                            end
                        end)
                    end
                    local crates = getAvailableSummonCrates()
                    if Options.SummonCrateDropdown then
                        pcall(function()
                            Options.SummonCrateDropdown:SetValues(crates)
                            if table.find(crates, S.summonCrate) then
                                Options.SummonCrateDropdown:SetValue(S.summonCrate)
                            end
                        end)
                    end
                    addLog("✅ Lobby Remotes & Elevators Linked!")
                end
            end
        end)
        task.wait(1.5)
    end
end)

-- Fast Auto-Summon Loop
task.spawn(function()
    local summonCount = 0
    while Controller.Running do
        if S.autoSummon then
            safeCall("AutoSummonLoop", function()
                local rf = LobbyRemotes.SummonTowers or getNetworkRemote("SummonTowers")
                if not rf then
                    setLabel(StatusLabels.SummonState, "Summon Status: ⏳ Waiting for SummonTowers remote...")
                    return
                end

                pcall(function()
                    local mainGui = LP:FindFirstChild("PlayerGui") and LP.PlayerGui:FindFirstChild("Main")
                    local sumFrame = mainGui and mainGui:FindFirstChild("SummonedFrame")
                    if sumFrame and sumFrame.Visible then
                        sumFrame.Visible = false
                    end
                end)

                local crateName = cleanStr(S.summonCrate or "Basic Crate")
                local amtStr    = cleanStr(S.summonAmount or "10x")
                local amtNum    = (amtStr == "10x") and 10 or 1
                local coins     = getLobbyCoins()

                setLabel(StatusLabels.SummonState, string.format(
                    "Summon Status: ⚡ Summoning %s (%s) | Coins: %d | Cycles: %d",
                    crateName, amtStr, coins, summonCount
                ))

                local ok, res, code = pcall(function()
                    return rf:InvokeServer(crateName, amtNum)
                end)

                if ok and type(res) == "table" and #res > 0 then
                    summonCount += 1
                    local names = {}
                    for i = 1, math.min(#res, 3) do
                        if type(res[i]) == "table" and res[i].Name then
                            table.insert(names, tostring(res[i].Name))
                        end
                    end
                    addLog(string.format(
                        "✨ Summoned %dx %s (#%d): %s%s",
                        #res, crateName, summonCount, table.concat(names, ", "),
                        (#res > 3) and (" +" .. tostring(#res - 3) .. " more") or ""
                    ))
                else
                    setLabel(StatusLabels.SummonState, string.format(
                        "Summon Status: 🔄 Waiting/Retry (%s) | Coins: %d | Cycles: %d",
                        tostring(code or "Cooldown/Low Coins"), coins, summonCount
                    ))
                end
            end)
            task.wait(0.55)
        else
            task.wait(0.4)
        end
    end
end)

-- Auto-Join Match Loop
task.spawn(function()
    local function leaveActiveElevator()
        if activeElevatorName then
            local toLeave = activeElevatorName
            activeElevatorName = nil
            pcall(function()
                local leaveRf = LobbyRemotes.ElevatorLeave or getNetworkRemote("ElevatorLeave")
                if leaveRf then leaveRf:InvokeServer(toLeave) end
            end)
        end
    end

    local function triggerStartElevator(elevName, startRf)
        pcall(function()
            local pg = LP:FindFirstChildOfClass("PlayerGui")
            local qf = pg and pg:FindFirstChild("ElevatorGui") and pg.ElevatorGui:FindFirstChild("QueueFrame")
            local readyBtn = qf and qf:FindFirstChild("ReadyButton")
            if readyBtn and readyBtn.Visible and firesignal then
                firesignal(readyBtn.Activated)
            end
        end)
        if startRf and elevName then
            pcall(function() startRf:InvokeServer(elevName) end)
        end
    end

    while Controller.Running do
        safeCall("LobbyAutoJoinLoop", function()
            local targetMap  = cleanStr((Options.SelectedMapDropdown and Options.SelectedMapDropdown.Value) or S.selectedMap or "Toilet City")
            local activeMods = getActiveUIModifiersList()
            local modText    = (#activeMods > 0) and table.concat(activeMods, "+") or "None"

            setLabel(StatusLabels.LobbyState, string.format(
                "Lobby Active | Coins: %d | Map: %s | Mods: %s",
                getLobbyCoins(), targetMap, modText
            ))

            local autoJoinOn = (Toggles.AutoJoinMatchToggle and Toggles.AutoJoinMatchToggle.Value == true)
            if not autoJoinOn then
                leaveActiveElevator()
                return
            end

            if S.autoExecute and not S.teleportQueued then
                armAutoExecute(false)
            end

            local totalSec  = math.clamp(math.floor(tonumber(S.joinCountdown) or 7), 1, 15)
            local cancelled = false

            for rem = totalSec, 1, -1 do
                if not (Toggles.AutoJoinMatchToggle and Toggles.AutoJoinMatchToggle.Value) or not Controller.Running then
                    cancelled = true
                    break
                end
                setLabel(StatusLabels.Countdown, string.format(
                    "⏳ Teleporting into %s in %ds... (Uncheck to cancel)",
                    cleanStr((Options.SelectedMapDropdown and Options.SelectedMapDropdown.Value) or S.selectedMap),
                    rem
                ))
                local stepStart = tick()
                while tick() - stepStart < 1.0 do
                    if not (Toggles.AutoJoinMatchToggle and Toggles.AutoJoinMatchToggle.Value) or not Controller.Running then
                        cancelled = true
                        break
                    end
                    task.wait(0.1)
                end
                if cancelled then break end
            end

            if cancelled or not (Toggles.AutoJoinMatchToggle and Toggles.AutoJoinMatchToggle.Value) or not Controller.Running then
                leaveActiveElevator()
                setLabel(StatusLabels.Countdown, "Join Timer: ⏹ Cancelled by user")
                addLog("⏹ Auto-Join countdown cancelled.")
                return
            end

            targetMap = cleanStr((Options.SelectedMapDropdown and Options.SelectedMapDropdown.Value) or S.selectedMap or "Toilet City")
            local elev = findEmptyElevatorForMap(targetMap)

            if not elev then
                setLabel(StatusLabels.Countdown, string.format("⏳ All pads for %s are busy! Waiting...", targetMap))
                task.wait(1.0)
                return
            end

            local enterRf = LobbyRemotes.ElevatorEnter or getNetworkRemote("ElevatorEnter")
            local startRf = LobbyRemotes.ElevatorStart or getNetworkRemote("ElevatorStart")
            local modRf   = LobbyRemotes.ElevatorSetModifiers or getNetworkRemote("ElevatorSetModifiers")

            if not enterRf or not startRf then
                setLabel(StatusLabels.Countdown, "⏳ Waiting for Elevator remotes...")
                task.wait(1.0)
                return
            end

            local method   = cleanStr((Options.JoinMethodDropdown and Options.JoinMethodDropdown.Value) or S.joinMethod or "Teleport")
            local areaPart = elev:FindFirstChild("Area") or elev:FindFirstChild("Hitbox") or elev:FindFirstChild("BasePart") or elev.PrimaryPart

            setLabel(StatusLabels.Countdown, string.format("🚀 Joining %s (%s) via %s...", elev.Name, targetMap, method))
            addLog(string.format("Joining %s (%s) via %s...", elev.Name, targetMap, method))

            local enteredOk = false
            if method == "Remote Instant" then
                local okEnter, resEnter = pcall(function() return enterRf:InvokeServer(elev.Name) end)
                if (okEnter and resEnter) or (tonumber(elev:GetAttribute("Host")) == LP.UserId) then
                    enteredOk = true
                    activeElevatorName = elev.Name
                end
            end

            if not enteredOk then
                local char = LP.Character
                local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                if hrp and areaPart then
                    hrp.AssemblyLinearVelocity  = Vector3.zero
                    hrp.AssemblyAngularVelocity = Vector3.zero
                    hrp.CFrame = areaPart.CFrame
                end

                local enterWaitStart = tick()
                while tick() - enterWaitStart < 1.2 and (Toggles.AutoJoinMatchToggle and Toggles.AutoJoinMatchToggle.Value) and Controller.Running do
                    if tonumber(elev:GetAttribute("Host")) == LP.UserId then
                        enteredOk = true
                        activeElevatorName = elev.Name
                        break
                    end
                    local pg = LP:FindFirstChildOfClass("PlayerGui")
                    local qf = pg and pg:FindFirstChild("ElevatorGui") and pg.ElevatorGui:FindFirstChild("QueueFrame")
                    if qf and qf.Visible then
                        enteredOk = true
                        activeElevatorName = elev.Name
                        break
                    end
                    task.wait(0.1)
                end

                if not enteredOk and (Toggles.AutoJoinMatchToggle and Toggles.AutoJoinMatchToggle.Value) then
                    local okEnter, resEnter = pcall(function() return enterRf:InvokeServer(elev.Name) end)
                    if (okEnter and resEnter) or (tonumber(elev:GetAttribute("Host")) == LP.UserId) then
                        enteredOk = true
                        activeElevatorName = elev.Name
                    end
                end
            end

            if not (Toggles.AutoJoinMatchToggle and Toggles.AutoJoinMatchToggle.Value) then
                leaveActiveElevator()
                return
            end

            local hostConfirmStart = tick()
            while tick() - hostConfirmStart < 2.0 and (Toggles.AutoJoinMatchToggle and Toggles.AutoJoinMatchToggle.Value) and Controller.Running do
                if (tonumber(elev:GetAttribute("Host")) or 0) == LP.UserId then
                    break
                end
                task.wait(0.1)
            end

            local pCount = tonumber(elev:GetAttribute("Players")) or 0
            local hostId = tonumber(elev:GetAttribute("Host")) or 0
            if (hostId ~= 0 and hostId ~= LP.UserId) or pCount > 1 then
                addLog(string.format("Pad %s occupied by another player! Switching pad...", elev.Name))
                leaveActiveElevator()
                task.wait(0.6)
                return
            end

            task.wait(0.35)

            if modRf then
                local modList = getActiveUIModifiersList()
                if #modList > 0 then
                    pcall(function() modRf:InvokeServer(elev.Name, modList) end)
                    addLog("Applied Modifiers: " .. table.concat(modList, ", "))
                    task.wait(0.35)
                else
                    pcall(function() modRf:InvokeServer(elev.Name, {}) end)
                end
            end

            triggerStartElevator(elev.Name, startRf)
            local lastStartTry = tick()

            setLabel(StatusLabels.Countdown, string.format("✅ Started %s (%s)! Teleporting...", elev.Name, targetMap))
            addLog(string.format("✅ Fired Start on %s (%s)! Waiting for teleport...", elev.Name, targetMap))

            local waitStart = tick()
            while tick() - waitStart < 12.0 and Controller.Running do
                if not (Toggles.AutoJoinMatchToggle and Toggles.AutoJoinMatchToggle.Value) then
                    leaveActiveElevator()
                    addLog("⏹ Left elevator queue (Auto-Join unchecked).")
                    break
                end
                local char = LP.Character
                local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                if hrp and areaPart and (hrp.Position - areaPart.Position).Magnitude > 6 then
                    hrp.AssemblyLinearVelocity = Vector3.zero
                    hrp.CFrame = areaPart.CFrame
                end
                if tick() - lastStartTry >= 3.2 then
                    lastStartTry = tick()
                    triggerStartElevator(elev.Name, startRf)
                end
                task.wait(0.25)
            end
        end)
        task.wait(0.5)
    end
end)

notify("Camera TD Lobby v6.0", "Lobby Module Loaded!", 4)
