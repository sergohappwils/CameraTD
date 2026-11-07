-- ============================================================================
-- CAMERA TD // MATCH STUDIO MODULE (Match.lua v5.7)
-- Fixes:
--   1. Fixed tonumber(str:gsub(...)) 2nd return value bug ('base out of range')
--      that crashed Upgrade Recording & ReplayStep!
--   2. Wrapped all MacroFileSelect:SetValues / :SetValue with suppressDropdownCallback
--   3. Added `if suppressDropdownCallback or S.recording then return end` guard
--   4. Dynamic Game Config Prices + Persistent Godly ($27k) Upgrade Loop
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

-- ==================== 1. SINGLETON & LEGACY UI CLEANUP GUARD ====================
local ENV = (getgenv and getgenv()) or _G
if ENV.__CAM_TD_CONTROLLER then
    pcall(function()
        ENV.__CAM_TD_CONTROLLER.Unload()
    end)
    task.wait(0.2)
end

local function destroyLegacyUI()
    pcall(function()
        if gethui then
            local h = gethui()
            local old = h and h:FindFirstChild("CameraTD_PrecisionV47")
            if old then old:Destroy() end
        end
        local core = game:GetService("CoreGui")
        local oldCore = core and core:FindFirstChild("CameraTD_PrecisionV47")
        if oldCore then oldCore:Destroy() end
        local lp = game:GetService("Players").LocalPlayer
        local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
        local oldPg = pg and pg:FindFirstChild("CameraTD_PrecisionV47")
        if oldPg then oldPg:Destroy() end
    end)
end
destroyLegacyUI()

local Controller = { Running = true, Connections = {}, Unloaded = false }
ENV.__CAM_TD_CONTROLLER = Controller
_G.__CAM_TD_MACRO = true

local function trackConn(conn)
    if conn then
        table.insert(Controller.Connections, conn)
    end
    return conn
end

-- ==================== 2. SERVICES & SAFE PARSING HELPERS ====================
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

-- Safe base-10 integer parser (discards 2nd return value of gsub so tonumber never errors with 'base out of range')
local function parseDigits(val)
    if type(val) == "number" then return val end
    if type(val) ~= "string" then return nil end
    local digits = val:gsub("[^%d]", "")
    if digits == "" then return nil end
    return tonumber(digits, 10)
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
        warn("[CameraTD] " .. tostring(text))
    else
        print("[CameraTD] " .. tostring(text))
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

-- ==================== 3. FILESYSTEM & PERSISTENT SETTINGS ====================
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
        local matchStr = readfile(DELAY_FILE):match("([%d%.]+)")
        local num = matchStr and tonumber(matchStr, 10)
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

    -- In-Game Settings
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

pcall(function()
    if S.syncSkipMultiAcc and isfile and readfile and isfile(SHARED_SKIP_FILE) then
        local sharedFilter = readfile(SHARED_SKIP_FILE)
        if type(sharedFilter) == "string" then S.noSkipWaves = sharedFilter end
    end
end)

-- Runtime state (non-saved)
S.recording        = false
S.replaying        = false
S.paused           = false
S.skipCurrentStep  = false
S.macro            = nil
S.macroPlayed      = false
S.currentStepIndex = 0
S.totalSteps       = 0
S.currentStepText  = "Idle"
S.teleportQueued   = ENV.__CAM_TD_TP_ARMED == true

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
    warn("[CameraTD] Critical: Could not load Obsidian Library from GitHub.")
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

-- ==================== 5. GITHUB + TELEPORT AUTO-EXECUTE ====================
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
                addLog("✅ Auto-Execute Armed (GitHub Live + Cache)!")
                notify("Auto-Execute", "Armed for next teleport!", 3)
            end
            return true
        else
            if showLog then addLog("❌ Auto-Exec Error: " .. tostring(err), true) end
            return false
        end
    else
        if showLog then
            addLog("✅ Auto-Execute is already armed for teleport!")
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

pcall(function()
    local ps = LP:FindFirstChild("PlayerScripts")
    local antiMacro = ps and ps:FindFirstChild("AntiMacro")
    if antiMacro and antiMacro:IsA("LocalScript") then
        antiMacro.Disabled = true
    end
end)

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
        destroyLegacyUI()
        applyFPSCap(S.fpsCap)
        task.wait(2.0)
    end
end)

-- ==================== 6. IN-GAME STATE & DYNAMIC CONFIG HELPERS ====================
local playerGui        = LP:FindFirstChildOfClass("PlayerGui")
local gameUI           = playerGui and playerGui:FindFirstChild("GameUI")
local gameFolder       = workspace:FindFirstChild("Game")
local towersFolder     = gameFolder and gameFolder:FindFirstChild("Towers")

local ConfigModule     = nil
local ConfigTowers     = {}
local Remotes          = {}
local MatchEngineReady = false

-- Dynamically loads Tower Configs from shared.Modules.Config AND ReplicatedStorage.ModuleLoader.Configs.Config.Towers
local function loadDynamicTowerConfigs()
    pcall(function()
        if shared and shared.Modules and type(shared.Modules.Config) == "table" then
            ConfigModule = shared.Modules.Config
            if type(ConfigModule.Towers) == "table" then
                for k, v in pairs(ConfigModule.Towers) do
                    ConfigTowers[k] = v
                end
            end
        end
    end)
    pcall(function()
        local ml = RS:FindFirstChild("ModuleLoader")
        local cfgs = ml and ml:FindFirstChild("Configs")
        local cfgScript = cfgs and cfgs:FindFirstChild("Config")
        local towersRoot = cfgScript and cfgScript:FindFirstChild("Towers")
        if towersRoot then
            for _, desc in ipairs(towersRoot:GetDescendants()) do
                if desc:IsA("ModuleScript") and not ConfigTowers[desc.Name] then
                    task.spawn(function()
                        local ok, mod = pcall(require, desc)
                        if ok and type(mod) == "table" and type(mod.Upgrades) == "table" then
                            ConfigTowers[desc.Name] = mod
                        end
                    end)
                end
            end
        end
    end)
end
task.spawn(loadDynamicTowerConfigs)

local function isWaveSkipBlocked(wave, filterStr)
    if not wave or wave <= 0 then return false end
    local raw = tostring(filterStr or "")
    if raw == "" then return false end
    for token in raw:gmatch("[^,;]+") do
        local s = token:match("^%s*(.-)%s*$")
        if s ~= "" then
            local rStart, rEnd = s:match("^(%d+)%s*%-%s*(%d+)$")
            if rStart and rEnd then
                local a, b = tonumber(rStart, 10), tonumber(rEnd, 10)
                if a and b then
                    if a > b then a, b = b, a end
                    if wave >= a and wave <= b then return true end
                end
            else
                local plusWave = s:match("^(%d+)%s*%+$")
                if plusWave then
                    local a = tonumber(plusWave, 10)
                    if a and wave >= a then return true end
                else
                    local single = tonumber(s, 10)
                    if single and wave == single then return true end
                end
            end
        end
    end
    return false
end

local function applyVFXSetting(disable)
    pcall(function()
        if shared and shared.Modules and shared.Modules.Replication then
            local rep = shared.Modules.Replication.GetCurrentReplica()
            if rep and rep.Data and rep.Data.Settings then
                rep.Data.Settings.VFX = not disable
            end
        end
    end)
end

local function getCash()
    local leaderstats = LP:FindFirstChild("leaderstats")
    local moneyObj = leaderstats and leaderstats:FindFirstChild("Money")
    if moneyObj and moneyObj:IsA("ValueBase") then
        return tonumber(moneyObj.Value) or 0
    end
    if not gameUI then
        playerGui = LP:FindFirstChildOfClass("PlayerGui")
        gameUI = playerGui and playerGui:FindFirstChild("GameUI")
    end
    local title = gameUI and gameUI:FindFirstChild("Stats")
        and gameUI.Stats:FindFirstChild("OtherUI")
        and gameUI.Stats.OtherUI:FindFirstChild("Money")
        and gameUI.Stats.OtherUI.Money:FindFirstChild("Title")
    if title and title:IsA("TextLabel") and title.Text ~= "" then
        local val = parseDigits(title.Text)
        if val then return val end
    end
    return 0
end

local function isGameOver()
    local msg = workspace:GetAttribute("Message")
    if msg == "You Won!" or msg == "You Lost!" then return true end
    local timer = tonumber(workspace:GetAttribute("PlayAgainTimer"))
    if timer and timer > 0 then return true end
    if not gameUI then
        playerGui = LP:FindFirstChildOfClass("PlayerGui")
        gameUI = playerGui and playerGui:FindFirstChild("GameUI")
    end
    local finalUI = gameUI and gameUI:FindFirstChild("FinalUI")
    if finalUI and finalUI:IsA("GuiObject") and finalUI.Visible then return true end
    return false
end

local function hasVotedPlayAgain()
    local votersJson = workspace:GetAttribute("PlayAgainVoters")
    if type(votersJson) == "string" and votersJson ~= "" then
        local ok, list = pcall(function() return HttpService:JSONDecode(votersJson) end)
        if ok and type(list) == "table" and table.find(list, LP.UserId) ~= nil then
            return true
        end
    end
    local btnLbl = gameUI and gameUI:FindFirstChild("FinalUI")
        and gameUI.FinalUI:FindFirstChild("Content")
        and gameUI.FinalUI.Content:FindFirstChild("PlayAgain")
        and gameUI.FinalUI.Content.PlayAgain:FindFirstChildWhichIsA("TextLabel")
    if btnLbl and btnLbl.Text == "Cancel" then
        return true
    end
    return false
end

local function isVotingActive()
    if workspace:GetAttribute("IsVoting") == true then return true end
    if not gameUI then
        playerGui = LP:FindFirstChildOfClass("PlayerGui")
        gameUI = playerGui and playerGui:FindFirstChild("GameUI")
    end
    local votingUI = gameUI and gameUI:FindFirstChild("GamemodeVoting")
    if votingUI and votingUI:IsA("GuiObject") and votingUI.Visible then return true end
    return false
end

local function isMatchActive()
    if isGameOver() or isVotingActive() then return false end
    if workspace:GetAttribute("GameState") == "Restarting" then return false end
    local wave = tonumber(workspace:GetAttribute("Wave"))
    return wave ~= nil and wave >= 1
end

local function getDistanceXZ(pos1, pos2)
    return math.sqrt((pos1.X - pos2.X)^2 + (pos1.Z - pos2.Z)^2)
end

local function getTowerPlacementCost(towerName, recordedCost)
    if not gameUI then
        playerGui = LP:FindFirstChildOfClass("PlayerGui")
        gameUI = playerGui and playerGui:FindFirstChild("GameUI")
    end
    for slot = 1, 5 do
        if LP:GetAttribute("Slot" .. slot) == towerName then
            local slotGui = gameUI and gameUI:FindFirstChild("Slots") and gameUI.Slots:FindFirstChild("Slot" .. slot)
            local pLbl = slotGui and slotGui:FindFirstChild("TroopFrame") and slotGui.TroopFrame:FindFirstChild("Price")
            if pLbl and pLbl:IsA("TextLabel") then
                local num = parseDigits(pLbl.Text)
                if num and num > 0 then return num end
            end
        end
    end
    local tData = ConfigTowers[towerName]
    if tData and tData.Upgrades and tData.Upgrades[1] and tData.Upgrades[1].Price then
        return tonumber(tData.Upgrades[1].Price) or 100
    end
    if recordedCost and tonumber(recordedCost) and tonumber(recordedCost) > 0 then
        return tonumber(recordedCost)
    end
    return 100
end

-- Checks live ConfigTowers[towerName].Upgrades[nextLevel].Price FIRST using safe parseDigits!
local function getTowerUpgradeCost(towerName, nextLevel, recordedCost)
    local tData = ConfigTowers[towerName]
    if tData and tData.Upgrades and tData.Upgrades[nextLevel] and tData.Upgrades[nextLevel].Price then
        local livePrice = tonumber(tData.Upgrades[nextLevel].Price)
        if livePrice and livePrice > 0 then
            local basePlace = tData.Upgrades[1] and tonumber(tData.Upgrades[1].Price)
            if basePlace and basePlace > 0 then
                if not gameUI then
                    playerGui = LP:FindFirstChildOfClass("PlayerGui")
                    gameUI = playerGui and playerGui:FindFirstChild("GameUI")
                end
                for slot = 1, 5 do
                    if LP:GetAttribute("Slot" .. slot) == towerName then
                        local slotGui = gameUI and gameUI:FindFirstChild("Slots") and gameUI.Slots:FindFirstChild("Slot" .. slot)
                        local pLbl = slotGui and slotGui:FindFirstChild("TroopFrame") and slotGui.TroopFrame:FindFirstChild("Price")
                        if pLbl and pLbl:IsA("TextLabel") then
                            local slotPrice = parseDigits(pLbl.Text)
                            if slotPrice and slotPrice > 0 and slotPrice < basePlace then
                                local ratio = slotPrice / basePlace
                                if math.abs(ratio - 0.8) < 0.03 then return math.floor(livePrice * 0.8) end
                                if math.abs(ratio - 0.9) < 0.03 then return math.floor(livePrice * 0.9) end
                            end
                        end
                    end
                end
            end
            return livePrice
        end
    end
    if recordedCost and tonumber(recordedCost) and tonumber(recordedCost) > 0 then
        local rc = tonumber(recordedCost)
        if not (rc == 200 and (tonumber(nextLevel) or 2) >= 4) then
            return rc
        end
    end
    return 200
end

local function resolveUnitIdForTower(towerName, fallbackId)
    for slot = 1, 5 do
        local sName = LP:GetAttribute("Slot" .. slot)
        local sId = LP:GetAttribute("Slot" .. slot .. "Id")
        if sName == towerName and type(sId) == "string" and sId ~= "" then
            return sId
        end
    end
    local foundId = nil
    pcall(function()
        if shared and shared.Modules and shared.Modules.Replication and shared.Modules.Replication.GetCurrentReplica then
            local rep = shared.Modules.Replication.GetCurrentReplica()
            if rep and rep.Data and rep.Data.Towers then
                for id, data in pairs(rep.Data.Towers) do
                    if data.Name == towerName and data.Equipped then
                        foundId = tostring(id)
                        break
                    end
                end
            end
        end
    end)
    return foundId or fallbackId or "1"
end

-- ==================== 7. MACRO RECORDING & REPLAY ENGINE ====================
local recData                  = { version = 5.7, actions = {} }
local TowerIdToPlacementIndex  = {}
local recordedTowerLevels      = {}
local recordedSoldTowers       = {}
local recordedTowerModes       = {}
local pendingUnitIds           = {}
local lastPlaceTime            = 0
local lastPlacePos             = Vector3.zero

local ReplayTowers             = {}
local UsedTowerIds             = {}
local ActiveTowerLevels        = {}
local ActiveTowerModes         = {}
local suppressDropdownCallback = false

local function getLiveTowerLevel(tId)
    if not tId then return 1 end
    tId = tostring(tId)
    local bestLvl = ActiveTowerLevels[tId] or 1

    pcall(function()
        if shared and shared.Modules and shared.Modules.GameReplicator and shared.Modules.GameReplicator.Data and shared.Modules.GameReplicator.Data.Towers then
            local entry = shared.Modules.GameReplicator.Data.Towers[tId] or shared.Modules.GameReplicator.Data.Towers[tonumber(tId, 10)]
            if entry and tonumber(entry.Level) and tonumber(entry.Level) > bestLvl then
                bestLvl = tonumber(entry.Level)
                ActiveTowerLevels[tId] = bestLvl
            end
        end
    end)

    pcall(function()
        if not towersFolder then
            gameFolder = workspace:FindFirstChild("Game")
            towersFolder = gameFolder and gameFolder:FindFirstChild("Towers")
        end
        local model = towersFolder and towersFolder:FindFirstChild(tId)
        local statusGui = model and model:FindFirstChild("TroopStatus", true)
        local lvlLabel = statusGui and statusGui:FindFirstChild("TroopLevel")
        if lvlLabel and lvlLabel:IsA("TextLabel") and lvlLabel.Text ~= "" then
            local parsed = parseDigits(lvlLabel.Text)
            if parsed and parsed > bestLvl then
                bestLvl = parsed
                ActiveTowerLevels[tId] = bestLvl
            end
        end
    end)

    return bestLvl
end

local function updateMacroTimelineUI()
    pcall(function()
        local actions = (#recData.actions > 0 and recData.actions) or (S.macro and S.macro.actions) or {}
        if StatusLabels.MacroSummary then
            setLabel(StatusLabels.MacroSummary, string.format(
                "Profile: %s | Actions: %d | Step: %d/%d (%s)",
                tostring(S.macroName),
                #actions,
                S.currentStepIndex,
                S.totalSteps,
                tostring(S.currentStepText)
            ))
        end
        if StatusLabels.Timeline then
            if #actions == 0 then
                setLabel(StatusLabels.Timeline, "No actions recorded or loaded.")
                return
            end
            local lines = {}
            local startIdx = math.max(1, (S.replaying and S.currentStepIndex > 10) and (S.currentStepIndex - 5) or 1)
            local endIdx = math.min(#actions, startIdx + 19)
            for i = startIdx, endIdx do
                local a = actions[i]
                local prefix = (S.replaying and S.currentStepIndex == i) and "▶ " or "  "
                local desc = ""
                if a.type == "place" then
                    desc = string.format("[%d] PLACE #%d: %s ($%d)", i, a.placementIndex or i, tostring(a.towerName), getTowerPlacementCost(a.towerName, a.cost))
                elseif a.type == "upgrade" then
                    desc = string.format("[%d] UPG #%d (%s) -> Lvl %d ($%d)", i, a.placementIndex or 0, tostring(a.towerName or "Unit"), a.targetLevel or 2, getTowerUpgradeCost(a.towerName or "", a.targetLevel or 2, a.cost))
                elseif a.type == "sell" then
                    desc = string.format("[%d] SELL Unit #%d", i, a.placementIndex or 0)
                elseif a.type == "target" then
                    desc = string.format("[%d] TARGET #%d -> %s", i, a.placementIndex or 0, tostring(a.targetMode))
                end
                table.insert(lines, prefix .. desc)
            end
            if #actions > endIdx then
                table.insert(lines, string.format("  ... (+%d more steps)", #actions - endIdx))
            end
            setLabel(StatusLabels.Timeline, table.concat(lines, "\n"))
        end
    end)
end

local function syncMacroFromRec(name)
    S.macro = { name = name, date = os.date(), actions = table.clone(recData.actions) }
    updateMacroTimelineUI()
end

-- Helper that safely updates MacroFileSelect with suppressDropdownCallback = true/false
local function autoFlushRecordingToDisk()
    if not S.recording or #recData.actions == 0 then return end
    local profName = cleanStr((Options and Options.MacroNameInput and Options.MacroNameInput.Value) or S.macroName or "Farm")
    if profName == "" then profName = "Farm" end
    S.macroName = profName
    S.macro = { name = profName, date = os.date(), actions = table.clone(recData.actions) }
    if S.autoSaveRec then
        saveS()
        saveJSON(MACRO_FOLDER .. "/" .. profName .. ".json", S.macro)
        if Options and Options.MacroFileSelect then
            suppressDropdownCallback = true
            pcall(function()
                local list = listMacroFiles()
                Options.MacroFileSelect:SetValues(list)
                Options.MacroFileSelect:SetValue(profName)
            end)
            suppressDropdownCallback = false
        end
    end
end

local function saveCurrentMacro(name)
    name = cleanStr(name or (Options and Options.MacroNameInput and Options.MacroNameInput.Value) or S.macroName or "Farm")
    if name == "" then name = "Farm" end
    local actionsToSave = (#recData.actions > 0 and recData.actions) or (S.macro and S.macro.actions) or {}
    if #actionsToSave == 0 then
        addLog("Cannot save an empty macro (0 actions).", true)
        notify("Macro Save", "Cannot save an empty macro (0 actions)!", 3)
        return false
    end
    S.macroName = name
    saveS()
    local payload = { name = name, date = os.date(), actions = table.clone(actionsToSave) }
    S.macro = payload
    recData.actions = table.clone(actionsToSave)
    local ok = saveJSON(MACRO_FOLDER .. "/" .. name .. ".json", payload)
    updateMacroTimelineUI()
    if Options and Options.MacroFileSelect then
        suppressDropdownCallback = true
        pcall(function()
            Options.MacroFileSelect:SetValues(listMacroFiles())
            Options.MacroFileSelect:SetValue(name)
        end)
        suppressDropdownCallback = false
    end
    if ok then
        addLog(string.format("Saved '%s' (%d actions)", name, #actionsToSave))
        notify("Macro Saved", string.format("Saved '%s' (%d actions)", name, #actionsToSave), 3)
    end
    return ok
end

local function loadMacroByName(name)
    name = cleanStr(name or S.macroName or "Farm")
    if name == "" then return false end
    local d = loadJSON(MACRO_FOLDER .. "/" .. name .. ".json")
    if d and type(d.actions) == "table" then
        S.macro = d
        recData.actions = table.clone(d.actions)
        S.macroName = name
        saveS()
        if Options then
            if Options.MacroNameInput then
                pcall(function()
                    if cleanStr(Options.MacroNameInput.Value) ~= name then
                        Options.MacroNameInput:SetValue(name)
                    end
                end)
            end
            if Options.MacroFileSelect then
                suppressDropdownCallback = true
                pcall(function()
                    Options.MacroFileSelect:SetValues(listMacroFiles())
                    Options.MacroFileSelect:SetValue(name)
                end)
                suppressDropdownCallback = false
            end
        end
        updateMacroTimelineUI()
        addLog(string.format("Loaded macro '%s' (%d actions)", name, #d.actions))
        return true
    end
    return false
end

ENV.__CAM_TD_HOOK_CB = function(payload)
    if not S.recording then return end
    if type(payload) == "table" and payload.Name then
        pendingUnitIds[tostring(payload.Name)] = payload.UnitId and tostring(payload.UnitId) or resolveUnitIdForTower(tostring(payload.Name))
        local now = tick()
        local pos = payload.Pos or (payload.CFrame and payload.CFrame.Position)
        if pos then
            if (now - lastPlaceTime < 0.35) and (getDistanceXZ(lastPlacePos, pos) < 1.0) then return end
            lastPlaceTime = now
            lastPlacePos = pos
        end
    end
end

if not ENV.__CAM_TD_NAMECALL_HOOKED and hookmetamethod and getnamecallmethod then
    ENV.__CAM_TD_NAMECALL_HOOKED = true
    pcall(function()
        local wrapClosure = newcclosure or function(f) return f end
        local isCaller = checkcaller or function() return false end
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", wrapClosure(function(self, ...)
            local method = getnamecallmethod()
            if not isCaller() and typeof(self) == "Instance" and (method == "FireServer" or method == "fireServer") then
                if self.Name == "TowerAdd" and ENV.__CAM_TD_HOOK_CB then
                    local args = { ... }
                    task.spawn(function() pcall(ENV.__CAM_TD_HOOK_CB, args[1]) end)
                end
            end
            return oldNamecall(self, ...)
        end))
    end)
end

local function bindMatchRemoteListeners()
    if Remotes.TowerAdd then
        trackConn(Remotes.TowerAdd.OnClientEvent:Connect(function(data)
            safeCall("TowerAddListener", function()
                local rawId = data and (data.Id or data.Index)
                if not rawId then return end
                local isMine = (data.OwnerUserId == LP.UserId) or (data.OwnerName == LP.Name)
                if not isMine or not data.Pos then return end

                local tId   = tostring(rawId)
                local tName = tostring(data.Name or "Tower")
                local pos   = data.Pos
                local rawCf = data.CFrame or CFrame.new(pos)
                local _, yawRad, _ = rawCf:ToOrientation()
                local cf    = CFrame.new(pos) * CFrame.Angles(0, yawRad, 0)

                if S.recording and not TowerIdToPlacementIndex[tId] then
                    local newIdx      = #recData.actions + 1
                    local savedUnitId = pendingUnitIds[tName] or resolveUnitIdForTower(tName, "1")
                    local liveCost    = (data.Stats and tonumber(data.Stats.Price)) or getTowerPlacementCost(tName)
                    TowerIdToPlacementIndex[tId] = newIdx
                    recordedTowerLevels[tId]     = 1
                    table.insert(recData.actions, {
                        type           = "place",
                        placementIndex = newIdx,
                        towerName      = tName,
                        unitId         = savedUnitId,
                        cost           = liveCost,
                        pos            = { pos.X, pos.Y, pos.Z },
                        cframe         = { cf:GetComponents() }
                    })
                    autoFlushRecordingToDisk()
                    updateMacroTimelineUI()
                    addLog(string.format("[REC #%d] Place %s ($%d)", newIdx, tName, liveCost))
                end

                if S.replaying then
                    ActiveTowerLevels[tId] = 1
                    if S.macro and S.macro.actions and not UsedTowerIds[tId] then
                        for _, act in ipairs(S.macro.actions) do
                            if act.type == "place" and act.pos and not ReplayTowers[act.placementIndex] then
                                local actPos = Vector3.new(act.pos[1], act.pos[2], act.pos[3])
                                if getDistanceXZ(actPos, pos) < 2.8 then
                                    ReplayTowers[act.placementIndex] = tId
                                    UsedTowerIds[tId] = act.placementIndex
                                    break
                                end
                            end
                        end
                    end
                end
            end)
        end))
    end

    if Remotes.TowerUpgrade then
        trackConn(Remotes.TowerUpgrade.OnClientEvent:Connect(function(data)
            safeCall("TowerUpgradeListener", function()
                local rawId = data and (data.Id or data.Index)
                if not rawId then return end
                local tId = tostring(rawId)
                local lvl = tonumber(data.Level)
                if S.replaying and lvl then ActiveTowerLevels[tId] = lvl end

                if S.recording then
                    local pIdx = TowerIdToPlacementIndex[tId]
                    if not pIdx then return end
                    local newLvl  = lvl or ((recordedTowerLevels[tId] or 1) + 1)
                    local lastLvl = recordedTowerLevels[tId] or 1
                    if newLvl > lastLvl then
                        local towerName = "Unknown"
                        for _, act in ipairs(recData.actions) do
                            if act.type == "place" and act.placementIndex == pIdx then
                                towerName = act.towerName
                                break
                            end
                        end
                        for stepLvl = lastLvl + 1, newLvl do
                            local upgCost = getTowerUpgradeCost(towerName, stepLvl)
                            table.insert(recData.actions, {
                                type           = "upgrade",
                                placementIndex = pIdx,
                                towerName      = towerName,
                                targetLevel    = stepLvl,
                                cost           = upgCost,
                                towerId        = tId
                            })
                            addLog(string.format("[REC] Upgraded #%d (%s) -> Lvl %d ($%d)", pIdx, towerName, stepLvl, upgCost))
                        end
                        recordedTowerLevels[tId] = newLvl
                        autoFlushRecordingToDisk()
                        updateMacroTimelineUI()
                    end
                end
            end)
        end))
    end

    local removeEvent = Remotes.TowerRemove or Remotes.TowerSell
    if removeEvent then
        trackConn(removeEvent.OnClientEvent:Connect(function(data)
            safeCall("TowerRemoveListener", function()
                if not S.recording then return end
                local tId = data and (data.Id and tostring(data.Id) or (data.Index and tostring(data.Index)))
                if not tId then return end
                local pIdx = TowerIdToPlacementIndex[tId]
                if pIdx and not recordedSoldTowers[tId] then
                    recordedSoldTowers[tId] = true
                    table.insert(recData.actions, { type = "sell", placementIndex = pIdx, towerId = tId })
                    autoFlushRecordingToDisk()
                    updateMacroTimelineUI()
                    addLog(string.format("[REC] Sold Unit #%d", pIdx))
                end
            end)
        end))
    end

    if Remotes.TowerTarget then
        trackConn(Remotes.TowerTarget.OnClientEvent:Connect(function(data)
            safeCall("TowerTargetListener", function()
                if not data or not (data.Id or data.Index) or not data.TargetMode then return end
                local tId     = tostring(data.Id or data.Index)
                local newMode = tostring(data.TargetMode)
                ActiveTowerModes[tId] = newMode
                if S.recording then
                    local pIdx = TowerIdToPlacementIndex[tId]
                    if pIdx and (recordedTowerModes[tId] ~= newMode) then
                        recordedTowerModes[tId] = newMode
                        table.insert(recData.actions, {
                            type           = "target",
                            placementIndex = pIdx,
                            targetMode     = newMode,
                            towerId        = tId
                        })
                        autoFlushRecordingToDisk()
                        updateMacroTimelineUI()
                        addLog(string.format("[REC] Target Mode #%d -> %s", pIdx, newMode))
                    end
                end
            end)
        end))
    end
end

local function findPlacedTowerModelByPos(targetPos, maxDist, excludeUsed)
    if not towersFolder then
        gameFolder = workspace:FindFirstChild("Game")
        towersFolder = gameFolder and gameFolder:FindFirstChild("Towers")
    end
    if not towersFolder then return nil end
    local threshold = maxDist or 2.8
    local closestModel, closestDist = nil, 999999
    for _, child in ipairs(towersFolder:GetChildren()) do
        if child:IsA("Model") and not child.Name:match("^CinemamanHeadModules_") then
            if not (excludeUsed and UsedTowerIds[child.Name]) then
                local dist = getDistanceXZ(child:GetPivot().Position, targetPos)
                if dist < closestDist then
                    closestDist = dist
                    closestModel = child
                end
            end
        end
    end
    return (closestDist <= threshold) and closestModel or nil
end

local function setMatchStatusText(txt)
    setLabel(StatusLabels.MatchStatus, txt)
end

local function awaitCashAndPause(cost, actionDesc)
    while Controller.Running and S.replaying and isMatchActive() do
        if S.skipCurrentStep then
            S.skipCurrentStep = false
            return "SKIP"
        end
        if S.paused then
            setMatchStatusText("⏸ Replay Paused (" .. actionDesc .. ")")
            task.wait(0.15)
            continue
        end
        if cost <= 0 or getCash() >= cost then
            return "OK"
        end
        setMatchStatusText(string.format("⏳ Need $%d/$%d (%s)", getCash(), cost, actionDesc))
        task.wait(0.15)
    end
    return "ABORT"
end

local function executeReplay(macroData)
    if S.replaying then return end
    if not macroData or not macroData.actions or #macroData.actions == 0 then
        addLog("Replay aborted: Macro has 0 actions.", true)
        return
    end

    if not isMatchActive() then
        addLog("Replay queued: Waiting for Wave 1...")
        setMatchStatusText("⏳ Awaiting Wave 1...")
        while not isMatchActive() and Controller.Running do
            task.wait(0.35)
        end
    end
    if not Controller.Running then return end

    table.clear(ReplayTowers)
    table.clear(UsedTowerIds)
    table.clear(ActiveTowerLevels)
    table.clear(ActiveTowerModes)
    S.replaying        = true
    S.paused           = false
    S.skipCurrentStep  = false
    S.macro            = macroData
    S.totalSteps       = #macroData.actions
    S.currentStepIndex = 0

    addLog(string.format("▶ REPLAY STARTED: %s (%d Steps)", macroData.name or S.macroName, #macroData.actions))

    for i, a in ipairs(macroData.actions) do
        if not S.replaying or not Controller.Running or not isMatchActive() then
            addLog("⏹ Replay Interrupted (Match Ended / Reset).")
            break
        end

        S.currentStepIndex = i
        local stepSummary = string.format("#%d %s", i, tostring(a.type):upper())
        if a.type == "place" then
            stepSummary = string.format("Place %s (#%d)", tostring(a.towerName), a.placementIndex or i)
        elseif a.type == "upgrade" then
            stepSummary = string.format("Upg #%d -> Lvl %d", a.placementIndex or 0, a.targetLevel or 2)
        elseif a.type == "sell" then
            stepSummary = string.format("Sell Unit #%d", a.placementIndex or 0)
        elseif a.type == "target" then
            stepSummary = string.format("Target #%d -> %s", a.placementIndex or 0, tostring(a.targetMode))
        end
        S.currentStepText = stepSummary
        updateMacroTimelineUI()
        setMatchStatusText(string.format("▶ [%d/%d] %s", i, #macroData.actions, stepSummary))

        safeCall("ReplayStep_" .. tostring(i), function()
            if a.type == "place" then
                local targetPos = Vector3.new(a.pos[1], a.pos[2], a.pos[3])
                local yawRad = 0
                if a.cframe and #a.cframe == 12 then
                    local okCf, parsedCf = pcall(function() return CFrame.new(table.unpack(a.cframe)) end)
                    if okCf and parsedCf then
                        local _, y, _ = parsedCf:ToOrientation()
                        yawRad = y
                    end
                end
                local cf = CFrame.new(targetPos) * CFrame.Angles(0, yawRad, 0)

                local existing = findPlacedTowerModelByPos(targetPos, 1.8, true)
                if existing then
                    ReplayTowers[a.placementIndex]   = existing.Name
                    UsedTowerIds[existing.Name]      = a.placementIndex
                    ActiveTowerLevels[existing.Name] = getLiveTowerLevel(existing.Name)
                    return
                end

                local cost   = getTowerPlacementCost(a.towerName, a.cost)
                local status = awaitCashAndPause(cost, "Place " .. a.towerName)
                if status == "ABORT" then S.replaying = false return end
                if status == "SKIP" then return end

                local unitId = resolveUnitIdForTower(a.towerName, a.unitId)
                local placed, attempts = false, 0

                while not placed and attempts < 10 and S.replaying and isMatchActive() and Controller.Running do
                    if S.skipCurrentStep then S.skipCurrentStep = false break end
                    if Remotes.TowerAdd then
                        pcall(function()
                            Remotes.TowerAdd:FireServer({ Name = a.towerName, UnitId = unitId, Pos = targetPos, CFrame = cf })
                        end)
                    end
                    local startWait = tick()
                    while tick() - startWait < 1.4 and S.replaying and isMatchActive() do
                        if ReplayTowers[a.placementIndex] then placed = true break end
                        local found = findPlacedTowerModelByPos(targetPos, 2.8, true)
                        if found then
                            ReplayTowers[a.placementIndex] = found.Name
                            UsedTowerIds[found.Name]       = a.placementIndex
                            ActiveTowerLevels[found.Name]  = getLiveTowerLevel(found.Name)
                            placed = true
                            break
                        end
                        task.wait(0.05)
                    end
                    attempts += 1
                end
                if placed then
                    addLog(string.format("Placed: %s (#%d)", a.towerName, a.placementIndex))
                else
                    addLog(string.format("Place Failed: %s (#%d)", a.towerName, a.placementIndex), true)
                end
                task.wait(0.1)

            elseif a.type == "upgrade" then
                local tId = ReplayTowers[a.placementIndex]
                if not towersFolder then
                    gameFolder = workspace:FindFirstChild("Game")
                    towersFolder = gameFolder and gameFolder:FindFirstChild("Towers")
                end
                local model = tId and towersFolder and towersFolder:FindFirstChild(tId)
                if not model then
                    for _, prevAct in ipairs(macroData.actions) do
                        if prevAct.type == "place" and prevAct.placementIndex == a.placementIndex and prevAct.pos then
                            model = findPlacedTowerModelByPos(Vector3.new(prevAct.pos[1], prevAct.pos[2], prevAct.pos[3]), 2.8, false)
                            if model then
                                tId = model.Name
                                ReplayTowers[a.placementIndex] = tId
                                UsedTowerIds[tId]              = a.placementIndex
                                break
                            end
                        end
                    end
                end

                if model and tId and Remotes.TowerUpgrade then
                    local towerName = a.towerName
                    if not towerName or towerName == "" or towerName == "Unknown" then
                        for _, prevAct in ipairs(macroData.actions) do
                            if prevAct.type == "place" and prevAct.placementIndex == a.placementIndex then
                                towerName = prevAct.towerName
                                break
                            end
                        end
                    end
                    towerName = towerName or "Scientist Cameraman"
                    local currentLvl = getLiveTowerLevel(tId)
                    local targetLvl  = a.targetLevel or (currentLvl + 1)
                    if currentLvl >= targetLvl then return end

                    local cost = getTowerUpgradeCost(towerName, targetLvl, a.cost)

                    -- Persistent upgrade loop so Godly $27,000 upgrade never times out after 6 attempts!
                    local upgraded = false
                    while not upgraded and S.replaying and isMatchActive() and Controller.Running do
                        if S.skipCurrentStep then S.skipCurrentStep = false break end
                        if not (towersFolder and towersFolder:FindFirstChild(tId)) then break end
                        if getLiveTowerLevel(tId) >= targetLvl then upgraded = true break end

                        local status = awaitCashAndPause(cost, string.format("Upg #%d -> Lvl %d", a.placementIndex, targetLvl))
                        if status == "ABORT" then S.replaying = false return end
                        if status == "SKIP" then return end

                        pcall(function() Remotes.TowerUpgrade:FireServer({ Id = tId }) end)
                        local waitStart = tick()
                        while tick() - waitStart < 1.8 and S.replaying and isMatchActive() do
                            if getLiveTowerLevel(tId) >= targetLvl then upgraded = true break end
                            task.wait(0.05)
                        end
                        if not upgraded and getCash() < (cost - 10) then
                            local graceStart = tick()
                            while tick() - graceStart < 2.0 and S.replaying and isMatchActive() do
                                if getLiveTowerLevel(tId) >= targetLvl then upgraded = true break end
                                task.wait(0.1)
                            end
                        end
                    end
                    if upgraded then
                        ActiveTowerLevels[tId] = targetLvl
                        addLog(string.format("Upgraded: #%d (%s) -> Lvl %d", a.placementIndex, towerName, targetLvl))
                    end
                end
                task.wait(0.1)

            elseif a.type == "sell" then
                local status = awaitCashAndPause(0, "Sell #" .. tostring(a.placementIndex))
                if status == "ABORT" then S.replaying = false return end
                if status ~= "SKIP" then
                    local tId = ReplayTowers[a.placementIndex]
                    if tId and Remotes.TowerSell then
                        pcall(function() Remotes.TowerSell:FireServer({ Id = tId }) end)
                        ReplayTowers[a.placementIndex] = nil
                        UsedTowerIds[tId]              = nil
                        ActiveTowerLevels[tId]         = nil
                        addLog(string.format("Sold Unit #%d", a.placementIndex))
                    end
                end
                task.wait(0.1)

            elseif a.type == "target" then
                local status = awaitCashAndPause(0, "Target #" .. tostring(a.placementIndex))
                if status == "ABORT" then S.replaying = false return end
                if status ~= "SKIP" then
                    local tId = ReplayTowers[a.placementIndex]
                    if tId and Remotes.TowerTarget then
                        pcall(function() Remotes.TowerTarget:FireServer({ Id = tId }) end)
                        addLog(string.format("Target Mode #%d -> %s", a.placementIndex, tostring(a.targetMode)))
                    end
                end
                task.wait(0.1)
            end
        end)
    end

    S.replaying        = false
    S.paused           = false
    S.currentStepIndex = 0
    S.currentStepText  = "Completed"
    updateMacroTimelineUI()
    addLog("🏁 Replay sequence finished.")
    setMatchStatusText(not isMatchActive() and "🏁 Match Ended" or "✅ Replay Complete")
end

-- ==================== 8. BUILD OBSIDIAN WINDOW & TABS ====================
local Window = Library:CreateWindow({
    Title                = "⚡ CAMERA TD // STUDIO v5.7",
    Footer               = "v5.7 Obsidian Edition | Match Studio",
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
    Macro    = Window:AddTab("Macro Studio", "clapperboard"),
    Match    = Window:AddTab("In-Game Auto", "zap"),
    PerfExec = Window:AddTab("Perf & Exec", "cpu"),
    Settings = Window:AddTab("Logs & UI", "settings")
}

-- ---------- TAB: MACRO STUDIO ----------
local MacroCtrlGroup     = Tabs.Macro:AddLeftGroupbox("Macro Controls", "film")
local MacroTimelineGroup = Tabs.Macro:AddRightGroupbox("Action Timeline", "list-ordered")

MacroCtrlGroup:AddInput("MacroNameInput", {
    Text             = "Macro Profile Name",
    Default          = S.macroName or "Farm",
    Numeric          = false,
    Finished         = false,
    ClearTextOnFocus = false,
    Placeholder      = "Enter profile name...",
    Callback = function(Value)
        local clean = cleanStr(Value)
        if clean ~= "" and clean ~= S.macroName then
            S.macroName = clean
            saveS()
            updateMacroTimelineUI()
        end
    end
})

local macroFilesList = listMacroFiles()
MacroCtrlGroup:AddDropdown("MacroFileSelect", {
    Values   = macroFilesList,
    Default  = table.find(macroFilesList, S.macroName) or 1,
    Multi    = false,
    Text     = "Saved Macro Files",
    Callback = function(Value)
        if suppressDropdownCallback or S.recording then return end
        local clean = cleanStr(Value)
        if clean ~= "" then
            S.macroName = clean
            loadMacroByName(clean)
        end
    end
})

MacroCtrlGroup:AddButton({
    Text = "💾 Save",
    Func = function()
        safeCall("SaveMacroBtn", function()
            saveCurrentMacro(Options.MacroNameInput and Options.MacroNameInput.Value or S.macroName)
        end)
    end
}):AddButton({
    Text = "📂 Load",
    Func = function()
        safeCall("LoadMacroBtn", function()
            local target = Options.MacroNameInput and Options.MacroNameInput.Value or S.macroName
            if loadMacroByName(target) then
                notify("Macro Loaded", "Loaded profile: " .. tostring(target), 3)
            else
                local dropTarget = Options.MacroFileSelect and cleanStr(Options.MacroFileSelect.Value)
                if dropTarget and dropTarget ~= "" and loadMacroByName(dropTarget) then
                    notify("Macro Loaded", "Loaded profile: " .. tostring(dropTarget), 3)
                else
                    notify("Macro Load Failed", "File not found: " .. tostring(target), 3)
                end
            end
        end)
    end
})

MacroCtrlGroup:AddButton({
    Text = "↻ Refresh",
    Func = function()
        safeCall("RefreshMacrosBtn", function()
            local list = listMacroFiles()
            suppressDropdownCallback = true
            pcall(function()
                Options.MacroFileSelect:SetValues(list)
                Options.MacroFileSelect:SetValue(S.macroName)
            end)
            suppressDropdownCallback = false
            notify("Macro Files", "Found " .. tostring(#list) .. " macro files.", 2)
        end)
    end
}):AddButton({
    Text    = "🗑 Delete",
    Tooltip = "Click to delete current macro JSON file",
    Func = function()
        safeCall("DeleteMacroBtn", function()
            local n = cleanStr(Options.MacroNameInput and Options.MacroNameInput.Value or S.macroName)
            local d = cleanStr(Options.MacroFileSelect and Options.MacroFileSelect.Value or "")
            local deletedName = nil
            if delfile and isfile then
                if n ~= "" and isfile(MACRO_FOLDER .. "/" .. n .. ".json") then
                    delfile(MACRO_FOLDER .. "/" .. n .. ".json")
                    deletedName = n
                elseif d ~= "" and isfile(MACRO_FOLDER .. "/" .. d .. ".json") then
                    delfile(MACRO_FOLDER .. "/" .. d .. ".json")
                    deletedName = d
                end
            end
            recData.actions = {}
            S.macro = nil
            local list = listMacroFiles()
            S.macroName = list[1] or "Farm"
            saveS()
            suppressDropdownCallback = true
            pcall(function()
                Options.MacroFileSelect:SetValues(list)
                Options.MacroFileSelect:SetValue(S.macroName)
            end)
            suppressDropdownCallback = false
            if Options.MacroNameInput then
                pcall(function() Options.MacroNameInput:SetValue(S.macroName) end)
            end
            loadMacroByName(S.macroName)
            updateMacroTimelineUI()
            if deletedName then
                addLog("Deleted macro file: " .. deletedName)
                notify("Deleted", "Deleted " .. deletedName .. ".json", 3)
            end
        end)
    end
})

MacroCtrlGroup:AddDivider()

MacroCtrlGroup:AddToggle("RecordMacroToggle", {
    Text    = "⏺ Record Macro",
    Default = false,
    Callback = function(Value)
        safeCall("RecordMacroToggle", function()
            if Value then
                if S.replaying then
                    S.replaying = false
                    if Toggles.ReplayMacroToggle then Toggles.ReplayMacroToggle:SetValue(false) end
                    task.wait(0.1)
                end
                table.clear(TowerIdToPlacementIndex)
                table.clear(recordedTowerLevels)
                table.clear(recordedSoldTowers)
                table.clear(recordedTowerModes)
                recData.actions = {}
                S.recording = true
                updateMacroTimelineUI()
                setMatchStatusText("⏺ RECORDING ACTIONS...")
                addLog("⏺ RECORDING STARTED")
            else
                if not S.recording then return end
                S.recording = false
                local profName = (Options.MacroNameInput and Options.MacroNameInput.Value ~= "" and Options.MacroNameInput.Value) or S.macroName
                syncMacroFromRec(profName)
                setMatchStatusText(string.format("⏹ Recorded %d Actions", #recData.actions))
                addLog(string.format("⏹ RECORDING STOPPED (%d Actions)", #recData.actions))
                if S.autoSaveRec and #recData.actions > 0 then
                    saveCurrentMacro(profName)
                end
            end
        end)
    end
})

MacroCtrlGroup:AddToggle("ReplayMacroToggle", {
    Text    = "▶ Replay Macro",
    Default = false,
    Callback = function(Value)
        safeCall("ReplayMacroToggle", function()
            if not Value then
                if S.replaying then
                    S.replaying = false
                    S.paused = false
                    addLog("⏹ Replay stopped by user.")
                end
                return
            end
            if S.recording then
                S.recording = false
                if Toggles.RecordMacroToggle then Toggles.RecordMacroToggle:SetValue(false) end
            end
            local d = S.macro
            local profName = (Options.MacroNameInput and Options.MacroNameInput.Value ~= "" and Options.MacroNameInput.Value) or S.macroName
            if not d or not d.actions or #d.actions == 0 then
                if #recData.actions > 0 then
                    syncMacroFromRec(profName)
                    d = S.macro
                else
                    loadMacroByName(profName)
                    d = S.macro
                end
            end
            if not d or not d.actions or #d.actions == 0 then
                addLog("No macro actions loaded to replay!", true)
                notify("Replay Error", "No macro actions loaded!", 3)
                Toggles.ReplayMacroToggle:SetValue(false)
                return
            end
            task.spawn(function()
                executeReplay(d)
                if Toggles.ReplayMacroToggle and Toggles.ReplayMacroToggle.Value then
                    pcall(function() Toggles.ReplayMacroToggle:SetValue(false) end)
                end
            end)
        end)
    end
})

MacroCtrlGroup:AddToggle("AutoSaveRecToggle", {
    Text    = "Auto-Save Recording",
    Default = S.autoSaveRec,
    Callback = function(Value)
        S.autoSaveRec = Value
        saveS()
    end
})

MacroCtrlGroup:AddButton({
    Text = "⏸ Pause/Resume",
    Func = function()
        if S.replaying then
            S.paused = not S.paused
            addLog(S.paused and "⏸ Replay Paused" or "▶ Replay Resumed")
        end
    end
}):AddButton({
    Text = "⏭ Skip Step",
    Func = function()
        if S.replaying then
            S.skipCurrentStep = true
            addLog("⏭ Skipping current macro step...")
        end
    end
})

MacroCtrlGroup:AddButton({
    Text = "↩ Undo Action",
    Func = function()
        local targetList = (#recData.actions > 0 and recData.actions) or (S.macro and S.macro.actions)
        if targetList and #targetList > 0 then
            table.remove(targetList)
            syncMacroFromRec(S.macroName)
            if S.recording then autoFlushRecordingToDisk() end
            addLog("↩ Removed last action from macro.")
        end
    end
}):AddButton({
    Text        = "🧹 Clear All",
    DoubleClick = true,
    Func = function()
        recData.actions = {}
        if S.macro then S.macro.actions = {} end
        updateMacroTimelineUI()
        addLog("🧹 Cleared all macro actions in memory.")
    end
})

StatusLabels.MatchStatus  = MacroTimelineGroup:AddLabel("Match State: Waiting...", true)
StatusLabels.Telemetry    = MacroTimelineGroup:AddLabel("Wave: 0 | Cash: $0 | Units: 0/15 | Base: 1000/1000", true)
StatusLabels.MacroSummary = MacroTimelineGroup:AddLabel("Profile: None | Actions: 0 | Step: 0/0", true)
MacroTimelineGroup:AddDivider()
StatusLabels.Timeline     = MacroTimelineGroup:AddLabel("No actions recorded or loaded.", true)

-- ---------- TAB: IN-GAME AUTOMATION ----------
local WaveSkipGroup  = Tabs.Match:AddLeftGroupbox("Wave-Skip Filter", "fast-forward")
local MatchAutoGroup = Tabs.Match:AddRightGroupbox("Match Automation", "bot")

WaveSkipGroup:AddToggle("AutoSkipToggle", {
    Text    = "Auto Skip Wave",
    Default = S.autoSkip,
    Callback = function(Value)
        S.autoSkip = Value
        saveS()
    end
})

WaveSkipGroup:AddInput("NoSkipWavesInput", {
    Text             = "Stop Skip Waves (e.g. 5-15, 49+)",
    Default          = tostring(S.noSkipWaves or ""),
    Numeric          = false,
    Finished         = false,
    ClearTextOnFocus = false,
    Placeholder      = "Example: 5-15, 16, 17",
    Callback = function(Value)
        local cleaned = tostring(Value or ""):match("^%s*(.-)%s*$") or ""
        if cleaned ~= S.noSkipWaves then
            S.noSkipWaves = cleaned
            saveS()
        end
    end
})

WaveSkipGroup:AddToggle("SyncSkipMultiAccToggle", {
    Text    = "Sync No-Skip (Multi-Acc)",
    Default = S.syncSkipMultiAcc,
    Callback = function(Value)
        S.syncSkipMultiAcc = Value
        saveS()
    end
})

local speedRejectedInMatch = false
MatchAutoGroup:AddToggle("AutoSpeedToggle", {
    Text    = "Auto Game Speed",
    Default = S.autoSpeed,
    Callback = function(Value)
        S.autoSpeed = Value
        speedRejectedInMatch = false
        saveS()
    end
})

local speedMap        = { ["1x Speed"] = 1, ["1.5x Speed"] = 1.5, ["2x Speed"] = 2 }
local speedLabels     = { "1x Speed", "1.5x Speed", "2x Speed" }
local defaultSpeedIdx = (S.speedChoice == 1 and 1) or (S.speedChoice == 1.5 and 2) or 3

MatchAutoGroup:AddDropdown("SpeedChoiceDropdown", {
    Values   = speedLabels,
    Default  = defaultSpeedIdx,
    Multi    = false,
    Text     = "Target Game Speed",
    Callback = function(Value)
        local clean = cleanStr(Value)
        S.speedChoice = speedMap[clean] or 2
        speedRejectedInMatch = false
        saveS()
    end
})

MatchAutoGroup:AddDivider()

MatchAutoGroup:AddToggle("AutoVoteModeToggle", {
    Text    = "Auto Vote Gamemode",
    Default = S.autoVoteMode,
    Callback = function(Value)
        S.autoVoteMode = Value
        saveS()
    end
})

local gamemodes = { "Easy", "Normal", "Hard", "Insane", "Nightmare", "HalloweenEasy", "HalloweenHard" }
MatchAutoGroup:AddDropdown("VoteModeDropdown", {
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

MatchAutoGroup:AddDivider()

MatchAutoGroup:AddToggle("AutoReplayToggle", {
    Text    = "Auto Play Again",
    Default = S.autoReplay,
    Callback = function(Value)
        S.autoReplay = Value
        saveS()
    end
})

MatchAutoGroup:AddToggle("AutoPlayMacroToggle", {
    Text    = "Auto Macro On Wave 1",
    Default = S.autoPlay,
    Callback = function(Value)
        S.autoPlay = Value
        saveS()
    end
})

-- ---------- TAB: PERFORMANCE & AUTO-EXECUTE ----------
local ExecGroup = Tabs.PerfExec:AddLeftGroupbox("Teleport Auto-Execute", "rocket")
local PerfGroup = Tabs.PerfExec:AddRightGroupbox("FPS Cap & Anti-Lag", "gauge")

ExecGroup:AddToggle("AutoExecuteToggle", {
    Text    = "Auto Execute On Hop",
    Default = S.autoExecute,
    Callback = function(Value)
        S.autoExecute = Value
        saveS()
        if Value then
            armAutoExecute(true)
        end
    end
})

ExecGroup:AddSlider("StartupDelaySlider", {
    Text     = "Startup Load Delay",
    Default  = tonumber(S.startupDelay) or 7,
    Min      = 1,
    Max      = 60,
    Rounding = 0,
    Suffix   = "s",
    Tooltip  = "Wait time before executing script on join/teleport",
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

PerfGroup:AddButton({
    Text = "10 FPS",
    Func = function() Options.FpsCapSlider:SetValue(10) end
}):AddButton({
    Text = "15 FPS",
    Func = function() Options.FpsCapSlider:SetValue(15) end
})

PerfGroup:AddButton({
    Text = "30 FPS",
    Func = function() Options.FpsCapSlider:SetValue(30) end
}):AddButton({
    Text = "60 FPS",
    Func = function() Options.FpsCapSlider:SetValue(60) end
})

PerfGroup:AddDivider()

PerfGroup:AddToggle("DisableVFXToggle", {
    Text    = "Disable Attack VFX",
    Default = S.disableVFX,
    Callback = function(Value)
        S.disableVFX = Value
        saveS()
        applyVFXSetting(Value)
    end
})

-- ---------- TAB: LOGS & UI SETTINGS ----------
local LogGroup  = Tabs.Settings:AddLeftGroupbox("Live Console Log", "terminal")
local MenuGroup = Tabs.Settings:AddRightGroupbox("Menu Controls", "wrench")

LogGroup:AddButton({
    Text = "Clear Console Log",
    Func = function()
        table.clear(logEntries)
        setLabel(StatusLabels.Console, "Console cleared.")
    end
})
StatusLabels.Console = LogGroup:AddLabel("Initializing Camera TD Suite...", true)

MenuGroup:AddToggle("ShowCustomCursor", {
    Text    = "Custom Cursor",
    Default = false,
    Callback = function(Value)
        Library.ShowCustomCursor = Value
    end
})

MenuGroup:AddDropdown("DPIDropdown", {
    Values   = { "50%", "75%", "90%", "100%", "125%", "150%" },
    Default  = "100%",
    Text     = "UI Scale (DPI)",
    Callback = function(Value)
        local num = parseDigits(tostring(Value))
        if num then
            pcall(function() Library:SetDPIScale(num) end)
        end
    end
})

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

pcall(function()
    if ThemeManager and SaveManager then
        ThemeManager:SetLibrary(Library)
        SaveManager:SetLibrary(Library)
        SaveManager:IgnoreThemeSettings()
        SaveManager:SetIgnoreIndexes({ "MenuKeybind", "MacroNameInput", "MacroFileSelect" })
        ThemeManager:SetFolder(FOLDER)
        SaveManager:SetFolder(FOLDER .. "/obsidian_configs")
        SaveManager:BuildConfigSection(Tabs.Settings)
        ThemeManager:ApplyToTab(Tabs.Settings)
    end
end)

function Controller.Unload()
    if Controller.Unloaded then return end
    Controller.Unloaded  = true
    Controller.Running   = false
    _G.__CAM_TD_MACRO    = false
    if S.recording and #recData.actions > 0 then
        autoFlushRecordingToDisk()
    end
    S.recording          = false
    S.replaying          = false
    ENV.__CAM_TD_HOOK_CB = nil
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

-- ==================== 9. ENGINE LINKER & SUPERVISOR LOOP ====================
task.spawn(function()
    addLog("Initializing Camera TD Engine (v5.7 Obsidian)...")
    pcall(function() loadMacroByName(S.macroName) end)
    updateMacroTimelineUI()

    while Controller.Running do
        safeCall("EngineLinker", function()
            playerGui    = LP:FindFirstChildOfClass("PlayerGui")
            gameUI       = playerGui and playerGui:FindFirstChild("GameUI")
            gameFolder   = workspace:FindFirstChild("Game")
            towersFolder = gameFolder and gameFolder:FindFirstChild("Towers")

            if next(ConfigTowers) == nil then
                task.spawn(loadDynamicTowerConfigs)
            end

            if not MatchEngineReady then
                local ml  = RS:FindFirstChild("ModuleLoader")
                local sh  = ml and ml:FindFirstChild("Shared")
                local net = sh and sh:FindFirstChild("Network")
                local re  = net and net:FindFirstChild("RemoteEvent")
                local rf  = net and net:FindFirstChild("RemoteFunction")

                if re and rf then
                    Remotes.TowerAdd     = re:FindFirstChild("TowerAdd")
                    Remotes.TowerUpgrade = re:FindFirstChild("TowerUpgrade")
                    Remotes.TowerSell    = re:FindFirstChild("TowerSell")
                    Remotes.TowerTarget  = re:FindFirstChild("TowerTarget")
                    Remotes.TowerRemove  = re:FindFirstChild("TowerRemove")
                    Remotes.ModeVote     = re:FindFirstChild("ModeVote")
                    Remotes.WaveSkip     = re:FindFirstChild("WaveSkip")
                    Remotes.PlayAgain    = re:FindFirstChild("PlayAgain")
                    Remotes.ChangeSpeed  = rf:FindFirstChild("ChangeSpeed")

                    if Remotes.TowerAdd and Remotes.TowerUpgrade then
                        bindMatchRemoteListeners()
                        if S.disableVFX then applyVFXSetting(true) end
                        MatchEngineReady = true
                        addLog("✅ Match Remotes & Tower Configs Linked!")
                    end
                end
            end
        end)

        task.wait(1.5)
    end
end)

task.spawn(function()
    local lastBlockedWaveLog   = 0
    local lastPlayAgainAttempt = 0
    local lastSpeedAttemptTime = 0
    local speedFailCount       = 0

    while Controller.Running do
        safeCall("MatchSupervisor", function()
            local isOver    = isGameOver()
            local isVoting  = isVotingActive()
            local isPlaying = isMatchActive()
            local curWave   = tonumber(workspace:GetAttribute("Wave")) or 0

            if S.syncSkipMultiAcc and isfile and readfile then
                pcall(function()
                    if isfile(SHARED_SKIP_FILE) then
                        local diskVal = readfile(SHARED_SKIP_FILE)
                        if type(diskVal) == "string" and diskVal ~= S.noSkipWaves then
                            S.noSkipWaves = diskVal
                            if Options and Options.NoSkipWavesInput then
                                Options.NoSkipWavesInput:SetValue(diskVal)
                            end
                        end
                    end
                end)
            end

            if MatchEngineReady then
                -- 1. Smart Game Speed Enforcer
                local autoSpeedOn = (Toggles.AutoSpeedToggle and Toggles.AutoSpeedToggle.Value == true)
                if autoSpeedOn and isPlaying and Remotes.ChangeSpeed and not speedRejectedInMatch then
                    local curSpeed    = tonumber(workspace:GetAttribute("GameSpeed")) or 1
                    local targetSpeed = tonumber(S.speedChoice) or 2
                    if curSpeed ~= targetSpeed then
                        if tick() - lastSpeedAttemptTime >= 4.0 then
                            lastSpeedAttemptTime = tick()
                            pcall(function() Remotes.ChangeSpeed:InvokeServer(targetSpeed) end)
                            task.wait(0.3)
                            local afterSpeed = tonumber(workspace:GetAttribute("GameSpeed")) or 1
                            if afterSpeed ~= targetSpeed then
                                speedFailCount += 1
                                if speedFailCount >= 2 then
                                    if targetSpeed == 2 then
                                        pcall(function() Remotes.ChangeSpeed:InvokeServer(1.5) end)
                                    end
                                    speedRejectedInMatch = true
                                    addLog("Speed " .. tostring(targetSpeed) .. "x locked on this account; stopped speed requests.")
                                end
                            else
                                speedFailCount = 0
                            end
                        end
                    else
                        speedFailCount = 0
                    end
                end

                -- 2. Gamemode Auto-Vote
                local autoVoteOn = (Toggles.AutoVoteModeToggle and Toggles.AutoVoteModeToggle.Value == true)
                if autoVoteOn and isVoting and Remotes.ModeVote then
                    local modeClean = cleanStr((Options.VoteModeDropdown and Options.VoteModeDropdown.Value) or S.selectedMode)
                    local votersRaw = workspace:GetAttribute(modeClean .. "Voters")
                    local alreadyVoted = false
                    if votersRaw and votersRaw ~= "" then
                        local ok, voters = pcall(function() return HttpService:JSONDecode(votersRaw) end)
                        if ok and type(voters) == "table" and table.find(voters, LP.UserId) then
                            alreadyVoted = true
                        end
                    end
                    if not alreadyVoted then
                        pcall(function() Remotes.ModeVote:FireServer(modeClean) end)
                        addLog("🗳️ Voted Mode: " .. modeClean)
                    end
                end

                -- 3. Wave Skip Enforcer
                local autoSkipOn = (Toggles.AutoSkipToggle and Toggles.AutoSkipToggle.Value == true)
                if autoSkipOn and isPlaying and Remotes.WaveSkip then
                    if workspace:GetAttribute("CanSkip") == true then
                        if isWaveSkipBlocked(curWave, S.noSkipWaves) then
                            if lastBlockedWaveLog ~= curWave then
                                lastBlockedWaveLog = curWave
                                addLog(string.format("🛑 Auto-Skip paused on Wave %d (Filter: %s)", curWave, S.noSkipWaves))
                            end
                        else
                            pcall(function() Remotes.WaveSkip:FireServer() end)
                        end
                    end
                end

                -- 4. Verified Auto Play Again
                if isOver then
                    if S.recording and #recData.actions > 0 then
                        autoFlushRecordingToDisk()
                    end
                    speedRejectedInMatch = false
                    speedFailCount       = 0
                    if S.autoExecute and not S.teleportQueued then
                        armAutoExecute(false)
                    end
                    local autoReplayOn = (Toggles.AutoReplayToggle and Toggles.AutoReplayToggle.Value == true)
                    if autoReplayOn and Remotes.PlayAgain and not hasVotedPlayAgain() then
                        if tick() - lastPlayAgainAttempt >= 1.0 then
                            lastPlayAgainAttempt = tick()
                            pcall(function() Remotes.PlayAgain:FireServer() end)
                            addLog("⚡ [AutoReplay] Sent PlayAgain Vote!")
                        end
                    end
                end

                -- 5. Interruption Watchdog
                if not isPlaying and S.replaying then
                    S.replaying = false
                    S.paused    = false
                    table.clear(ReplayTowers)
                    table.clear(UsedTowerIds)
                    table.clear(ActiveTowerLevels)
                    updateMacroTimelineUI()
                    addLog("⏹ Replay Reset: Match transitioned to Voting/Lobby.")
                end

                -- 6. AutoPlay Trigger on Wave >= 1
                local autoPlayOn = (Toggles.AutoPlayMacroToggle and Toggles.AutoPlayMacroToggle.Value == true)
                if autoPlayOn and isPlaying and curWave >= 1 and not S.replaying and not S.recording and not S.macroPlayed then
                    S.macroPlayed = true
                    task.spawn(function()
                        task.wait(1.2)
                        if (Toggles.AutoPlayMacroToggle and Toggles.AutoPlayMacroToggle.Value) and isMatchActive() and not S.replaying and Controller.Running then
                            local d = S.macro
                            if not d or not d.actions or #d.actions == 0 then
                                loadMacroByName(S.macroName)
                                d = S.macro
                            end
                            if d and d.actions and #d.actions > 0 then
                                addLog("🤖 [AutoPlay] Starting Macro: " .. (d.name or S.macroName))
                                if Toggles.ReplayMacroToggle then
                                    pcall(function() Toggles.ReplayMacroToggle:SetValue(true) end)
                                else
                                    executeReplay(d)
                                end
                            end
                        end
                    end)
                end

                if not isPlaying or curWave == 0 then
                    S.macroPlayed = false
                end
            end

            local curCash   = getCash()
            local curPlaced = LP:FindFirstChild("PlacedTowers") and LP.PlacedTowers.Value or 0
            local basePart  = gameFolder and gameFolder:FindFirstChild("Base")
            local baseHp    = basePart and basePart:GetAttribute("Health") or 1000
            local baseMax   = basePart and basePart:GetAttribute("MaxHealth") or 1000
            local skipBlock = isWaveSkipBlocked(curWave, S.noSkipWaves)

            setLabel(StatusLabels.Telemetry, string.format(
                "Wave: %d%s | Cash: $%d | Units: %d/15 | Base: %d/%d",
                curWave,
                skipBlock and " [NO-SKIP]" or "",
                curCash,
                curPlaced,
                baseHp,
                baseMax
            ))

            if not S.replaying and not S.recording then
                if isOver then
                    setMatchStatusText(hasVotedPlayAgain() and "🏁 Play Again Voted! Waiting..." or "🏁 Match Concluded (Voting Play Again...)")
                elseif isVoting then
                    setMatchStatusText("🗳️ Voting Gamemode (" .. cleanStr(S.selectedMode) .. ")")
                elseif curWave == 0 then
                    setMatchStatusText("⏳ Intermission (Wave 0 Gate Active)")
                elseif isPlaying then
                    setMatchStatusText("🎮 Match Active | Cash: $" .. tostring(curCash))
                end
            end
        end)
        task.wait(0.35)
    end
end)

notify("Camera TD v5.7 Loaded", "In-Game Match Mode Active!", 4)
