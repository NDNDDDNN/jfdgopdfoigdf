-- Dungeon Lootr auto farm. Run this as a LocalScript/executor script while inside a dungeon.
-- Uses equipped Tool activation for attacks and normal number-key input for skills.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")
local LocalPlayer = Players.LocalPlayer
local env = (typeof(getgenv) == "function" and getgenv()) or _G

local function cleanupOldWindUI()
    local function clean(root)
        if not root then return end
        for _, child in next, root:GetChildren() do
            local name = child.Name:lower()
            -- This WindUI build parents a ScreenGui literally named "ScreenGui" to
            -- CoreGui; remove leftovers from previous runs.
            local isOurBareGui = name == "screengui" and child.Parent == game:GetService("CoreGui")
            if name:find("windui", 1, true) or name:find("dungeonlootr", 1, true) or name:find("zyronx", 1, true)
                or name == "delextoggle" or name == "chickchicktoggle" or isOurBareGui then
                pcall(function() child:Destroy() end)
            end
        end
    end
    clean(LocalPlayer:FindFirstChild("PlayerGui"))
    clean(game:GetService("CoreGui"))
end

cleanupOldWindUI()

-- Earlier runs leave motor connections behind (destroying the ScreenGui does
-- not disconnect them); a broken one retries its step every frame forever and
-- spams capability errors. Flipper motors are recognizable by their _onStep /
-- _onStart signal upvalues, so disable those before the new UI creates its own.
local function cleanupOldMotorConnections()
    if type(getconnections) ~= "function" then return end
    local ok, connections = pcall(getconnections, game:GetService("RunService").RenderStepped)
    if not ok or type(connections) ~= "table" then return end
    local getUps = (type(getupvalues) == "function" and getupvalues)
        or (type(debug) == "table" and type(debug.getupvalues) == "function" and debug.getupvalues)
        or nil
    for _, connection in next, connections do
        local func = connection.Function
        if type(func) == "function" then
            local isMotor = false
            if getUps then
                local okUps, upvalues = pcall(getUps, func)
                if okUps and type(upvalues) == "table" then
                    for _, value in next, upvalues do
                        if type(value) == "table" and type(value._onStep) == "table" and type(value._onStart) == "table" then
                            isMotor = true
                            break
                        end
                    end
                end
            end
            if isMotor then pcall(function() connection:Disable() end) end
        end
    end
end

cleanupOldMotorConnections()

-- UI
-- Use the shared CC UI module so Dungeon Lootr follows the same branding and
-- base tabs as the other scripts in this collection.
local Window = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/latavee1399-dev/AKO/refs/heads/main/CC%20ui"
))({
    Author = "Dungeon Lootr",
    TagTitle = "Izi",
})
assert(type(Window) == "table", "CC UI module returned an invalid Window")
local WindUI = Window.WindUI
assert(type(WindUI) == "table", "CC UI module did not expose WindUI")

-- CONFIG

-- Toggle, dropdown, and slider changes autosave to DungeonLootr/config.json
-- (debounced 1s) and reload on the next execute; saved values reapply through
-- the real UI handles so callbacks run exactly like a manual toggle.
-- Function families grouped into tables: function table fields do not
-- consume main-chunk local registers, keeping the file under the 200 limit.
local Config = { Registry = {}, SaveScheduled = false, Folder = "DungeonLootr", File = "DungeonLootr/config.json" }
local Gui = {}
local Data = {}
local Claims = { SessionClaimed = {} }
local Run = {}
local PF = {}
local Inv = {}
local Forge = {}
local Reroll = {}
local Srv = {}
local Chest = {}
local Tgt = {}
local Cbt = {}






function Config.configAvailable()
    return type(writefile) == "function" and type(readfile) == "function"
end

function Config.flushConfig()
    if not Config.configAvailable() then return end
    pcall(function()
        if type(isfolder) == "function" and not isfolder(Config.Folder) and type(makefolder) == "function" then
            makefolder(Config.Folder)
        end
        local payload = {}
        for key, entry in next, Config.Registry do
            payload[key] = entry.Current
        end
        writefile(Config.File, game:GetService("HttpService"):JSONEncode(payload))
    end)
end

function Config.SaveConfigValue(key, value)
    local entry = Config.Registry[key]
    if not entry then return end
    entry.Current = value
    if not Config.SaveScheduled then
        Config.SaveScheduled = true
        task.delay(1, function()
            Config.SaveScheduled = false
            Config.flushConfig()
        end)
    end
end

function Config.RegisterConfigValue(key, initialValue, applyValue)
    Config.Registry[key] = { Current = initialValue, Apply = applyValue }
end

function Config.LoadConfig()
    if not Config.configAvailable() then return 0 end
    local applied = 0
    pcall(function()
        if type(isfile) == "function" and not isfile(Config.File) then return end
        local data = game:GetService("HttpService"):JSONDecode(readfile(Config.File))
        if type(data) ~= "table" then return end
        for key, entry in next, Config.Registry do
            local saved = data[key]
            if saved ~= nil and type(entry.Apply) == "function" then
                pcall(entry.Apply, saved)
                entry.Current = saved
                applied += 1
            end
        end
    end)
    return applied
end

-- The shared CC UI is loaded above; Dungeon Lootr keeps its own state and
-- callbacks in this file while using the shared Window for rendering.

if type(env.__DungeonLootrStop) == "function" then pcall(env.__DungeonLootrStop) end

local State = {
    AutoFarm = false, AutoAttack = true, AutoSkills = true, AutoCollectChest = true,
    AutoParry = false, ParryDelay = 0.2, ParryRange = 16,
    Position = "Front", Distance = 8, VerticalOffset = 0, TargetRange = 250,
    AttackInterval = 0.18, SkillInterval = 1.2, ChestRange = 350,
    Noclip = false, WalkSpeedEnabled = false, WalkSpeed = 24,
    JumpPowerEnabled = false, JumpPower = 65, InfiniteJump = false,
    SelectedSkills = { ["1"] = true, ["2"] = false, ["3"] = false, ["4"] = false },
    AutoHeal = false, HealThreshold = 20,
    WaitRoomClear = true, RoomClearRange = 120,
}
local running, farmToken, attackToken, skillToken = true, 0, 0, 0
local characterConnection, StatusLabel, LobbyStatusLabel, ForgeStatusLabel, RerollStatusLabel, CraftStatusLabel, playerLoopThread, jumpConnection
local UIWindow
local autoStatsThread
local forgeThread
local rerollThread
local autoHealThread
local OriginalPlayerValues = {}
local NoclipOriginal = setmetatable({}, { __mode = "k" })
local LobbyState = {
    AutoCreate = false, AutoStart = false, AutoReplay = false, AutoLeave = false,
    AutoClaim = false, AutoBattlePassQuest = false, AutoBattlePassReward = false,
    AutoSell = false, AutoEquip = false, AntiAfk = false,
    BestUnlocked = false, SoloMode = false, SelectedDungeon = "Bandits Den", SelectedDifficulty = "Easy",
    DungeonConfigured = false, StartRequested = false,
    AutoSelectChest = false, BossChestPicks = { "2", "3" }, AutoChangeDungeon = false,
    AutoClaimLobby = false, AutoRedeemCodes = false, AutoClaimProgress = false,
    AutoPickBuff = false, BuffPickIndex = 1, PreferredBlessing = "",
}
-- Forge thresholds. MinSuccess is the raw success rate (%) an attempt must pass
-- (Purity Stones can bridge the gap from EnhanceFromLevel up), CoinReserve keeps
-- that many coins unspent, and protection scrolls are only burned once failures
-- can actually downgrade (level 11+).
local ForgeState = {
    AutoForge = false, TargetLevel = 15, MinSuccess = 30, CoinReserve = 0,
    AutoEnhance = true, EnhanceFromLevel = 10,
    AutoProtect = true, ProtectFromLevel = 15,
    AutoReforge = false, ReforgeQuality = "Standard", ReforgeCount = 3,
    SelectedItems = {},
}
-- Class reroll. Spins target the slot that is currently active, so the loop
-- switches to each chosen slot first and restores the original slot afterwards.
-- Slot unlocking goes through the coin PurchaseSlot remote only; the Robux
-- remote is never called.
local RerollState = {
    AutoReroll = false, SpinType = "Normal",
    SelectedSlots = { ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true },
    AutoUnlockSlot = false, UnlockAttempted = false,
    ReturnToOriginalSlot = true,
}
local DungeonOptions = { "Bandits Den", "Goblins", "Knights", "Catacombs", "Snow", "Demon", "Double Dungeon", "Throne Room" }
local DifficultyOptions = { "Easy", "Normal", "Hard", "Nightmare", "Endless" }
local DungeonRules = {
    ["Bandits Den"] = {
        { Name = "Easy", MinLevel = 1 },
        { Name = "Normal", MinLevel = 4 },
        { Name = "Hard", Requires = "Normal" },
        { Name = "Nightmare", MinLevel = 25 },
        { Name = "Endless", MinLevel = 10 },
    },
}
local ActionLabels = {
    Create = { "create dungeon", "create", "new dungeon" }, Start = { "start", "begin" },
    Leave = { "leave", "exit" }, Claim = { "claim", "collect", "reward" },
    Sell = { "sell", "sell all" }, Equip = { "equip", "loadout" },
}
local LobbyLoops = {}
local LobbyConnections = {}
local InteractingButtons = setmetatable({}, { __mode = "k" })
local BattlePassClaiming = {}
-- Timeout keeps places without the same structure (AFK chamber, dungeon)
-- from hanging forever before the UI builds.
local KnitOk, Knit = pcall(require, ReplicatedStorage:WaitForChild("Packages", 10):WaitForChild("Knit", 10))
local RegistryOk, Registry = pcall(require, LocalPlayer:WaitForChild("PlayerScripts", 10):WaitForChild("Client", 10):WaitForChild("Controllers", 10):WaitForChild("Registry", 10))

local lastStatus
local function setStatus(text)
    if text == lastStatus then return end
    lastStatus = text
    if not StatusLabel then return end
    if StatusLabel.SetDesc then pcall(StatusLabel.SetDesc, StatusLabel, tostring(text))
    elseif StatusLabel.SetText then pcall(StatusLabel.SetText, StatusLabel, tostring(text)) end
end

local lastLobbyStatus
local function setLobbyStatus(text)
    if text == lastLobbyStatus then return end
    lastLobbyStatus = text
    if LobbyStatusLabel then
        if LobbyStatusLabel.SetDesc then pcall(LobbyStatusLabel.SetDesc, LobbyStatusLabel, tostring(text))
        elseif LobbyStatusLabel.SetText then pcall(LobbyStatusLabel.SetText, LobbyStatusLabel, tostring(text)) end
    end
end

function Gui.walkChildren(root, callback)
    if not root or not root.GetChildren then return end
    for _, child in next, root:GetChildren() do
        callback(child)
        Gui.walkChildren(child, callback)
    end
end

function Gui.findGuiButton(keyword)
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return nil end
    local wanted = tostring(keyword or ""):lower()
    local found
    Gui.walkChildren(playerGui, function(instance)
        if found or not instance:IsA("GuiButton") then return end
        local text = tostring(instance.Name):lower()
        pcall(function() text = text .. " " .. tostring(instance.Text):lower() end)
        if wanted == "" or text:find(wanted, 1, true) then found = instance end
    end)
    return found
end

function Gui.getGuiText(instance)
    local text = tostring(instance and instance.Name or ""):lower()
    if instance and (instance:IsA("TextButton") or instance:IsA("TextLabel")) then
        text ..= " " .. tostring(instance.Text):lower()
    end
    if instance then
        for _, child in next, instance:GetChildren() do
            if child:IsA("TextLabel") or child:IsA("TextButton") then
                text ..= " " .. tostring(child.Name):lower() .. " " .. tostring(child.Text):lower()
            end
        end
    end
    return text
end

function Gui.getButtonContext(button)
    local text = Gui.getGuiText(button)
    local parent = button.Parent
    local depth = 0
    while parent and depth < 7 and not parent:IsA("ScreenGui") do
        text ..= " " .. Gui.getGuiText(parent)
        parent = parent.Parent
        depth += 1
    end
    return text
end

function Gui.isGuiActuallyVisible(instance)
    local current = instance
    while current and not current:IsA("ScreenGui") do
        if current:IsA("GuiObject") and not current.Visible then return false end
        current = current.Parent
    end
    return current and current.Enabled ~= false
end

function Gui.clickGuiButton(button)
    if not button or not button:IsA("GuiButton") or InteractingButtons[button] then return false end
    InteractingButtons[button] = true
    local clicked = false
    if type(getconnections) == "function" then
        for _, eventName in next, { "Activated", "MouseButton1Down", "MouseButton1Click", "MouseButton1Up" } do
            pcall(function()
                for _, connection in next, getconnections(button[eventName]) do
                    pcall(function()
                        if type(connection.Function) == "function" then
                            connection.Function()
                            clicked = true
                        end
                    end)
                end
            end)
            if clicked then break end
        end
    end
    if not clicked then
        local previousSelection = GuiService.SelectedObject
        local success = pcall(function()
            GuiService.SelectedObject = button
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
            GuiService.SelectedObject = previousSelection
        end)
        clicked = success
    end
    InteractingButtons[button] = nil
    return clicked
end

function Gui.getPlayerLevel()
    local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
    for _, container in next, { LocalPlayer, leaderstats } do
        if container then
            for _, child in next, container:GetChildren() do
                if child:IsA("IntValue") or child:IsA("NumberValue") then
                    if tostring(child.Name):lower():find("level", 1, true) then return child.Value end
                end
            end
        end
    end
    return 0
end

function Gui.hasCompletedRequirement(requirement)
    local playerData = LocalPlayer:FindFirstChild("Data") or LocalPlayer
    local marker = playerData and playerData:FindFirstChild(requirement)
    if marker and marker:IsA("BoolValue") then return marker.Value end
    return Gui.findGuiButton(requirement) ~= nil
end

function Gui.getBestDifficulty(dungeonName)
    local rules = DungeonRules[dungeonName]
    if not rules then return LobbyState.SelectedDifficulty end
    local level, best = Gui.getPlayerLevel(), nil
    for _, rule in next, rules do
        local allowed = (not rule.MinLevel or level >= rule.MinLevel)
        if rule.Requires then allowed = allowed and Gui.hasCompletedRequirement(rule.Requires) end
        if allowed then best = rule.Name end
    end
    return best or rules[1].Name
end

function Gui.clickLobbyButton(keyword)
    local button = Gui.findGuiButton(keyword)
    if not button then return false end
    return Gui.clickGuiButton(button)
end

function Data.getPlayerData()
    if not RegistryOk or not Registry then return nil end
    return Registry:Get("PlayerData")
end

function Data.getBattlePassData()
    local playerData = Data.getPlayerData()
    return playerData and playerData.Data and playerData.Data.Battlepass or nil
end

function Data.getKnitService(name)
    if not KnitOk or not Knit then return nil end
    local success, service = pcall(Knit.GetService, name)
    return success and service or nil
end

-- Calls a Knit service method that returns a Promise and unwraps both layers of
-- results: the Promise resolution flag and the server's own success flag.
-- Returns serverOk, serverMessage (or payload) so callers can react to rejections
-- such as "Stand on a pod to start" instead of treating them as successes.
local function callKnitAwait(service, methodName, ...)
    if not service or type(service[methodName]) ~= "function" then
        return false, "service method unavailable: " .. tostring(methodName)
    end
    local args = { ... }
    local callOk, promiseOk, serverOk, payload = pcall(function()
        return service[methodName](service, unpack(args)):await()
    end)
    if not callOk then return false, tostring(promiseOk) end
    if promiseOk ~= true then return false, tostring(serverOk or payload or promiseOk) end
    if serverOk == nil then return true, payload end
    if serverOk == true then return true, payload end
    return false, tostring(payload or serverOk)
end

-- callKnitAwait above only understands boolean server returns; the ForgeService
-- methods return data tables, so unwrap those here. Handles promise-wrapped
-- calls plus bare (true, data) / (true, true, data) server tuples.
local function callKnitData(service, methodName, ...)
    if not service or type(service[methodName]) ~= "function" then return nil, "method unavailable: " .. tostring(methodName) end
    local args = { ... }
    local results = { pcall(function()
        local promise = service[methodName](service, unpack(args))
        if type(promise) == "table" and type(promise.await) == "function" then
            return promise:await()
        end
        return promise
    end) }
    if results[1] ~= true then return nil, tostring(results[2]) end
    if results[2] == false then return nil, tostring(results[3] or "rejected") end
    if type(results[2]) == "table" then return results[2] end
    if results[2] == true then
        if type(results[3]) == "table" then return results[3] end
        if results[3] == true and type(results[4]) == "table" then return results[4] end
        return (results[3] ~= nil and results[3] or true)
    end
    return nil, "unexpected response"
end

function Claims.claimReadyBattlePassQuests()
    local battlePass = Data.getBattlePassData()
    local service = Data.getKnitService("BattlepassService")
    if not battlePass or not service then return 0 end
    local claimed = 0
    for index, quest in next, battlePass.Quests or {} do
        local key = "Quest:" .. tostring(index)
        if quest.Completed and not quest.Claimed and not BattlePassClaiming[key] then
            BattlePassClaiming[key] = true
            local ok, success = callKnitAwait(service, "ClaimQuest", index)
            BattlePassClaiming[key] = nil
            if ok and success then claimed += 1 end
            task.wait(0.15)
        end
    end
    return claimed
end

function Claims.claimReadyBattlePassRewards()
    local battlePass = Data.getBattlePassData()
    local service = Data.getKnitService("BattlepassService")
    if not battlePass or not service then return 0 end
    local claimed = 0
    local highestTier = battlePass.Tier or 0
    for tier = 1, highestTier do
        if not table.find(battlePass.ClaimedFree or {}, tier) then
            local key = "Free:" .. tier
            if not BattlePassClaiming[key] then
                BattlePassClaiming[key] = true
                local ok = callKnitAwait(service, "ClaimReward", tier, "Free")
                BattlePassClaiming[key] = nil
                if ok then claimed += 1 end
                task.wait(0.15)
            end
        end
        if battlePass.HasPremium and not table.find(battlePass.ClaimedPremium or {}, tier) then
            local key = "Premium:" .. tier
            if not BattlePassClaiming[key] then
                BattlePassClaiming[key] = true
                local ok = callKnitAwait(service, "ClaimReward", tier, "Premium")
                BattlePassClaiming[key] = nil
                if ok then claimed += 1 end
                task.wait(0.15)
            end
        end
    end
    return claimed
end

-- Free lobby rewards the game exposes over Knit: daily check-ins, shop free
-- chests, and the free Shadow Monarch pack. Each target is tried once per
-- session so the loop never hammers the server.

function Claims.claimLobbyRewards()
    local claimed = 0
    local checks = Data.getKnitService("CheckService")
    if checks then
        for i = 1, 10 do
            local key = "check:" .. i
            if not Claims.SessionClaimed[key] then
                Claims.SessionClaimed[key] = true
                local ok, success = callKnitAwait(checks, "ClaimCheck", i)
                if ok and success ~= false then claimed += 1 end
            end
        end
    end
    local chestService = Data.getKnitService("ChestService")
    if chestService then
        for i = 1, 5 do
            local key = "freechest:" .. i
            if not Claims.SessionClaimed[key] then
                Claims.SessionClaimed[key] = true
                local ok, success = callKnitAwait(chestService, "ClaimFreeChest", i)
                if ok and success ~= false then claimed += 1 end
            end
        end
    end
    if not Claims.SessionClaimed.shadowMonarch then
        Claims.SessionClaimed.shadowMonarch = true
        local monetization = Data.getKnitService("MonetizationService")
        if monetization then
            local ok, success = callKnitAwait(monetization, "ClaimShadowMonarchFree")
            if ok and success ~= false then claimed += 1 end
        end
    end
    return claimed
end

function Claims.startLobbyClaimsLoop()
    if LobbyLoops.LobbyClaims then return end
    LobbyLoops.LobbyClaims = task.spawn(function()
        while running and LobbyState.AutoClaimLobby do
            pcall(function()
                local claimed = Claims.claimLobbyRewards()
                if claimed > 0 then setLobbyStatus("Lobby rewards claimed: " .. claimed) end
            end)
            task.wait(10)
        end
        LobbyLoops.LobbyClaims = nil
    end)
end

function Claims.redeemAllCodes()
    local claimed = 0
    local codesService = Data.getKnitService("CodesService")
    local codesModule = ReplicatedStorage:FindFirstChild("GameInfo")
    codesModule = codesModule and codesModule:FindFirstChild("CodesData")
    local okData, codesData = pcall(require, codesModule)
    if not (codesService and okData and type(codesData) == "table" and codesData.Codes) then return 0 end
    for _, code in next, codesData.Codes do
        local key = "code:" .. tostring(code)
        if not Claims.SessionClaimed[key] then
            Claims.SessionClaimed[key] = true
            local ok, success = callKnitAwait(codesService, "RedeemCode", tostring(code))
            if ok and success ~= false then
                claimed += 1
                setLobbyStatus("Code redeemed: " .. tostring(code))
            end
            task.wait(0.3)
        end
    end
    return claimed
end

function Claims.claimPatchNotes()
    local claimed = 0
    local service = Data.getKnitService("PatchNotesService")
    local dataModule = ReplicatedStorage:FindFirstChild("GameInfo")
    dataModule = dataModule and dataModule:FindFirstChild("PatchNoteData")
    local okData, data = pcall(require, dataModule)
    if not (service and okData and type(data) == "table" and type(data.GetOrdered) == "function") then return 0 end
    local okOrdered, ordered = pcall(data.GetOrdered)
    if not okOrdered or type(ordered) ~= "table" then return 0 end
    for _, note in next, ordered do
        local id = note and note.Id
        if id and not Claims.SessionClaimed["patch:" .. tostring(id)] then
            Claims.SessionClaimed["patch:" .. tostring(id)] = true
            if type(data.HasRewards) ~= "function" or data.HasRewards(note) then
                local ok, success = callKnitAwait(service, "ClaimReward", id)
                if ok and success ~= false then
                    claimed += 1
                    setLobbyStatus("Patch reward claimed: " .. tostring(id))
                end
                task.wait(0.3)
            end
        end
    end
    return claimed
end

function Claims.claimQuests()
    -- The game keys active quests by numeric slot (Quests[cat].Active[slot])
    -- and its own UI claims with ClaimQuest(category, slotNumber): string ids
    -- are silently ignored, so claim by slot where Completed and unclaimed.
    local claimed = 0
    local service = Data.getKnitService("QuestService")
    local playerData = Data.getPlayerData()
    local quests = playerData and playerData.Data and playerData.Data.Quests
    if not (service and type(quests) == "table") then return 0 end
    for _, category in next, { "Daily", "Weekly" } do
        local active = quests[category] and quests[category].Active
        if type(active) == "table" then
            local slots = {}
            for slot in next, active do table.insert(slots, tonumber(slot) or 0) end
            table.sort(slots)
            for _, slot in next, slots do
                if not running then break end
                local quest = active[slot]
                if type(quest) == "table" and quest.Completed == true and quest.Claimed ~= true then
                    local key = "quest:" .. category .. ":" .. tostring(quest.QuestId)
                    if not Claims.SessionClaimed[key] then
                        local ok, success = callKnitAwait(service, "ClaimQuest", category, slot)
                        if ok and success ~= false then
                            Claims.SessionClaimed[key] = true
                            quest.Claimed = true
                            claimed += 1
                            setLobbyStatus("Quest claimed: " .. tostring(quest.QuestId))
                        end
                        task.wait(0.15)
                    end
                end
            end
        end
    end
    return claimed
end

function Claims.claimAchievements()
    local claimed = 0
    local service = Data.getKnitService("AchievementService")
    local dataModule = ReplicatedStorage:FindFirstChild("GameInfo")
    dataModule = dataModule and dataModule:FindFirstChild("AchievementData")
    local okData, data = pcall(require, dataModule)
    if not (service and okData and type(data) == "table" and data.AchievementById) then return 0 end
    for id in next, data.AchievementById do
        for tier = 1, 10 do
            local key = "ach:" .. tostring(id) .. ":" .. tier
            if not Claims.SessionClaimed[key] then
                local ok, success = callKnitAwait(service, "ClaimAchievement", id, tier)
                if ok and success ~= false then
                    Claims.SessionClaimed[key] = true
                    claimed += 1
                    setLobbyStatus("Achievement claimed: " .. tostring(id) .. " T" .. tier)
                end
                task.wait(0.1)
            end
        end
    end
    return claimed
end

function Claims.startProgressClaimsLoop()
    if LobbyLoops.ProgressClaims then return end
    LobbyLoops.ProgressClaims = task.spawn(function()
        while running and (LobbyState.AutoRedeemCodes or LobbyState.AutoClaimProgress) do
            local claimed = 0
            if LobbyState.AutoRedeemCodes then
                pcall(function() claimed += Claims.redeemAllCodes() end)
            end
            if LobbyState.AutoClaimProgress then
                pcall(function() claimed += Claims.claimPatchNotes() end)
                pcall(function() claimed += Claims.claimQuests() end)
                pcall(function() claimed += Claims.claimAchievements() end)
            end
            if claimed > 0 then setLobbyStatus("Progress claims: " .. claimed) end
            -- quests and achievement tiers become claimable as you play; retry
            -- every cycle (per-key memory prevents repeat claims)
            task.wait(30)
        end
        LobbyLoops.ProgressClaims = nil
    end)
end

-- Boss Rush / mid-run buff offers: the game fires DungeonBuffService.BuffSelection
-- with the option list; pick the user-chosen slot automatically.
-- The blessing pool (GameInfo.BuffData.Buffs) — titles the server can offer
-- on the "SELECT A BLESSING:" cards.
local BlessingNames = {
    "Overwhelming Force", "Fleetfoot", "Ironhide", "Bloodlust", "Scholar's Insight",
    "Fortune", "Arcane Might", "Deadeye", "Focused Casting", "Devastation",
    "Bulwark", "Steadfast", "Nimble", "Flowstate",
}

function Claims.handleBuffSelection(options)
    task.spawn(function()
        if not LobbyState.AutoPickBuff then return end
        if type(options) ~= "table" or #options == 0 then return end
        task.wait(1) -- let the card UI appear
        -- Prefer the configured blessing name when one is offered; otherwise
        -- fall back to the configured card position (First/Second/Third).
        local preferred = tostring(LobbyState.PreferredBlessing or "")
        local pickIndex
        if preferred ~= "" then
            for i, option in next, options do
                local title = tostring(type(option) == "table" and (option.Title or option.Name) or option)
                if title:lower():find(preferred:lower(), 1, true) then
                    pickIndex = i
                    break
                end
            end
        end
        if not pickIndex then
            pickIndex = math.clamp(LobbyState.BuffPickIndex, 1, #options)
        end
        local service = Data.getKnitService("DungeonBuffService")
        if not service then return end
        -- The server expects the CARD NUMBER — the game's own UI calls
        -- SelectBuff(cardIndex). Passing the option object failed silently.
        local ok, message = callKnitAwait(service, "SelectBuff", pickIndex)
        local chosen = options[pickIndex]
        local chosenName = (type(chosen) == "table" and chosen.Title) or ("option " .. pickIndex)
        if ok then
            setLobbyStatus("Blessing: " .. tostring(chosenName))
        else
            setLobbyStatus("Buff select failed: " .. tostring(message))
        end
    end)
end

function Claims.startBattlePassLoop()
    if LobbyLoops.BattlePass then return end
    LobbyLoops.BattlePass = task.spawn(function()
        while running and (LobbyState.AutoBattlePassQuest or LobbyState.AutoBattlePassReward) do
            pcall(function()
                local claimed = 0
                if LobbyState.AutoBattlePassQuest then
                    claimed += Claims.claimReadyBattlePassQuests()
                end
                if LobbyState.AutoBattlePassReward then
                    claimed += Claims.claimReadyBattlePassRewards()
                end
                if claimed > 0 then setStatus("Battle Pass claimed: " .. claimed) end
            end)
            task.wait(2)
        end
        LobbyLoops.BattlePass = nil
    end)
end

function Run.clickLobbyAction(action)
    for _, label in next, ActionLabels[action] or {} do
        if Gui.clickLobbyButton(label) then return true end
    end
    return false
end

function Run.isUnlockedButton(button)
    if not button or not button.Visible or not button.Active then return false end
    local text = tostring(button.Name):lower()
    pcall(function() text = text .. " " .. tostring(button.Text):lower() end)
    return not text:find("locked", 1, true) and not text:find("requires", 1, true)
end

function Run.prepareDungeonSelection()
    if LobbyState.BestUnlocked then
        LobbyState.SelectedDifficulty = Gui.getBestDifficulty(LobbyState.SelectedDungeon)
    end
    Gui.clickLobbyButton(LobbyState.SelectedDungeon)
    task.wait(0.15)
    Gui.clickLobbyButton(LobbyState.SelectedDifficulty)
end

function Run.createDungeon()
    local service = Data.getKnitService("DungeonQueueService")
    if not service then
        setLobbyStatus("DungeonQueueService is unavailable")
        return false
    end
    setLobbyStatus("Selecting Dungeon mode...")
    local modeOk, modeResult = callKnitAwait(service, "RequestSelectMode", "Dungeon")
    if not modeOk then
        setLobbyStatus("Select mode failed: " .. tostring(modeResult))
        return false
    end
    setLobbyStatus("Selecting " .. LobbyState.SelectedDungeon .. "...")
    local dungeonOk, dungeonResult = callKnitAwait(service, "RequestSelectDungeon", LobbyState.SelectedDungeon)
    if not dungeonOk then
        setLobbyStatus("Select dungeon failed: " .. tostring(dungeonResult))
        return false
    end
    setLobbyStatus("Selecting " .. LobbyState.SelectedDifficulty .. "...")
    local difficultyOk, difficultyResult = callKnitAwait(service, "RequestSelectDifficulty", LobbyState.SelectedDifficulty)
    if not difficultyOk then
        setLobbyStatus("Difficulty unavailable: " .. tostring(difficultyResult))
        return false
    end
    LobbyState.DungeonConfigured = true
    LobbyState.StartRequested = false
    local soloText = LobbyState.SoloMode and " [SOLO]" or ""
    setLobbyStatus("Ready: " .. LobbyState.SelectedDungeon .. " / " .. LobbyState.SelectedDifficulty .. soloText)
    return true
end

function Run.startDungeon()
    if LobbyState.StartRequested then return true end
    if not LobbyState.DungeonConfigured and not Run.createDungeon() then return false end
    local service = Data.getKnitService("DungeonQueueService")
    if not service then return false end
    setLobbyStatus(LobbyState.SoloMode and "Starting solo dungeon..." or "Joining dungeon queue...")
    local action = LobbyState.SoloMode and "RequestStartSoloRun" or "RequestStartPodQueue"
    local serverOk, serverMessage = callKnitAwait(service, action)
    if serverOk then
        LobbyState.StartRequested = true
        setLobbyStatus(LobbyState.SoloMode and "Solo dungeon starting..." or "Dungeon queue joined...")
        return true
    end
    setLobbyStatus("Start failed: " .. tostring(serverMessage))
    return false
end

function Run.requestReplay()
    local service = Data.getKnitService("DungeonRunService")
    if not service then return false end
    return pcall(function() service:RequestReplay() end)
end

function Run.requestReturn()
    local service = Data.getKnitService("DungeonRunService")
    if not service then return false end
    return pcall(function() service:RequestReturn() end)
end

-- The game announces run endings on DungeonRunService.DungeonComplete (the
-- HUD's ShowCompletion listens there; payload carries IsVictory) and phase
-- transitions on DungeonRunService.PhaseChange. Auto Replay / Auto Leave
-- consume RunStatus instead of blindly firing requests on a timer.
local RunStatus = { Completed = false, Handled = true, Victory = false, ChestSelecting = false, CompletedAt = 0 }

function Run.onRunCompleted(payload)
    RunStatus.Completed = true
    RunStatus.Handled = false
    RunStatus.CompletedAt = os.clock()
    RunStatus.Victory = (payload and payload.IsVictory) == true
    setLobbyStatus(RunStatus.Victory and "Dungeon complete!" or "Dungeon failed")
end

function Run.isChestSelectionActive()
    if not (KnitOk and Knit) then return false end
    local ok, controller = pcall(function() return Knit.GetController("ChestSelectionController") end)
    if ok and controller and type(controller.IsActive) == "function" then
        return controller:IsActive() == true
    end
    return false
end

-- The game fires DungeonRunService.ChestSelection after the final boss; pick the
-- preferred chests and confirm server-side without touching its UI.
function Run.handleChestSelection(candidates, extraLoot, source)
    task.spawn(function()
        if not LobbyState.AutoSelectChest then return end
        RunStatus.ChestSelecting = true
        task.wait(1.0) -- let the selection screen animate in
        local maxPicks = (extraLoot == true) and 3 or 2
        local count = 3
        if type(candidates) == "table" and #candidates > 0 then count = #candidates end
        local picks = {}
        local function addPick(index)
            if #picks >= maxPicks then return end
            index = tonumber(index)
            if index and index >= 1 and index <= count and not table.find(picks, index) then
                picks[#picks + 1] = index
            end
        end
        for _, pick in next, LobbyState.BossChestPicks do addPick(pick) end
        for index = 1, count do addPick(index) end -- fill any remaining picks
        if #picks < maxPicks then
            setLobbyStatus("Auto chest: only " .. #picks .. "/" .. maxPicks .. " picks available")
            RunStatus.ChestSelecting = false
            return
        end
        local service = Data.getKnitService(source == "BossRush" and "BossRushService" or "DungeonRunService")
        if not service then
            setLobbyStatus("Auto chest: service unavailable")
            RunStatus.ChestSelecting = false
            return
        end
        local method = source == "BossRush" and "SelectFloorChests"
            or (source == "MidRun" and "SelectMidRunChests" or "SelectChests")
        local ok, message = callKnitAwait(service, method, picks)
        RunStatus.ChestSelecting = false
        if ok then
            setLobbyStatus("Auto chest: selected " .. table.concat(picks, " + "))
        else
            setLobbyStatus("Auto chest failed: " .. tostring(message))
        end
    end)
end

function Run.connectRunEvents()
    if not KnitOk or not Knit then return end
    local function isSignal(value)
        return typeof(value) == "RBXScriptSignal"
            or (typeof(value) == "table" and type(value.Connect) == "function")
    end
    task.spawn(function()
        for _ = 1, 30 do
            local service = Data.getKnitService("DungeonRunService")
            if service and isSignal(service.DungeonComplete)
                and isSignal(service.PhaseChange) then
                if not LobbyConnections.RunComplete then
                    LobbyConnections.RunComplete = service.DungeonComplete:Connect(Run.onRunCompleted)
                end
                if not LobbyConnections.RunPhase then
                    LobbyConnections.RunPhase = service.PhaseChange:Connect(function(phase)
                        -- "Clear" fires when a dungeon (re)starts, so the next
                        -- completion can trigger Replay/Leave again.
                        if phase == "Clear" then
                            RunStatus.Completed = false
                            RunStatus.Handled = true
                            -- Knit signal objects can be recreated between
                            -- runs; drop stale connections and re-attach so
                            -- chest selection keeps working on later runs.
                            task.spawn(function()
                                for name, connection in next, LobbyConnections do
                                    pcall(function() connection:Disconnect() end)
                                    LobbyConnections[name] = nil
                                end
                                Run.connectRunEvents()
                            end)
                        end
                    end)
                end
                if isSignal(service.ChestSelection) and not LobbyConnections.ChestSelection then
                    LobbyConnections.ChestSelection = service.ChestSelection:Connect(function(candidates, extraLoot)
                        Run.handleChestSelection(candidates, extraLoot, "Dungeon")
                    end)
                end
                if isSignal(service.MidRunChestSelection) and not LobbyConnections.MidRunChestSelection then
                    LobbyConnections.MidRunChestSelection = service.MidRunChestSelection:Connect(function(candidates, extraLoot)
                        Run.handleChestSelection(candidates, extraLoot, "MidRun")
                    end)
                end
                local bossService = Data.getKnitService("BossRushService")
                if bossService and isSignal(bossService.ChestSelection) and not LobbyConnections.BossChestSelection then
                    LobbyConnections.BossChestSelection = bossService.ChestSelection:Connect(function(candidates, extraLoot)
                        Run.handleChestSelection(candidates, extraLoot, "BossRush")
                    end)
                end
                local buffService = Data.getKnitService("DungeonBuffService")
                if buffService and isSignal(buffService.BuffSelection) and not LobbyConnections.BuffSelection then
                    LobbyConnections.BuffSelection = buffService.BuffSelection:Connect(Claims.handleBuffSelection)
                end
                return
            end
            task.wait(1)
        end
        setLobbyStatus("DungeonRunService events unavailable; Auto Replay/Leave idle")
    end)
end

function Run.isDungeonActive()
    if LocalPlayer:GetAttribute("InNoCombatZone") == true then return false end
    if LocalPlayer:GetAttribute("CurrentDungeon") ~= nil
        or LocalPlayer:GetAttribute("CurrentDifficultyMode") ~= nil then return true end
    local dungeon = Workspace:FindFirstChild("Dungeon") or Workspace:FindFirstChild("dungeon")
    if dungeon then return true end
    for _, child in next, Workspace:GetChildren() do
        local name = child.Name:lower()
        -- The game spawns runs as "Generated_<DungeonName>_<id>" folders.
        if name:find("generated", 1, true) and name:find("den", 1, true) then return true end
        if name:find("generated", 1, true) and (name:find("dungeon", 1, true) or name:find("goblin", 1, true)
            or name:find("knight", 1, true) or name:find("catacomb", 1, true) or name:find("frostspire", 1, true)
            or name:find("underworld", 1, true) or name:find("mage", 1, true) or name:find("throne", 1, true)) then
            return true
        end
    end
    return false
end

-- Resets queue state once a run actually starts so Auto Create can prepare the
-- next selection after the current dungeon ends.
function Run.watchRunStart()
    task.spawn(function()
        while running do
            if LobbyState.StartRequested and Run.isDungeonActive() then
                LobbyState.StartRequested = false
                LobbyState.DungeonConfigured = false
                RunStatus.Completed = false
                RunStatus.Handled = true
                setLobbyStatus("Dungeon entered. Queue state reset.")
            end
            task.wait(1)
        end
    end)
end

local function startLobbyLoop(name, enabledKey, action, interval)
    if LobbyLoops[name] then return end
    LobbyLoops[name] = task.spawn(function()
        while running and LobbyState[enabledKey] do
            pcall(function()
                if action == "Create" then
                    if Run.isDungeonActive() then
                        -- A run is live; do not touch queue selection while inside it.
                        setLobbyStatus("Auto Create: in dungeon, idle")
                    elseif not LobbyState.DungeonConfigured then
                        Run.createDungeon()
                    else
                        setLobbyStatus("Auto Create: ready (" .. LobbyState.SelectedDungeon .. " / " .. LobbyState.SelectedDifficulty .. ")")
                    end
                elseif action == "Start" then
                    if not Run.isDungeonActive() then
                        if LobbyState.DungeonConfigured then
                            Run.startDungeon()
                        else
                            Run.createDungeon()
                        end
                    else
                        setLobbyStatus("Auto Start: dungeon running")
                    end
                elseif action == "Replay" then
                    if Run.isChestSelectionActive() or RunStatus.ChestSelecting then
                        setLobbyStatus("Auto Replay: waiting for chest selection")
                    elseif RunStatus.Completed and not RunStatus.Handled
                        and os.clock() - (RunStatus.CompletedAt or 0) >= 3 then
                        RunStatus.Handled = true
                        if LobbyState.AutoChangeDungeon then
                            local currentIndex = table.find(DungeonOptions, LobbyState.SelectedDungeon) or 1
                            local nextDungeon = DungeonOptions[currentIndex % #DungeonOptions + 1]
                            LobbyState.SelectedDungeon = nextDungeon
                            LobbyState.DungeonConfigured = false
                            setLobbyStatus("Auto Change: " .. nextDungeon .. " — returning to lobby...")
                            Run.requestReturn()
                        else
                            setLobbyStatus(RunStatus.Victory and "Replaying dungeon..." or "Retrying dungeon...")
                            Run.requestReplay()
                        end
                    elseif Run.isDungeonActive() then
                        setLobbyStatus("Auto Replay: run in progress")
                    end
                elseif action == "Leave" then
                    if Run.isChestSelectionActive() or RunStatus.ChestSelecting then
                        setLobbyStatus("Auto Leave: waiting for chest selection")
                    elseif RunStatus.Completed and not RunStatus.Handled
                        and os.clock() - (RunStatus.CompletedAt or 0) >= 3 then
                        RunStatus.Handled = true
                        setLobbyStatus("Returning to lobby...")
                        Run.requestReturn()
                    elseif Run.isDungeonActive() then
                        setLobbyStatus("Auto Leave: waiting for run to end")
                    end
                else
                    Run.clickLobbyAction(action)
                end
            end)
            task.wait(interval or 2)
        end
        LobbyLoops[name] = nil
    end)
end

local function stopLobbyLoops()
    for name, thread in next, LobbyLoops do
        pcall(function() task.cancel(thread) end)
        LobbyLoops[name] = nil
    end
    for name, connection in next, LobbyConnections do
        pcall(function() connection:Disconnect() end)
        LobbyConnections[name] = nil
    end
end

local function setupAntiAfk(enabled)
    LobbyState.AntiAfk = enabled == true
    if LobbyConnections.AntiAfk then LobbyConnections.AntiAfk:Disconnect(); LobbyConnections.AntiAfk = nil end
    if LobbyState.AntiAfk then
        LobbyConnections.AntiAfk = LocalPlayer.Idled:Connect(function()
            pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.zero) end)
        end)
    end
end

function PF.getCharacter()
    local character = LocalPlayer.Character
    if not character or not character.Parent then return nil end
    local humanoid, root = character:FindFirstChildOfClass("Humanoid"), character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or humanoid.Health <= 0 then return nil end
    return character, humanoid, root
end

function PF.rememberHumanoid(humanoid)
    if not humanoid or OriginalPlayerValues.Humanoid == humanoid then return end
    OriginalPlayerValues = {
        Humanoid = humanoid,
        WalkSpeed = humanoid.WalkSpeed,
        JumpPower = humanoid.JumpPower,
        UseJumpPower = humanoid.UseJumpPower,
    }
end

function PF.restoreNoclip()
    for part, canCollide in next, NoclipOriginal do
        if part and part.Parent then pcall(function() part.CanCollide = canCollide end) end
        NoclipOriginal[part] = nil
    end
end

function PF.applyPlayerModifiers()
    local character, humanoid = PF.getCharacter()
    if not character or not humanoid then return end
    PF.rememberHumanoid(humanoid)
    if State.WalkSpeedEnabled then humanoid.WalkSpeed = State.WalkSpeed end
    if State.JumpPowerEnabled then
        humanoid.UseJumpPower = true
        humanoid.JumpPower = State.JumpPower
    end
    if State.Noclip then
        for _, child in next, character:GetChildren() do
            if child:IsA("BasePart") then
                if NoclipOriginal[child] == nil then NoclipOriginal[child] = child.CanCollide end
                child.CanCollide = false
            end
        end
    end
end

function PF.restorePlayerModifiers()
    PF.restoreNoclip()
    local humanoid = OriginalPlayerValues.Humanoid
    if humanoid and humanoid.Parent then
        pcall(function()
            humanoid.WalkSpeed = OriginalPlayerValues.WalkSpeed
            humanoid.UseJumpPower = OriginalPlayerValues.UseJumpPower
            humanoid.JumpPower = OriginalPlayerValues.JumpPower
        end)
    end
    OriginalPlayerValues = {}
end

function PF.setWalkSpeedEnabled(enabled)
    State.WalkSpeedEnabled = enabled == true
    if not State.WalkSpeedEnabled then
        local humanoid = OriginalPlayerValues.Humanoid
        if humanoid and humanoid.Parent and OriginalPlayerValues.WalkSpeed then humanoid.WalkSpeed = OriginalPlayerValues.WalkSpeed end
    end
end

function PF.setJumpPowerEnabled(enabled)
    State.JumpPowerEnabled = enabled == true
    if not State.JumpPowerEnabled then
        local humanoid = OriginalPlayerValues.Humanoid
        if humanoid and humanoid.Parent then
            humanoid.UseJumpPower = OriginalPlayerValues.UseJumpPower
            humanoid.JumpPower = OriginalPlayerValues.JumpPower
        end
    end
end

function PF.setNoclip(enabled)
    State.Noclip = enabled == true
    if not State.Noclip then PF.restoreNoclip() end
end

function PF.setupInfiniteJump(enabled)
    State.InfiniteJump = enabled == true
    if jumpConnection then jumpConnection:Disconnect(); jumpConnection = nil end
    if State.InfiniteJump then
        jumpConnection = UserInputService.JumpRequest:Connect(function()
            local _, humanoid = PF.getCharacter()
            if humanoid then humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end
        end)
    end
end

function PF.startPlayerLoop()
    if playerLoopThread then return end
    playerLoopThread = task.spawn(function()
        while running and task.wait(0.1) do
            pcall(PF.applyPlayerModifiers)
        end
        playerLoopThread = nil
    end)
end

-- PLAYER EXTRAS

-- Fullbright: brightens Lighting while enabled; every changed property is
-- restored on unload or when toggled off.
local FullbrightOriginal = nil

local function setFullbright(enabled)
    local lighting = game:GetService("Lighting")
    if enabled then
        FullbrightOriginal = {
            Brightness = lighting.Brightness, ClockTime = lighting.ClockTime,
            FogEnd = lighting.FogEnd, GlobalShadows = lighting.GlobalShadows,
            OutdoorAmbient = lighting.OutdoorAmbient,
        }
        lighting.Brightness = 3
        lighting.ClockTime = 14
        lighting.FogEnd = 1e6
        lighting.GlobalShadows = false
    elseif FullbrightOriginal then
        for key, value in next, FullbrightOriginal do
            pcall(function() lighting[key] = value end)
        end
        FullbrightOriginal = nil
    end
end

-- Click TP: right-click anywhere to teleport to the aimed surface. The
-- connection is replaced each toggle and removed by stopAll.
local ClickTpConnection = nil

local function setClickTp(enabled)
    if ClickTpConnection then
        ClickTpConnection:Disconnect()
        ClickTpConnection = nil
    end
    if enabled then
        ClickTpConnection = UserInputService.InputBegan:Connect(function(input, processed)
            if processed or input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
            local _, _, root = PF.getCharacter()
            if not root then return end
            local camera = Workspace.CurrentCamera
            if not camera then return end
            local location = UserInputService:GetMouseLocation()
            local ray = camera:ViewportPointToRay(location.X, location.Y)
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { LocalPlayer.Character }
            local hit = Workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
            if hit then
                root.AssemblyLinearVelocity = Vector3.zero
                root.CFrame = CFrame.new(hit.Position + Vector3.new(0, 4, 0))
            end
        end)
    end
end

local function getRoot(model)
    if not model or not model:IsA("Model") then return nil end
    return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
        or model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
end

local CollectionService = game:GetService("CollectionService")

-- Port of the game's own IsValidEnemy (DungeonOnboardingPointer): dungeon mobs are
-- CollectionService-tagged "NPC" models; some classes (Rogue) have no Humanoid at all.
local function isValidTarget(model, ownCharacter)
    if not model or model == ownCharacter or not model:IsA("Model") or model:IsDescendantOf(ownCharacter) then return false end
    -- Special bosses are the run's final target: they must stay attackable or
    -- the dungeon can never be cleared. Mimic chests and loot-room guards are
    -- still off limits.
    if model:GetAttribute("IsLootRoomGuard") or model:GetAttribute("MimicMob") then return false end
    if Players:GetPlayerFromCharacter(model) then return false end
    local root = getRoot(model)
    if not root then return false end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health <= 0 then return false end
    -- Dungeon mobs carry the NPC tag (or a RoomIndex on generated layouts);
    -- dialogue NPCs, stray rigs and other players' characters never do.
    local tagged = CollectionService:HasTag(model, "NPC")
    return tagged or (humanoid ~= nil and model:GetAttribute("RoomIndex") ~= nil)
end

-- Mob cache: the tagged list misses boss wings and loot-room rigs entirely,
-- so candidates come from tagged models plus every living humanoid rig.
local CachedMobs, MobCacheAt = {}, 0
function Tgt.refreshMobCache(ownCharacter)
    if os.clock() - MobCacheAt <= 0.4 then return end
    MobCacheAt = os.clock()
    CachedMobs = {}
    local seen = {}
    for _, model in next, CollectionService:GetTagged("NPC") do
        if not seen[model] then seen[model] = true CachedMobs[#CachedMobs + 1] = model end
    end
    for _, d in next, Workspace:GetDescendants() do
        if d:IsA("Humanoid") and d.Health > 0 and d.Parent and not seen[d.Parent] then
            seen[d.Parent] = true
            if isValidTarget(d.Parent, ownCharacter) then CachedMobs[#CachedMobs + 1] = d.Parent end
        end
    end
end

function Tgt.findNearestTarget(origin, ownCharacter, inRangeOnly)
    Tgt.refreshMobCache(ownCharacter)
    local nearest, nearestDistance
    for _, model in next, CachedMobs do
        if isValidTarget(model, ownCharacter) then
            local root = getRoot(model)
            if root then
                local distance = (root.Position - origin).Magnitude
                if distance <= State.TargetRange and (not nearestDistance or distance < nearestDistance) then nearest, nearestDistance = model, distance end
            end
        end
    end
    -- Generated dungeon layouts vary; with nothing in range, go for the nearest
    -- valid target anywhere so far-away rooms still get farmed. The farm loop
    -- only uses this fallback after nearby chests are handled.
    if not nearest and not inRangeOnly then
        for _, model in next, CachedMobs do
            if isValidTarget(model, ownCharacter) then
                local root = getRoot(model)
                if root then
                    local distance = (root.Position - origin).Magnitude
                    if not nearestDistance or distance < nearestDistance then nearest, nearestDistance = model, distance end
                end
            end
        end
    end
    return nearest
end

function Tgt.targetCFrame(targetRoot)
    local offset
    if State.Position == "Above" then offset = Vector3.new(0, State.Distance, 0)
    elseif State.Position == "Below" then offset = Vector3.new(0, -State.Distance, 0)
    elseif State.Position == "Behind" then offset = -targetRoot.CFrame.LookVector * State.Distance
    else offset = targetRoot.CFrame.LookVector * State.Distance end
    local position = targetRoot.Position + offset + Vector3.new(0, State.VerticalOffset, 0)
    -- Always face the mob. Above/Below: face it on the horizontal plane only so
    -- the character stays upright (a full lookAt would flip it upside-down).
    if State.Position == "Above" or State.Position == "Below" then
        local flat = Vector3.new(targetRoot.Position.X - position.X, 0, targetRoot.Position.Z - position.Z)
        if flat.Magnitude < 0.5 then
            local character = LocalPlayer.Character
            local myRoot = character and getRoot(character)
            flat = myRoot and myRoot.CFrame.LookVector or Vector3.zAxis
            flat = Vector3.new(flat.X, 0, flat.Z)
            if flat.Magnitude < 0.05 then flat = Vector3.zAxis end
        end
        return CFrame.lookAt(position, position + flat.Unit)
    end
    return CFrame.lookAt(position, targetRoot.Position)
end

local ChestAttempts = setmetatable({}, { __mode = "k" })
local ChestAttemptCount = setmetatable({}, { __mode = "k" })
local OpenedChests = setmetatable({}, { __mode = "k" }) -- never revisit these

function Chest.findChildOfClass(root, className)
    if not root then return nil end
    for _, child in next, root:GetChildren() do
        if child:IsA(className) then return child end
        local found = Chest.findChildOfClass(child, className)
        if found then return found end
    end
    return nil
end

function Chest.getChestRoot(instance)
    if instance:IsA("BasePart") then return instance end
    if instance:IsA("Model") then
        return instance.PrimaryPart or instance:FindFirstChild("HumanoidRootPart")
            or instance:FindFirstChild("Handle") or Chest.findChildOfClass(instance, "BasePart")
    end
    return instance.Parent and Chest.getChestRoot(instance.Parent) or nil
end

function Chest.isClosedChest(instance)
    if not instance or not instance.Parent then return false end
    if OpenedChests[instance] then return false end
    if ChestAttempts[instance] and ChestAttempts[instance] > os.clock() then return false end
    if instance:GetAttribute("Opened") == true or instance:GetAttribute("Collected") == true then return false end
    local opened = instance:FindFirstChild("Opened") or instance:FindFirstChild("Collected")
    return not (opened and opened:IsA("BoolValue") and opened.Value)
end

-- Dungeon chests only: the game marks them with the DungeonChest attribute and
-- enables ChestPrompt ONLY once every mob in the room is dead (server-controlled).
-- Locked-room bonus chests (keyhole) carry LockedRoom/KeyTier attributes and a
-- Chest_Lock model — skipped entirely; only normal mob-room chests are collected.
function Chest.isUnlockedDungeonChest(model)
    if not model or not model:IsA("Model") then return false end
    if OpenedChests[model] then return false end
    if model:GetAttribute("DungeonChest") ~= true then return false end
    if model:GetAttribute("Opened") == true or model:GetAttribute("Collected") == true then return false end
    if ChestAttempts[model] and ChestAttempts[model] > os.clock() then return false end
    local prompt = model:FindFirstChild("ChestPrompt", true)
    if not (prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled == true) then return false end
    if model:GetAttribute("LockedRoom") ~= nil or model:GetAttribute("KeyTier") ~= nil
        or model:FindFirstChild("Chest_Lock") then
        return false
    end
    return true
end

-- Walking every Workspace descendant each farm tick is expensive; cache the
-- chest list briefly so targeting stays responsive.
local CachedChests, ChestCacheAt = {}, 0
function Chest.findNearestChest(origin)
    if os.clock() - ChestCacheAt > 0.4 then
        ChestCacheAt = os.clock()
        CachedChests = {}
        for _, descendant in next, Workspace:GetDescendants() do
            if descendant:IsA("Model") and Chest.isUnlockedDungeonChest(descendant) then
                local root = Chest.getChestRoot(descendant)
                if root then CachedChests[#CachedChests + 1] = { Chest = descendant, Root = root } end
            end
        end
    end
    local nearest, nearestRoot, nearestDistance
    for _, entry in next, CachedChests do
        local distance = (entry.Root.Position - origin).Magnitude
        if distance <= State.ChestRange and (not nearestDistance or distance < nearestDistance) then
            nearest, nearestRoot, nearestDistance = entry.Chest, entry.Root, distance
        end
    end
    return nearest, nearestRoot
end

function Chest.collectChest(chest, chestRoot, root)
    if not chest or not chestRoot or not root then return false end
    root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    root.CFrame = chestRoot.CFrame + Vector3.new(0, math.max(2, chestRoot.Size.Y * 0.5 + 1), 0)
    task.wait(0.12)

    local promptFired = false
    local prompt = chest:FindFirstChild("ChestPrompt", true) or Chest.findChildOfClass(chest, "ProximityPrompt")
    if prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled and type(fireproximityprompt) == "function" then
        promptFired = pcall(fireproximityprompt, prompt)
    end
    if type(firetouchinterest) == "function" then
        pcall(firetouchinterest, root, chestRoot, 0)
        pcall(firetouchinterest, root, chestRoot, 1)
    end

    -- The prompt is the real open path; touch is a fallback nudge. Confirm the
    -- chest actually unlocked before marking it done — a keyhole chest swallows
    -- the prompt silently, and the old fire-and-forget retry (1.5s) made the
    -- farm teleport to it and back forever.
    local opened = false
    if promptFired or type(firetouchinterest) == "function" then
        local deadline = os.clock() + 0.8
        while os.clock() < deadline do
            if chest:GetAttribute("Opened") == true or chest:GetAttribute("Collected") == true then
                opened = true
                break
            end
            local flag = chest:FindFirstChild("Opened") or chest:FindFirstChild("Collected")
            if flag and flag:IsA("BoolValue") and flag.Value then
                opened = true
                break
            end
            task.wait(0.1)
        end
    end
    if opened then
        OpenedChests[chest] = true
        return true
    end
    local fails = (ChestAttemptCount[chest] or 0) + 1
    ChestAttemptCount[chest] = fails
    ChestAttempts[chest] = os.clock() + math.min(3 * 2 ^ (fails - 1), 90)
    return false
end

-- Room-gated collection: chests are only touched when nothing alive is near
-- them, so the farm stops grabbing boxes from rooms it has not cleared.
function Chest.shouldCollectChest(waitRoomClear, mobsNearChest)
    if not waitRoomClear then return true end
    return (tonumber(mobsNearChest) or 0) == 0
end

function Chest.countNearbyMobs(origin, range, ownCharacter)
    local count = 0
    for _, model in next, CollectionService:GetTagged("NPC") do
        if isValidTarget(model, ownCharacter) then
            local modelRoot = getRoot(model)
            if modelRoot and (modelRoot.Position - origin).Magnitude <= range then count += 1 end
        end
    end
    -- Untagged dungeon rigs (boss wings, loot rooms) count too; flagged
    -- mimics/guards stay filtered out by isValidTarget.
    for _, d in next, Workspace:GetDescendants() do
        if d:IsA("Humanoid") and d.Health > 0 and not CollectionService:HasTag(d.Parent, "NPC") and isValidTarget(d.Parent, ownCharacter) then
            local modelRoot = getRoot(d.Parent)
            if modelRoot and (modelRoot.Position - origin).Magnitude <= range then count += 1 end
        end
    end
    return count
end

-- Final fallback when no mobs and no chests remain anywhere: walk the dungeon
-- door by door, room by room, until the boss room streams in. Only reached on
-- a fully cleared floor, so it never competes with the farm's TP-to-mob
-- priority. Standing at a door means the next zone is one step away, so the
-- farm steps through it instead of idling there — that hold used to leave the
-- farm stopped forever in a far room whose mobs had not streamed in yet.
local CachedDoors, DoorCacheAt = {}, 0
local PassedDoors = {}
function Tgt.resetRoomProgress()
    if next(PassedDoors) ~= nil then
        PassedDoors = {}
        CachedDoors = {}
        DoorCacheAt = 0
    end
end
function Tgt.moveTowardNextRoom(root)
    if os.clock() - DoorCacheAt > 0.5 then
        DoorCacheAt = os.clock()
        CachedDoors = {}
        for _, d in next, Workspace:GetDescendants() do
            if d:IsA("BasePart") and d.Name == "Door" and d.Transparency > 0.5 and not d.CanCollide and not PassedDoors[d] then
                CachedDoors[#CachedDoors + 1] = d
            end
        end
    end
    local nearest, nearestDistance = nil, math.huge
    for _, door in next, CachedDoors do
        if not PassedDoors[door] and door.Parent then
            local distance = (door.Position - root.Position).Magnitude
            if distance > 8 and distance < 600 and distance < nearestDistance then nearest, nearestDistance = door, distance end
        end
    end
    if not nearest then return false end
    local direction = (nearest.Position - root.Position) * Vector3.new(1, 0, 1)
    direction = direction.Magnitude > 0.5 and direction.Unit or root.CFrame.LookVector
    root.AssemblyLinearVelocity, root.AssemblyAngularVelocity = Vector3.zero, Vector3.zero
    if nearestDistance <= 22 then
        -- Already at the approach point: step through the door into the next
        -- zone (and mark its neighbouring door parts passed so a double-wide
        -- doorway cannot bounce the farm back).
        for _, door in next, CachedDoors do
            if door.Parent and (door.Position - nearest.Position).Magnitude <= 16 then PassedDoors[door] = true end
        end
        root.CFrame = CFrame.new(nearest.Position + direction * 12 + Vector3.new(0, 2, 0))
    else
        root.CFrame = CFrame.new(nearest.Position + direction * 18 + Vector3.new(0, 2, 0))
    end
    return true
end

-- This game has no Tool object: the weapon is welded to the character and attacks
-- go through the Inputs.Attack RemoteEvent (same path the game's Weapon_Input uses).
local AttackRemote
do
    local remotes = ReplicatedStorage:FindFirstChild("Player")
    remotes = remotes and remotes:FindFirstChild("Remotes")
    remotes = remotes and remotes:FindFirstChild("Inputs")
    AttackRemote = remotes and remotes:FindFirstChild("Attack")
end

local CurrentTargetRoot -- set by the farm loop; weak so dead targets GC

function Cbt.attackDirection()
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root and CurrentTargetRoot and CurrentTargetRoot.Parent then
        local aim = (CurrentTargetRoot.Position - root.Position)
        if aim.Magnitude > 0.05 then return aim.Unit end
    end
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.MoveDirection.Magnitude > 0.01 then return humanoid.MoveDirection end
    if Workspace.CurrentCamera then return Workspace.CurrentCamera.CFrame.LookVector end
    return Vector3.zero
end

function Cbt.sendMouseClick()
    if not AttackRemote then return end
    pcall(function() AttackRemote:FireServer(Cbt.attackDirection()) end)
end

local SkillKeys = { ["1"] = Enum.KeyCode.One, ["2"] = Enum.KeyCode.Two, ["3"] = Enum.KeyCode.Three, ["4"] = Enum.KeyCode.Four }
function Cbt.sendSkill(skill)
    local key = SkillKeys[skill]
    if not key or UserInputService:GetFocusedTextBox() then return end
    -- Do not use keybd_event or hold a key across yields: the user's physical
    -- keyboard remains independent and the synthetic key is always released.
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, key, false, game)
        VirtualInputManager:SendKeyEvent(false, key, false, game)
    end)
end

function Cbt.selectedSkillList()
    local result = {}
    for _, skill in next, { "1", "2", "3", "4" } do if State.SelectedSkills[skill] then result[#result + 1] = skill end end
    return result
end

-- Auto Parry: mob swings are server animations that replicate with an Action
-- priority; react to the windup and tap the Parry input inside its 0.25s window.
local ParryRemote
do
    local remotes = ReplicatedStorage:FindFirstChild("Player")
    remotes = remotes and remotes:FindFirstChild("Remotes")
    remotes = remotes and remotes:FindFirstChild("Inputs")
    ParryRemote = remotes and remotes:FindFirstChild("Parry")
end
local ParryHooks = {}
local ParryLastFire = 0
local parryMaintainThread

function Cbt.stopParry()
    if parryMaintainThread then pcall(task.cancel, parryMaintainThread); parryMaintainThread = nil end
    for model, connection in next, ParryHooks do
        pcall(function() connection:Disconnect() end)
        ParryHooks[model] = nil
    end
end

function Cbt.tryParry(model)
    if not State.AutoParry or not ParryRemote then return end
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local modelRoot = getRoot(model)
    if not root or not modelRoot then return end
    if (modelRoot.Position - root.Position).Magnitude > State.ParryRange then return end
    local now = os.clock()
    if now - ParryLastFire < 1.6 then return end -- server parry cooldown is ~2s
    ParryLastFire = now
    task.delay(State.ParryDelay, function()
        if running and State.AutoParry then
            pcall(function() ParryRemote:FireServer() end)
        end
    end)
end

function Cbt.startParry()
    if parryMaintainThread then return end
    parryMaintainThread = task.spawn(function()
        while running do
            pcall(function()
                for _, model in next, CollectionService:GetTagged("NPC") do
                    if not ParryHooks[model] then
                        local humanoid = model:FindFirstChildOfClass("Humanoid")
                        local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
                        if animator then
                            ParryHooks[model] = animator.AnimationPlayed:Connect(function(track)
                                local priority = track.Priority and track.Priority.Name or ""
                                if priority == "Action" or priority == "Action2"
                                    or priority == "Action3" or priority == "Action4" then
                                    Cbt.tryParry(model)
                                end
                            end)
                        end
                    end
                end
                for model, connection in next, ParryHooks do
                    if typeof(model) ~= "Instance" or model.Parent == nil then
                        pcall(function() connection:Disconnect() end)
                        ParryHooks[model] = nil
                    end
                end
            end)
            task.wait(0.3)
        end
        Cbt.stopParry()
    end)
end

local function startFarm()
    if State.AutoFarm then return end
    State.AutoFarm = true
    farmToken, attackToken, skillToken = farmToken + 1, attackToken + 1, skillToken + 1
    local thisFarm, thisAttack, thisSkill = farmToken, attackToken, skillToken
    setStatus("Auto farm: running")
    task.spawn(function()
        while running and State.AutoFarm and thisFarm == farmToken do
            local dungeonActive = Run.isDungeonActive()
            local character, _, root = PF.getCharacter()
            if not dungeonActive then
                Tgt.resetRoomProgress()
                setStatus("Auto farm: waiting to enter dungeon")
            elseif character and root then
                -- Priority: collect unlocked cleared-room chests first (the
                -- game enables ChestPrompt only once the room is dead, so a
                -- visible chest never competes with an active fight), then
                -- fight in-range mobs, chase far mobs, and walk to the next
                -- room. Chests used to be checked only when no mobs were in
                -- range, which left them behind until the dungeon ended.
                local target = Tgt.findNearestTarget(root.Position, character, true)
                local targetRoot = target and getRoot(target)
                local chest, chestRoot
                if State.AutoCollectChest then
                    chest, chestRoot = Chest.findNearestChest(root.Position)
                    if chestRoot and not Chest.shouldCollectChest(State.WaitRoomClear, Chest.countNearbyMobs(chestRoot.Position, State.RoomClearRange, character)) then
                        chest, chestRoot = nil, nil
                    end
                end
                if chestRoot then
                    CurrentTargetRoot = nil
                    if root.Anchored then root.Anchored = false end
                    setStatus("Collecting chest: " .. chest.Name)
                    Chest.collectChest(chest, chestRoot, root)
                elseif targetRoot then
                    CurrentTargetRoot = targetRoot
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.CFrame = Tgt.targetCFrame(targetRoot)
                    -- Facing follows the user camera; the script never touches it.
                    -- Above/Below: anchor so gravity/physics cannot drift the
                    -- character away; attacks and skills are remote-fired and
                    -- do not need character physics.
                    local shouldAnchor = State.Position == "Above" or State.Position == "Below"
                    if root.Anchored ~= shouldAnchor then root.Anchored = shouldAnchor end
                    setStatus("Target: " .. target.Name)
                else
                    if root.Anchored then root.Anchored = false end
                    -- Nothing near: teleport straight to the far fallback target
                    -- (boss wings, loot rooms) like before.
                    local farTarget = Tgt.findNearestTarget(root.Position, character)
                    local farRoot = farTarget and getRoot(farTarget)
                    if farRoot then
                        root.AssemblyLinearVelocity = Vector3.zero
                        root.CFrame = Tgt.targetCFrame(farRoot)
                        CurrentTargetRoot = farRoot
                        setStatus("Target: " .. farTarget.Name)
                    elseif Tgt.moveTowardNextRoom(root) then
                        setStatus("All clear — heading to the boss room")
                    else
                        setStatus("Auto farm: waiting for target or chest")
                    end
                end
            end
            task.wait(0.06)
        end
    end)
    task.spawn(function()
        while running and State.AutoFarm and thisAttack == attackToken do
            -- Only swing at something: no target means no air attacks.
            if Run.isDungeonActive() and State.AutoAttack and CurrentTargetRoot then Cbt.sendMouseClick() end
            task.wait(math.max(0.05, State.AttackInterval))
        end
    end)
    task.spawn(function()
        local index = 0
        while running and State.AutoFarm and thisSkill == skillToken do
            local skills = Cbt.selectedSkillList()
            if Run.isDungeonActive() and State.AutoSkills and CurrentTargetRoot and #skills > 0 then index = (index % #skills) + 1; Cbt.sendSkill(skills[index]) end
            task.wait(math.max(0.1, State.SkillInterval))
        end
    end)
end

local function stopFarm()
    if not State.AutoFarm then return end
    State.AutoFarm = false; farmToken, attackToken, skillToken = farmToken + 1, attackToken + 1, skillToken + 1
    CurrentTargetRoot = nil
    -- No teleport-back: the character stays wherever the farm left it.
    local _, _, root = PF.getCharacter()
    if root and root.Anchored then root.Anchored = false end
    setStatus("Auto farm: stopped")
end

-- Auto Heal: drink the equipped potion whenever HP dips below the threshold.
-- The server enforces its own potion cooldown, so over-calls are harmless.
local function startAutoHeal()
    if autoHealThread then return end
    autoHealThread = task.spawn(function()
        while running and State.AutoHeal do
            pcall(function()
                local character = LocalPlayer.Character
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                if humanoid and humanoid.Health > 0
                    and humanoid.Health / humanoid.MaxHealth < (tonumber(State.HealThreshold) or 20) / 100 then
                    local service = Data.getKnitService("PotionService")
                    if service then callKnitAwait(service, "UsePotion") end
                end
            end)
            task.wait(0.5)
        end
        autoHealThread = nil
    end)
end

-- Auto Stats: pour UnspentSkillPoints into the selected stats round-robin as
-- they are earned. Allocation is permanent, so it only runs while enabled.
local function startAutoStatsLoop()
    if autoStatsThread then return end
    autoStatsThread = task.spawn(function()
        while running and State.AutoStats do
            pcall(function()
                if not (RegistryOk and Registry) then return end
                local playerData = Registry:Get("PlayerData")
                local data = playerData and playerData.Data
                if not data then return end
                local chosen = {}
                for stat, selected in next, State.SelectedStats do
                    if selected == true then chosen[#chosen + 1] = tostring(stat) end
                end
                if #chosen == 0 then return end
                if (data.UnspentSkillPoints or 0) <= 0 then return end
                local statService = Data.getKnitService("StatService")
                if not statService then return end
                local spent, guard = 0, 0
                while guard < 40 do
                    guard += 1
                    if (data.UnspentSkillPoints or 0) <= 0 then break end
                    local stat = chosen[(guard - 1) % #chosen + 1]
                    local ok, success = callKnitAwait(statService, "AllocatePoint", stat)
                    if not (ok and success ~= false) then break end
                    spent += 1
                    task.wait(0.1)
                end
                if spent > 0 then setStatus("Stat points spent: " .. spent) end
            end)
            task.wait(3)
        end
        autoStatsThread = nil
    end)
end

-- CRAFTING

-- Auto Craft: watches the selected recipes and crafts whenever the account
-- owns the required materials (CraftingService.CanCraft/Craft; recipe ids
-- come from the game's own CraftingData). Guaranteed output, no RNG. Purity
-- Stone chains nicely with Auto Forge.
local CraftState = { AutoCraft = false, SelectedRecipes = {}, craftThread = nil }

local function setCraftStatus(text)
    if CraftStatusLabel and CraftStatusLabel.SetDesc then
        pcall(CraftStatusLabel.SetDesc, CraftStatusLabel, tostring(text))
    end
end

local function getRecipeIds()
    local ids = {}
    local gameInfo = ReplicatedStorage:FindFirstChild("GameInfo")
    local okData, cd = pcall(require, gameInfo and gameInfo:FindFirstChild("CraftingData"))
    if okData and type(cd) == "table" and type(cd.Recipes) == "table" then
        for id in next, cd.Recipes do ids[#ids + 1] = tostring(id) end
        table.sort(ids)
    end
    if #ids == 0 then ids = { "Purity Stone" } end
    return ids
end

local function craftSelectedOnce()
    local service = Data.getKnitService("CraftingService")
    if not service then
        setCraftStatus("Craft: CraftingService unavailable")
        return
    end
    local selected = 0
    for _, selectedFlag in next, CraftState.SelectedRecipes do
        if selectedFlag == true then selected += 1 end
    end
    if selected == 0 then
        setCraftStatus("Craft: no recipes selected")
        return
    end
    local crafted, lines = 0, {}
    for recipeId, selectedFlag in next, CraftState.SelectedRecipes do
        if selectedFlag == true then
            local can = select(1, callKnitData(service, "CanCraft", recipeId))
            if can == true then
                local ok, res = callKnitData(service, "Craft", recipeId)
                if ok and res ~= false then
                    crafted += 1
                    lines[#lines + 1] = recipeId .. " crafted"
                else
                    lines[#lines + 1] = recipeId .. " failed: " .. tostring(res)
                end
                task.wait(0.3)
            else
                lines[#lines + 1] = recipeId .. " missing materials"
            end
        end
    end
    setCraftStatus("Crafted " .. crafted .. "/" .. selected .. " | " .. table.concat(lines, ", "))
end

local function startCraftLoop()
    if CraftState.craftThread then return end
    CraftState.craftThread = task.spawn(function()
        while running and CraftState.AutoCraft do
            pcall(craftSelectedOnce)
            task.wait(2)
        end
        CraftState.craftThread = nil
    end)
end

-- FORGE

local lastForgeStatus
function Forge.setForgeStatus(text)
    if text == lastForgeStatus then return end
    lastForgeStatus = text
    if ForgeStatusLabel then
        if ForgeStatusLabel.SetDesc then pcall(ForgeStatusLabel.SetDesc, ForgeStatusLabel, tostring(text))
        elseif ForgeStatusLabel.SetText then pcall(ForgeStatusLabel.SetText, ForgeStatusLabel, tostring(text)) end
    end
end

function Forge.getEquippedItems()
    local playerData = Data.getPlayerData()
    local data = playerData and playerData.Data
    return data and data.Equipment or nil
end

-- Bag gear (bought or looted). Forging works on any item GUID, so unequipped
-- pieces — e.g. a weapon that just dropped — can be forged without equipping.
function Forge.getBagItems()
    local playerData = Data.getPlayerData()
    local data = playerData and playerData.Data
    return data and data.EquipmentInventory or nil
end

-- INVENTORY TOOLS

-- Equip Best: score every bag piece against the equipped one per slot
-- (rarity, enchant, level requirement) and equip the winner. Locked pieces
-- are never touched.
local RarityRank = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Mythic = 6, Celestial = 7 }

function Inv.equipmentScore(item)
    if type(item) ~= "table" then return -1 end
    local rarity = RarityRank[tostring(item.Rarity)] or 0
    return rarity * 1000000 + (tonumber(item.EnchantLevel) or 0) * 10000 + (tonumber(item.LevelReq) or 0) * 100
end

function Inv.equipBestPass()
    local equipped = Forge.getEquippedItems()
    local bag = Forge.getBagItems()
    if type(equipped) ~= "table" or type(bag) ~= "table" then
        setLobbyStatus("Equip best: player data unavailable")
        return
    end
    local best = {}
    for _, item in next, bag do
        if type(item) == "table" and item.GUID and not item.Locked then
            local slot = tostring(item.Slot)
            if Inv.equipmentScore(item) > Inv.equipmentScore(best[slot]) then best[slot] = item end
        end
    end
    local service = Data.getKnitService("EquipmentService")
    if not service then
        setLobbyStatus("Equip best: EquipmentService unavailable")
        return
    end
    local changed = 0
    for slot, item in next, best do
        local current = equipped[slot]
        if not (type(current) == "table" and current.GUID == item.GUID)
            and Inv.equipmentScore(item) > Inv.equipmentScore(current) then
            local ok, success = callKnitAwait(service, "Equip", item.GUID)
            if ok and success ~= false then
                changed += 1
                setLobbyStatus("Equipped best " .. slot .. ": " .. tostring(item.ItemId))
            end
            task.wait(0.25)
        end
    end
    if changed == 0 then setLobbyStatus("Equip best: already wearing the best") end
end

-- Auto Use: keeps the selected consumables consumed (one every 0.5s, 3s scan
-- cycle) while the toggle is on. Selection comes from items the account owns.
local InventoryState = { AutoUse = false, SelectedItems = {}, useThread = nil }

function Inv.getConsumableNames()
    local names = {}
    local playerData = Data.getPlayerData()
    local consumables = playerData and playerData.Data and playerData.Data.Consumables
    if type(consumables) == "table" then
        for name in next, consumables do names[#names + 1] = tostring(name) end
        table.sort(names)
    end
    if #names == 0 then names = { "AspectGem" } end
    return names
end

function Inv.startAutoUseLoop()
    if InventoryState.useThread then return end
    InventoryState.useThread = task.spawn(function()
        while running and InventoryState.AutoUse do
            pcall(function()
                local playerData = Data.getPlayerData()
                local consumables = playerData and playerData.Data and playerData.Data.Consumables
                local service = Data.getKnitService("ConsumableService")
                if type(consumables) == "table" and service then
                    for name in next, consumables do
                        if running and InventoryState.AutoUse and InventoryState.SelectedItems[name]
                            and (tonumber(consumables[name]) or 0) > 0 then
                            callKnitAwait(service, "UseConsumable", name)
                            task.wait(0.5)
                        end
                    end
                end
            end)
            task.wait(3)
        end
        InventoryState.useThread = nil
    end)
end

-- Pure threshold decision so the forge budget rules can be self-checked
-- without touching the server. Returns action, useEnhance, useProtect.
function Forge.decideForgeAttempt(info)
    if type(info) ~= "table" then return "no-info", false, false end
    if info.IsMaxed then return "maxed", false, false end
    if info.CanForge == false then return "locked", false, false end
    local level = tonumber(info.ForgeLevel) or 0
    if level >= (tonumber(ForgeState.TargetLevel) or 20) then return "target", false, false end
    local coins = tonumber(info.CoinsOwned) or 0
    local cost = tonumber(info.NextCoinCost) or 0
    if coins - cost < (tonumber(ForgeState.CoinReserve) or 0) then return "reserve", false, false end
    if (tonumber(info.MaterialsOwned) or 0) < (tonumber(info.NextMaterialCost) or 1) then return "materials", false, false end
    local rate = tonumber(info.NextSuccessRate) or 0
    local minRate = (tonumber(ForgeState.MinSuccess) or 0) / 100
    local enhance = false
    if ForgeState.AutoEnhance and rate < minRate
        and (level + 1) >= (tonumber(ForgeState.EnhanceFromLevel) or 0)
        and (tonumber(info.PurityOwned) or 0) > 0
        and rate + (tonumber(info.PurityBonus) or 0) >= minRate then
        enhance = true
    end
    if rate < minRate and not enhance then return "low-rate", false, false end
    local protect = ForgeState.AutoProtect
        and (tonumber(info.NextDowngradeChance) or 0) > 0
        and (level + 1) >= (tonumber(ForgeState.ProtectFromLevel) or 0)
        and (tonumber(info.ProtectionScrollsOwned) or 0) > 0
        and info.ProtectApplies ~= false
    return "forge", enhance, protect
end

function Forge.reforgeItem(service, slot, guid, rolls)
    local quality = ForgeState.ReforgeQuality == "High" and 2 or 1
    local done = 0
    for _ = 1, (tonumber(rolls) or 1) do
        local res = callKnitData(service, "ReforgeItem", guid, quality)
        if type(res) ~= "table" or res.Success ~= true then break end
        done += 1
        task.wait(0.25)
    end
    if done > 0 then
        Forge.setForgeStatus("Forge " .. slot .. ": rerolled affix " .. done .. "x (" .. tostring(ForgeState.ReforgeQuality) .. ")")
    end
    return done
end

function Forge.attemptForge(slot, item, service)
    local guid = item and item.GUID
    if not guid then return false end
    -- callKnitData returns (data, errMessage), not (ok, data)
    local info, infoErr = callKnitData(service, "GetForgeInfo", guid)
    if type(info) ~= "table" then
        Forge.setForgeStatus("Forge " .. slot .. ": forge info unavailable (" .. tostring(infoErr or "bad payload") .. ")")
        return false
    end
    local action, enhance, protect = Forge.decideForgeAttempt(info)
    if action == "maxed" then Forge.setForgeStatus("Forge " .. slot .. ": maxed") return false end
    if action == "locked" then Forge.setForgeStatus("Forge " .. slot .. ": cannot forge") return false end
    if action == "target" then Forge.setForgeStatus("Forge " .. slot .. ": target level " .. tostring(ForgeState.TargetLevel) .. " reached") return false end
    if action == "reserve" then Forge.setForgeStatus("Forge " .. slot .. ": coin reserve hit (" .. tostring(info.CoinsOwned) .. " coins)") return false end
    if action == "materials" then Forge.setForgeStatus("Forge " .. slot .. ": out of " .. tostring(info.MaterialId) .. " (" .. tostring(info.MaterialsOwned) .. " left)") return false end
    if action == "low-rate" then
        Forge.setForgeStatus("Forge " .. slot .. ": waiting, success " .. math.floor((tonumber(info.NextSuccessRate) or 0) * 100 + 0.5) .. "% < " .. tostring(ForgeState.MinSuccess) .. "%")
        return false
    end
    if action ~= "forge" then return false end
    local res, forgeErr = callKnitData(service, "ForgeItem", guid, { Enhance = enhance, Protect = protect })
    if type(res) ~= "table" or res.Success ~= true then
        local reason = (type(res) == "table" and res.Message) or forgeErr or "rejected"
        Forge.setForgeStatus("Forge " .. slot .. ": failed (" .. tostring(reason) .. ")")
        return false
    end
    local notes = {}
    if enhance then table.insert(notes, "purity") end
    if protect then table.insert(notes, "scroll") end
    if res.GrantedAffix then table.insert(notes, "affix " .. tostring(res.GrantedAffix.StatKey)) end
    Forge.setForgeStatus("Forge " .. slot .. ": level " .. tostring(res.NewLevel) .. (#notes > 0 and " (" .. table.concat(notes, ", ") .. ")" or ""))
    if res.GrantedAffix and ForgeState.AutoReforge then
        Forge.reforgeItem(service, slot, guid, tonumber(ForgeState.ReforgeCount) or 1)
    end
    return true
end

function Forge.forgePass(service)
    -- Only the worn items picked in the Items dropdown get forged, identified
    -- by their "Slot: ItemName" label at forge time.
    local attempted = 0
    local equipment = Forge.getEquippedItems()
    if not equipment then Forge.setForgeStatus("Forge: player data unavailable") return 0 end
    local slots = {}
    for slot in next, equipment do table.insert(slots, tostring(slot)) end
    table.sort(slots)
    local anySelected = false
    for _, slot in next, slots do
        local item = equipment[slot]
        local label = slot .. ": " .. tostring(item and item.ItemId or "?")
        if ForgeState.SelectedItems[label] then anySelected = true break end
    end
    if not anySelected then Forge.setForgeStatus("Forge: no items selected") return 0 end
    for _, slot in next, slots do
        if not running then break end
        local item = equipment[slot]
        local label = slot .. ": " .. tostring(item and item.ItemId or "?")
        if ForgeState.SelectedItems[label] then
            local ok, forgedSlot = pcall(Forge.attemptForge, slot, item, service)
            if ok and forgedSlot then attempted += 1 end
            task.wait(0.35)
        end
    end
    return attempted
end

function Forge.startForgeLoop()
    if forgeThread then return end
    forgeThread = task.spawn(function()
        while running and ForgeState.AutoForge do
            pcall(function()
                local service = Data.getKnitService("ForgeService")
                if not service then
                    Forge.setForgeStatus("Forge: ForgeService unavailable")
                else
                    Forge.forgePass(service)
                end
            end)
            task.wait(1.5)
        end
        forgeThread = nil
    end)
end

-- CLASS REROLL

local lastRerollStatus
function Reroll.setRerollStatus(text)
    if text == lastRerollStatus then return end
    lastRerollStatus = text
    if RerollStatusLabel then
        if RerollStatusLabel.SetDesc then pcall(RerollStatusLabel.SetDesc, RerollStatusLabel, tostring(text))
        elseif RerollStatusLabel.SetText then pcall(RerollStatusLabel.SetText, RerollStatusLabel, tostring(text)) end
    end
end

-- Pure slot-eligibility rule so the reroll guards can be self-checked without
-- the server. Returns "ok", "locked", or "not-unlocked".
function Reroll.decideRerollSlot(slotIndex, maxUnlocked, slotLocks)
    local index = tonumber(slotIndex) or 0
    if index > (tonumber(maxUnlocked) or 0) then return "not-unlocked" end
    if slotLocks and slotLocks[index] == true then return "locked" end
    return "ok"
end

function Reroll.rerollCountsLine(counts)
    return "Spins: Normal " .. tostring(type(counts) == "table" and counts.Normal or "?")
        .. " | Lucky " .. tostring(type(counts) == "table" and counts.Lucky or "?")
end

function Reroll.rerollPass(service, singlePass)
    local counts = select(1, callKnitData(service, "GetSpinCounts"))
    local slotData = select(1, callKnitData(service, "GetSlotData"))
    if type(slotData) ~= "table" then
        Reroll.setRerollStatus("Reroll: slot data unavailable")
        return
    end
    local spinType = RerollState.SpinType == "Lucky" and "Lucky" or "Normal"
    local remaining = (type(counts) == "table" and tonumber(counts[spinType])) or 0
    local unlockedSlots = 1 + (tonumber(slotData.CoinSlotsPurchased) or 0)
    -- Coin-only slot unlock. One attempt per activation; the Robux remote is
    -- never touched.
    if RerollState.AutoUnlockSlot and not RerollState.UnlockAttempted then
        RerollState.UnlockAttempted = true
        local res, err = callKnitData(service, "PurchaseSlot")
        if type(res) == "table" or res == true then
            local refreshed = select(1, callKnitData(service, "GetSlotData"))
            unlockedSlots = 1 + (tonumber(type(refreshed) == "table" and refreshed.CoinSlotsPurchased) or 0)
            Reroll.setRerollStatus("Reroll: unlocked slot " .. unlockedSlots .. " with coins")
        else
            Reroll.setRerollStatus("Reroll: coin unlock rejected (" .. tostring(err or "server refused") .. ") — slot may need Robux")
        end
    end
    local chosen = {}
    for slot in next, RerollState.SelectedSlots do
        if RerollState.SelectedSlots[slot] then chosen[#chosen + 1] = tonumber(slot) or 0 end
    end
    table.sort(chosen)
    local spun = 0
    for _, slotIndex in next, chosen do
        if not (running and (singlePass or RerollState.AutoReroll)) then break end
        if remaining <= 0 then
            Reroll.setRerollStatus("Reroll: out of " .. spinType .. " spins (" .. Reroll.rerollCountsLine(type(counts) == "table" and counts or {}) .. ")")
            break
        end
        local verdict = Reroll.decideRerollSlot(slotIndex, unlockedSlots, slotData.SlotLocks)
        if verdict == "not-unlocked" then
            Reroll.setRerollStatus("Reroll: slot " .. slotIndex .. " not unlocked (coin slots: " .. unlockedSlots .. ")")
        elseif verdict == "locked" then
            Reroll.setRerollStatus("Reroll: slot " .. slotIndex .. " is locked")
        else
            local switched = select(1, callKnitData(service, "SwitchSlot", slotIndex))
            if switched ~= true and type(switched) ~= "table" then
                Reroll.setRerollStatus("Reroll: could not switch to slot " .. slotIndex)
            else
                callKnitData(service, "Spin", spinType, false)
                task.wait(0.7)
                local refreshed = select(1, callKnitData(service, "GetSlotData"))
                local freshCounts = select(1, callKnitData(service, "GetSpinCounts"))
                if type(freshCounts) == "table" then
                    counts = freshCounts
                    remaining = tonumber(counts[spinType]) or (remaining - 1)
                else
                    remaining -= 1
                end
                spun += 1
                local newClass = type(refreshed) == "table" and type(refreshed.Slots) == "table" and refreshed.Slots[slotIndex] or "?"
                Reroll.setRerollStatus("Reroll: slot " .. slotIndex .. " -> " .. tostring(newClass) .. " (" .. spinType .. ") | " .. Reroll.rerollCountsLine(type(counts) == "table" and counts or {}))
            end
        end
        task.wait(0.5)
    end
    if RerollState.ReturnToOriginalSlot and tonumber(slotData.ActiveIndex) then
        callKnitData(service, "SwitchSlot", tonumber(slotData.ActiveIndex))
    end
    if spun == 0 and remaining > 0 and #chosen > 0 then
        Reroll.setRerollStatus("Reroll: nothing spun this pass | " .. Reroll.rerollCountsLine(type(counts) == "table" and counts or {}))
    end
end

function Reroll.startRerollLoop()
    if rerollThread then return end
    rerollThread = task.spawn(function()
        while running and RerollState.AutoReroll do
            pcall(Reroll.rerollPass, Data.getKnitService("SummoningService"))
            task.wait(1.2)
        end
        rerollThread = nil
    end)
end

function Reroll.runRerollOnce()
    task.spawn(function()
        pcall(Reroll.rerollPass, Data.getKnitService("SummoningService"), true)
    end)
end

-- SERVER TOOLS

-- Server info (players/ping/jobid), clipboard copy, and a filtered server hop.
-- The public games API exposes player counts per server but no per-server ping,
-- so the ping filter applies to the current server display only.
local ServerState = { MinPlayers = 1, MaxPlayers = 50 }
local ServerInfoLabel

function Srv.copyToClipboard(text)
    for _, fn in next, { setclipboard, toclipboard, writeclipboard } do
        if type(fn) == "function" then
            local ok = pcall(fn, text)
            if ok then return true end
        end
    end
    return false
end

function Srv.getServerInfoText()
    local players = tostring(#Players:GetPlayers()) .. "/" .. tostring(Players.MaxPlayers)
    local ping = "?"
    pcall(function() ping = tostring(math.floor(LocalPlayer:GetNetworkPing() * 1000)) .. " ms" end)
    return "Players: " .. players .. " | Ping: " .. ping .. " | JobId: " .. string.sub(game.JobId, 1, 8) .. "..."
end

function Srv.startServerInfoLoop()
    task.spawn(function()
        while running do
            if ServerInfoLabel and ServerInfoLabel.SetDesc then
                pcall(ServerInfoLabel.SetDesc, ServerInfoLabel, Srv.getServerInfoText())
            end
            task.wait(3)
        end
    end)
end

function Srv.hopWithFilters(minPlayers, maxPlayers)
    task.spawn(function()
        local seen, candidates = {}, {}
        local cursor = ""
        for _ = 1, 3 do
            local url = "https://games.roblox.com/v1/games/" .. game.PlaceId
                .. "/servers/Public?limit=100&excludeFullGames=true" .. (cursor ~= "" and "&cursor=" .. cursor or "")
            local ok, response = pcall(request, { Url = url, Method = "GET" })
            if not ok or type(response) ~= "table" or type(response.Body) ~= "string" then break end
            local okDecode, data = pcall(function() return game:GetService("HttpService"):JSONDecode(response.Body) end)
            if not okDecode or type(data) ~= "table" or type(data.data) ~= "table" then break end
            for _, server in next, data.data do
                if server.id and server.id ~= game.JobId and not seen[server.id] then
                    seen[server.id] = true
                    local playing = tonumber(server.playing) or 0
                    if playing >= minPlayers and playing <= maxPlayers then
                        candidates[#candidates + 1] = server.id
                    end
                end
            end
            cursor = tostring(data.nextPageCursor or "")
            if cursor == "" then break end
        end
        if #candidates == 0 then
            WindUI:Notify({ Title = "Server Hop", Content = "No server matches the filters.", Duration = 4 })
            return
        end
        local target = candidates[math.random(1, #candidates)]
        pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, target, LocalPlayer) end)
    end)
end

local function stopAll()
    running = false; stopFarm(); stopLobbyLoops()
    PF.restorePlayerModifiers()
    if jumpConnection then jumpConnection:Disconnect(); jumpConnection = nil end
    if characterConnection then characterConnection:Disconnect(); characterConnection = nil end
    Cbt.stopParry()
    if autoStatsThread then pcall(task.cancel, autoStatsThread); autoStatsThread = nil end
    ForgeState.AutoForge = false
    if forgeThread then pcall(task.cancel, forgeThread); forgeThread = nil end
    RerollState.AutoReroll = false
    if rerollThread then pcall(task.cancel, rerollThread); rerollThread = nil end
    State.AutoHeal = false
    if autoHealThread then pcall(task.cancel, autoHealThread); autoHealThread = nil end
    setClickTp(false)
    setFullbright(false)
end
env.__DungeonLootrStop = stopAll

local function unloadScript()
    stopAll()
    Config.flushConfig()
    env.__DungeonLootrStop = nil
    if UIWindow and type(UIWindow.Destroy) == "function" then
        pcall(function() UIWindow:Destroy() end)
    elseif WindUI and type(WindUI.Destroy) == "function" then
        pcall(function() WindUI:Destroy() end)
    end
    cleanupOldWindUI()
end
env.__DungeonLootrUnload = unloadScript

do
    local oldPosition = State.Position; State.Position = "Above"
    local mockRoot = { Position = Vector3.zero, CFrame = CFrame.new() }
    assert(Tgt.targetCFrame(mockRoot).Position.Y == State.Distance, "position self-check failed")
    State.Position = oldPosition
end

do
    -- A failed self-check reports instead of killing the whole script.
    local okCheck, checkErr = pcall(function()
    local function mockInfo(level, rate, purityOwned, purityBonus, downgrade)
        return {
            ForgeLevel = level, NextSuccessRate = rate, PurityOwned = purityOwned, PurityBonus = purityBonus,
            NextDowngradeChance = downgrade, CoinsOwned = 50000, NextCoinCost = 300,
            MaterialsOwned = 10, NextMaterialCost = 1, CanForge = true,
        }
    end
    local saved = ForgeState
    ForgeState = {
        TargetLevel = 15, MinSuccess = 30, CoinReserve = 0,
        AutoEnhance = true, EnhanceFromLevel = 10,
        AutoProtect = true, ProtectFromLevel = 15,
    }
    local action = select(1, Forge.decideForgeAttempt(mockInfo(10, 0.65, 0, 0, 0)))
    assert(action == "forge", "forge decision self-check failed: expected forge at 65%")
    assert(select(1, Forge.decideForgeAttempt(mockInfo(9, 0.28, 0, 0, 0))) == "low-rate", "forge decision self-check failed: expected low-rate without purity")
    local lowAction, lowEnhance = Forge.decideForgeAttempt(mockInfo(9, 0.28, 3, 0.03, 0))
    assert(lowAction == "forge" and lowEnhance == true, "forge decision self-check failed: purity should bridge the gap at level 9+1")
    local earlyAction, earlyEnhance = Forge.decideForgeAttempt(mockInfo(3, 0.28, 3, 0.03, 0))
    assert(earlyAction == "low-rate" and earlyEnhance == false, "forge decision self-check failed: purity must be saved below EnhanceFromLevel")
    assert(select(1, Forge.decideForgeAttempt(mockInfo(15, 0.9, 0, 0, 0))) == "target", "forge decision self-check failed: target level not honored")
    ForgeState = saved
    end)
    if not okCheck then getgenv().__DLSelfCheckError = "forge: " .. tostring(checkErr) end
end

do
    local locks = { [4] = true }
    assert(Reroll.decideRerollSlot(3, 4, locks) == "ok", "reroll self-check failed: unlocked slot should reroll")
    assert(Reroll.decideRerollSlot(4, 4, locks) == "locked", "reroll self-check failed: locked slot must be skipped")
    assert(Reroll.decideRerollSlot(5, 4, locks) == "not-unlocked", "reroll self-check failed: beyond coin slots must be skipped")
end

do
    assert(Chest.shouldCollectChest(true, 0) == true, "collect self-check failed: cleared room should collect")
    assert(Chest.shouldCollectChest(true, 2) == false, "collect self-check failed: mobs near chest must block collection")
    assert(Chest.shouldCollectChest(false, 3) == true, "collect self-check failed: disabled gating must allow collection")
    assert(Chest.countNearbyMobs ~= nil and startAutoHeal ~= nil and Tgt.moveTowardNextRoom ~= nil, "farm helpers missing")
end

characterConnection = LocalPlayer.CharacterAdded:Connect(function()
    OriginalPlayerValues = {}
    table.clear(NoclipOriginal)
    task.wait(0.5)
    PF.applyPlayerModifiers()
end)
PF.startPlayerLoop()
Run.watchRunStart()
Run.connectRunEvents()

assert(Window and type(Window.Tab) == "function", "CC UI API mismatch: Window:Tab is unavailable")
UIWindow = Window

-- This build puts elements directly on the Tab (Tab:Toggle/Slider/Dropdown/
-- Paragraph/Button) with Title/Desc/Value/Callback fields, which is exactly
-- the style the UI code below uses. adaptTab only kicks in if a future
-- library build moves elements onto sections.
local function adaptTab(tab)
    if type(tab) ~= "table" then return nil end
    local okSection, defaultSection = pcall(function()
        return tab:Section({ Title = "Options", Side = "left" })
    end)
    if not okSection or type(defaultSection) ~= "table" then
        return tab
    end

    local function key(data) return tostring(data.Title or "Element") end
    return {
        Paragraph = function(_, data) return defaultSection:Paragraph(data) end,
        Button = function(_, data) return defaultSection:Button(data) end,
        Toggle = function(_, data) return defaultSection:Toggle(data) end,
        Dropdown = function(_, data) return defaultSection:Dropdown(data) end,
        Slider = function(_, data) return defaultSection:Slider(data) end,
        Section = function(_, data)
            local ok, section = pcall(function() return tab:Section(data) end)
            return ok and section or defaultSection
        end,
    }
end

local function createTab(title, icon)
    local tab = Window:Tab({ Title = title, Icon = icon })
    if type(tab) ~= "table" then
        error("CC UI returned an invalid tab: " .. tostring(title))
    end
    if type(tab.Section) == "function" then
        return tab
    end
    return adaptTab(tab)
end
local FarmSection = createTab("Auto Farm", "swords")
local PlayerSection = createTab("Player", "user")
local LobbySection = createTab("Lobby", "door-open")
local InventorySection = createTab("Inventory", "backpack")
local ForgeSection = createTab("Forge", "hammer")
local CraftSection = createTab("Crafting", "wrench")
local ClassesSection = createTab("Classes", "shuffle")
-- This build does not auto-select the first tab.
if type(Window.SelectTab) == "function" then pcall(Window.SelectTab, Window, 1) end
StatusLabel = FarmSection:Paragraph({ Title = "Status", Desc = "Auto farm: stopped" })

-- AUTO FARM TAB --------------------------------------------------------------
local FarmMain = FarmSection:Section({ Title = "Auto Farm", Icon = "swords", Side = "left" })
FarmMain:Toggle({ Title = "Enable Auto Farm", Value = false, Callback = function(value) if value then startFarm() else stopFarm() end end })
FarmMain:Toggle({ Title = "Auto Attack", Value = State.AutoAttack, Callback = function(value) State.AutoAttack = value == true end })
FarmMain:Toggle({ Title = "Auto Skills", Value = State.AutoSkills, Callback = function(value) State.AutoSkills = value == true end })
FarmMain:Toggle({ Title = "Auto Collect Chest", Value = State.AutoCollectChest, Callback = function(value) State.AutoCollectChest = value == true end })
FarmMain:Toggle({ Title = "Auto Select Boss Chests", Value = false, Callback = function(value) LobbyState.AutoSelectChest = value == true end })
FarmMain:Dropdown({ Title = "Boss Chest Picks", Values = { "1", "2", "3" }, Multi = true, Value = { "2", "3" }, Callback = function(value) LobbyState.BossChestPicks = type(value) == "table" and value or { "2", "3" } end })
FarmMain:Toggle({ Title = "Auto Pick Buff", Value = false, Callback = function(value) LobbyState.AutoPickBuff = value == true end })
FarmMain:Dropdown({ Title = "Buff Pick", Values = { "First", "Second", "Third" }, Value = "First", Callback = function(value) LobbyState.BuffPickIndex = value == "Second" and 2 or (value == "Third" and 3 or 1) end })
FarmMain:Dropdown({ Title = "Prefer Blessing", Values = { "Any (use Buff Pick)", table.unpack(BlessingNames) }, Value = "Any (use Buff Pick)", Callback = function(value) LobbyState.PreferredBlessing = (value == "Any (use Buff Pick)" and "") or tostring(value) end })

local FarmSettings = FarmSection:Section({ Title = "Farm Settings", Icon = "crosshair", Side = "right" })
FarmSettings:Dropdown({ Title = "Position", Values = { "Front", "Behind", "Above", "Below" }, Value = State.Position, Callback = function(value) State.Position = value end })
FarmSettings:Dropdown({ Title = "Skills (multi-select)", Values = { "1", "2", "3", "4" }, Multi = true, Value = { "1" }, Callback = function(value)
    State.SelectedSkills = {}
    if type(value) == "table" then
        for skill, selected in next, value do if selected == true then State.SelectedSkills[tostring(skill)] = true end end
        for _, skill in next, value do if type(skill) == "string" then State.SelectedSkills[skill] = true end end
    end
end })
FarmSettings:Slider({ Title = "Distance", Value = { Min = 2, Max = 20, Default = State.Distance }, Step = 1, Callback = function(value) State.Distance = tonumber(value) or State.Distance end })
FarmSettings:Slider({ Title = "Vertical Offset", Value = { Min = -10, Max = 10, Default = State.VerticalOffset }, Step = 1, Callback = function(value) State.VerticalOffset = tonumber(value) or State.VerticalOffset end })
FarmSettings:Slider({ Title = "Target Range", Value = { Min = 25, Max = 500, Default = State.TargetRange }, Step = 25, Callback = function(value) State.TargetRange = tonumber(value) or State.TargetRange end })
FarmSettings:Slider({ Title = "Chest Range", Value = { Min = 50, Max = 500, Default = State.ChestRange }, Step = 25, Callback = function(value) State.ChestRange = tonumber(value) or State.ChestRange end })
FarmSettings:Slider({ Title = "Attack Interval", Value = { Min = 0.05, Max = 1, Default = State.AttackInterval }, Step = 0.05, Callback = function(value) State.AttackInterval = tonumber(value) or State.AttackInterval end })
FarmSettings:Slider({ Title = "Skill Interval", Value = { Min = 0.2, Max = 5, Default = State.SkillInterval }, Step = 0.2, Callback = function(value) State.SkillInterval = tonumber(value) or State.SkillInterval end })

local FarmSurvive = FarmSection:Section({ Title = "Survive & Progress", Icon = "heart-pulse", Side = "left" })
FarmSurvive:Toggle({ Title = "Auto Parry", Value = State.AutoParry, Callback = function(value) State.AutoParry = value == true; if value then Cbt.startParry() end end })
FarmSurvive:Slider({ Title = "Parry Delay", Value = { Min = 0, Max = 0.4, Default = State.ParryDelay }, Step = 0.05, Callback = function(value) State.ParryDelay = tonumber(value) or State.ParryDelay end })
FarmSurvive:Toggle({ Title = "Auto Heal Potion", Value = State.AutoHeal, Callback = function(value) State.AutoHeal = value == true; if value then startAutoHeal() end end })
FarmSurvive:Slider({ Title = "Heal Below %", Value = { Min = 5, Max = 80, Default = State.HealThreshold }, Step = 5, Callback = function(value) State.HealThreshold = tonumber(value) or State.HealThreshold end })
FarmSurvive:Toggle({ Title = "Collect After Room Clear", Value = State.WaitRoomClear, Callback = function(value) State.WaitRoomClear = value == true end })

-- PLAYER TAB -----------------------------------------------------------------
local MovementSection = PlayerSection:Section({ Title = "Movement", Icon = "footprints", Side = "left" })
MovementSection:Toggle({ Title = "Noclip", Value = State.Noclip, Callback = PF.setNoclip })
MovementSection:Toggle({ Title = "Custom WalkSpeed", Value = State.WalkSpeedEnabled, Callback = PF.setWalkSpeedEnabled })
MovementSection:Slider({ Title = "WalkSpeed", Value = { Min = 16, Max = 100, Default = State.WalkSpeed }, Step = 2, Callback = function(value) State.WalkSpeed = value; PF.applyPlayerModifiers() end })
MovementSection:Toggle({ Title = "Custom JumpPower", Value = State.JumpPowerEnabled, Callback = PF.setJumpPowerEnabled })
MovementSection:Slider({ Title = "JumpPower", Value = { Min = 50, Max = 150, Default = State.JumpPower }, Step = 5, Callback = function(value) State.JumpPower = value; PF.applyPlayerModifiers() end })
MovementSection:Toggle({ Title = "Infinite Jump", Value = State.InfiniteJump, Callback = PF.setupInfiniteJump })

local StatsSection = PlayerSection:Section({ Title = "Auto Stats", Icon = "sparkles", Side = "right" })
StatsSection:Dropdown({ Title = "Auto Stats", Values = { "STR", "DEX", "INT", "LCK", "VIT" }, Multi = true, Value = { "STR", "VIT" }, Callback = function(value)
    State.SelectedStats = {}
    if type(value) == "table" then
        for stat, selected in next, value do if selected == true then State.SelectedStats[tostring(stat)] = true end end
        for _, stat in next, value do if type(stat) == "string" then State.SelectedStats[stat] = true end end
    end
end })
StatsSection:Toggle({ Title = "Auto Spend Stat Points", Value = false, Callback = function(value) State.AutoStats = value == true; if value then startAutoStatsLoop() end end })

local VisualSection = PlayerSection:Section({ Title = "Visual", Icon = "eye", Side = "left" })
VisualSection:Toggle({ Title = "Fullbright", Value = false, Callback = function(value) setFullbright(value == true) end })
VisualSection:Toggle({ Title = "Right-Click Teleport", Value = false, Callback = function(value) setClickTp(value == true) end })

-- LOBBY TAB ------------------------------------------------------------------
LobbyStatusLabel = LobbySection:Paragraph({ Title = "Lobby Status", Desc = "Waiting for Auto Create" })

local QueueSection = LobbySection:Section({ Title = "Dungeon Queue", Icon = "door-open", Side = "left" })
QueueSection:Dropdown({ Title = "Dungeon", Values = DungeonOptions, Value = LobbyState.SelectedDungeon, Callback = function(value) LobbyState.SelectedDungeon = value; LobbyState.DungeonConfigured = false; LobbyState.StartRequested = false end })
QueueSection:Dropdown({ Title = "Difficulty", Values = DifficultyOptions, Value = LobbyState.SelectedDifficulty, Callback = function(value) LobbyState.SelectedDifficulty = value; LobbyState.DungeonConfigured = false; LobbyState.StartRequested = false end })
QueueSection:Toggle({ Title = "Best Unlocked", Value = LobbyState.BestUnlocked, Callback = function(value) LobbyState.BestUnlocked = value == true; if value then LobbyState.SelectedDifficulty = Gui.getBestDifficulty(LobbyState.SelectedDungeon) end end })
QueueSection:Toggle({ Title = "Solo Mode", Value = LobbyState.SoloMode, Callback = function(value) LobbyState.SoloMode = value == true; LobbyState.StartRequested = false end })
QueueSection:Toggle({ Title = "Auto Create Dungeon", Value = false, Callback = function(value) LobbyState.AutoCreate = value == true; if value then startLobbyLoop("create", "AutoCreate", "Create", 5) end end })
QueueSection:Toggle({ Title = "Auto Start Dungeon", Value = false, Callback = function(value) LobbyState.AutoStart = value == true; if value then startLobbyLoop("start", "AutoStart", "Start", 5) end end })
QueueSection:Toggle({ Title = "Auto Replay / Rejoin", Value = false, Callback = function(value) LobbyState.AutoReplay = value == true; if value then startLobbyLoop("replay", "AutoReplay", "Replay", 4) end end })
QueueSection:Toggle({ Title = "Auto Leave Dungeon", Value = false, Callback = function(value) LobbyState.AutoLeave = value == true; if value then startLobbyLoop("leave", "AutoLeave", "Leave", 3) end end })
QueueSection:Toggle({ Title = "Auto Change Dungeon", Value = false, Callback = function(value) LobbyState.AutoChangeDungeon = value == true end })
QueueSection:Toggle({ Title = "Lobby Anti-AFK", Value = false, Callback = setupAntiAfk })

local RewardsSection = LobbySection:Section({ Title = "Rewards & Claims", Icon = "gift", Side = "right" })
RewardsSection:Toggle({ Title = "Auto Claim Battle Pass Quest", Value = false, Callback = function(value) LobbyState.AutoBattlePassQuest = value == true; if value then Claims.startBattlePassLoop() end end })
RewardsSection:Toggle({ Title = "Auto Claim Battle Pass Reward", Value = false, Callback = function(value) LobbyState.AutoBattlePassReward = value == true; if value then Claims.startBattlePassLoop() end end })
RewardsSection:Toggle({ Title = "Auto Claim Lobby Rewards", Value = false, Callback = function(value) LobbyState.AutoClaimLobby = value == true; if value then Claims.startLobbyClaimsLoop() end end })
RewardsSection:Toggle({ Title = "Auto Redeem Codes", Value = false, Callback = function(value) LobbyState.AutoRedeemCodes = value == true; if value then Claims.startProgressClaimsLoop() end end })
RewardsSection:Toggle({ Title = "Auto Claim Quests & Achievements", Value = false, Callback = function(value) LobbyState.AutoClaimProgress = value == true; if value then Claims.startProgressClaimsLoop() end end })
RewardsSection:Toggle({ Title = "Auto Claim Rewards (Legacy)", Value = false, Callback = function(value) LobbyState.AutoClaim = value == true; if value then startLobbyLoop("rewards", "AutoClaim", "Claim", 4) end end })

-- INVENTORY TAB --------------------------------------------------------------
local SellingSection = InventorySection:Section({ Title = "Selling", Icon = "coins", Side = "left" })
SellingSection:Toggle({ Title = "Auto Sell", Value = false, Callback = function(value) LobbyState.AutoSell = value == true; if value then startLobbyLoop("sell", "AutoSell", "Sell", 5) end end })
SellingSection:Button({ Title = "Manage Inventory", Callback = function() Run.clickLobbyAction("Sell") end })

local EquipSection = InventorySection:Section({ Title = "Equipment", Icon = "shirt", Side = "right" })
EquipSection:Toggle({ Title = "Auto Equip Loadout", Value = false, Callback = function(value) LobbyState.AutoEquip = value == true; if value then startLobbyLoop("equip", "AutoEquip", "Equip", 5) end end })
EquipSection:Button({ Title = "Equip Visible Loadout", Callback = function() Run.clickLobbyAction("Equip") end })
EquipSection:Button({ Title = "Equip Best", Callback = function()
    task.spawn(Inv.equipBestPass)
end })

local ConsumablesSection = InventorySection:Section({ Title = "Consumables", Icon = "flask-conical", Side = "left" })
ConsumablesSection:Toggle({ Title = "Auto Use Consumables", Value = false, Callback = function(value) InventoryState.AutoUse = value == true; if value then Inv.startAutoUseLoop() end end })
ConsumablesSection:Dropdown({ Title = "Auto Use Items", Values = Inv.getConsumableNames(), Multi = true, Value = {}, Callback = function(value)
    InventoryState.SelectedItems = {}
    if type(value) == "table" then
        for name, selected in next, value do if selected == true then InventoryState.SelectedItems[tostring(name)] = true end end
        for _, name in next, value do if type(name) == "string" then InventoryState.SelectedItems[name] = true end end
    end
end })

-- CRAFTING TAB ---------------------------------------------------------------
CraftStatusLabel = CraftSection:Paragraph({ Title = "Craft Status", Desc = "Auto craft: idle" })

local RecipesSection = CraftSection:Section({ Title = "Recipes", Icon = "list-checks", Side = "left" })
RecipesSection:Dropdown({ Title = "Recipes", Values = getRecipeIds(), Multi = true, Value = {}, Callback = function(value)
    CraftState.SelectedRecipes = {}
    if type(value) == "table" then
        for recipe, selected in next, value do if selected == true then CraftState.SelectedRecipes[tostring(recipe)] = true end end
        for _, recipe in next, value do if type(recipe) == "string" then CraftState.SelectedRecipes[recipe] = true end end
    end
end })
RecipesSection:Toggle({ Title = "Auto Craft", Value = false, Callback = function(value) CraftState.AutoCraft = value == true; if value then startCraftLoop() end end })
RecipesSection:Button({ Title = "Craft Selected Once", Callback = function()
    task.spawn(craftSelectedOnce)
end })

-- FORGE TAB ------------------------------------------------------------------
do
    -- Item list follows what is actually worn right now so the dropdown only
    -- shows real pieces; every equipped item is pre-selected.
    local forgeItemValues, forgeItemDefaults = {}, {}
    local equipment = Forge.getEquippedItems()
    if type(equipment) == "table" then
        local slots = {}
        for slot in next, equipment do table.insert(slots, tostring(slot)) end
        table.sort(slots)
        for _, slot in next, slots do
            local item = equipment[slot]
            local label = slot .. ": " .. tostring(item and item.ItemId or "?")
            forgeItemValues[#forgeItemValues + 1] = label
            forgeItemDefaults[#forgeItemDefaults + 1] = label
        end
    end

    ForgeStatusLabel = ForgeSection:Paragraph({ Title = "Forge Status", Desc = "Auto forge: idle" })

    local ForgeMain = ForgeSection:Section({ Title = "Forge", Icon = "hammer", Side = "left" })
    ForgeMain:Toggle({ Title = "Auto Forge Equipped", Value = false, Callback = function(value) ForgeState.AutoForge = value == true; if value then Forge.startForgeLoop() end end })
    ForgeMain:Dropdown({ Title = "Items (equipped)", Values = forgeItemValues, Multi = true, Value = forgeItemDefaults, Callback = function(value)
        ForgeState.SelectedItems = {}
        if type(value) == "table" then
            for label, selected in next, value do if selected == true then ForgeState.SelectedItems[tostring(label)] = true end end
            for _, label in next, value do if type(label) == "string" then ForgeState.SelectedItems[label] = true end end
        end
    end })
    ForgeMain:Slider({ Title = "Target Forge Level", Value = { Min = 1, Max = 20, Default = ForgeState.TargetLevel }, Step = 1, Callback = function(value) ForgeState.TargetLevel = tonumber(value) or ForgeState.TargetLevel end })
    ForgeMain:Button({ Title = "Forge Equipped Once", Callback = function()
        task.spawn(function()
            local service = Data.getKnitService("ForgeService")
            if not service then Forge.setForgeStatus("Forge: ForgeService unavailable") return end
            Forge.forgePass(service)
        end)
    end })

    local ForgeQuality = ForgeSection:Section({ Title = "Quality & Budget", Icon = "shield", Side = "right" })
    ForgeQuality:Slider({ Title = "Min Success %", Value = { Min = 5, Max = 100, Default = ForgeState.MinSuccess }, Step = 5, Callback = function(value) ForgeState.MinSuccess = tonumber(value) or ForgeState.MinSuccess end })
    ForgeQuality:Slider({ Title = "Coin Reserve", Value = { Min = 0, Max = 100000, Default = ForgeState.CoinReserve }, Step = 1000, Callback = function(value) ForgeState.CoinReserve = tonumber(value) or ForgeState.CoinReserve end })
    ForgeQuality:Toggle({ Title = "Auto Purity Stone", Value = ForgeState.AutoEnhance, Callback = function(value) ForgeState.AutoEnhance = value == true end })
    ForgeQuality:Slider({ Title = "Purity From Level", Value = { Min = 1, Max = 20, Default = ForgeState.EnhanceFromLevel }, Step = 1, Callback = function(value) ForgeState.EnhanceFromLevel = tonumber(value) or ForgeState.EnhanceFromLevel end })
    ForgeQuality:Toggle({ Title = "Auto Protection Scroll", Value = ForgeState.AutoProtect, Callback = function(value) ForgeState.AutoProtect = value == true end })
    ForgeQuality:Slider({ Title = "Protect From Level", Value = { Min = 1, Max = 20, Default = ForgeState.ProtectFromLevel }, Step = 1, Callback = function(value) ForgeState.ProtectFromLevel = tonumber(value) or ForgeState.ProtectFromLevel end })

    local ForgeReforge = ForgeSection:Section({ Title = "Reforge", Icon = "refresh-cw", Side = "right" })
    ForgeReforge:Dropdown({ Title = "Reforge Quality", Values = { "Standard", "High" }, Value = ForgeState.ReforgeQuality, Callback = function(value) ForgeState.ReforgeQuality = value == "High" and "High" or "Standard" end })
    ForgeReforge:Slider({ Title = "Rerolls Per Affix", Value = { Min = 1, Max = 10, Default = ForgeState.ReforgeCount }, Step = 1, Callback = function(value) ForgeState.ReforgeCount = tonumber(value) or ForgeState.ReforgeCount end })
    ForgeReforge:Toggle({ Title = "Auto Reforge New Affix", Value = ForgeState.AutoReforge, Callback = function(value) ForgeState.AutoReforge = value == true end })
    ForgeReforge:Button({ Title = "Reforge Affixes Now", Callback = function()
        task.spawn(function()
            local service = Data.getKnitService("ForgeService")
            if not service then Forge.setForgeStatus("Forge: ForgeService unavailable") return end
            local equipment = Forge.getEquippedItems()
            if not equipment then Forge.setForgeStatus("Forge: player data unavailable") return end
            for slot, item in next, equipment do
                local label = tostring(slot) .. ": " .. tostring(item and item.ItemId or "?")
                if running and ForgeState.SelectedItems[label] and item and item.GUID then
                    Forge.reforgeItem(service, tostring(slot), item.GUID, 1)
                    task.wait(0.25)
                end
            end
        end)
    end })
end

-- CLASSES TAB ----------------------------------------------------------------
do
    -- Slot dropdown mirrors the slots the account actually has; it stays 1-4
    -- when the summoning service is unreachable at UI build time.
    local rerollSlotValues = { "1", "2", "3", "4" }
    local rerollDefaultSlots = { "1" }
    local summonService = Data.getKnitService("SummoningService")
    local slotData = summonService and select(1, callKnitData(summonService, "GetSlotData"))
    if type(slotData) == "table" and type(slotData.Slots) == "table" then
        local total = 0
        for _ in next, slotData.Slots do total += 1 end
        if total > 0 then
            rerollSlotValues = {}
            for i = 1, total do rerollSlotValues[i] = tostring(i) end
        end
        rerollDefaultSlots = {}
        for i = 1, math.min(1 + (tonumber(slotData.CoinSlotsPurchased) or 0), total) do
            rerollDefaultSlots[#rerollDefaultSlots + 1] = tostring(i)
        end
    end

    RerollStatusLabel = ClassesSection:Paragraph({ Title = "Reroll Status", Desc = "Auto reroll: idle" })

    local RerollSection = ClassesSection:Section({ Title = "Auto Reroll", Icon = "shuffle", Side = "left" })
    RerollSection:Toggle({ Title = "Auto Reroll Class", Value = false, Callback = function(value) RerollState.AutoReroll = value == true; if value then Reroll.startRerollLoop() end end })
    RerollSection:Dropdown({ Title = "Spin Type", Values = { "Normal", "Lucky" }, Value = RerollState.SpinType, Callback = function(value) RerollState.SpinType = value == "Lucky" and "Lucky" or "Normal" end })
    RerollSection:Dropdown({ Title = "Slots", Values = rerollSlotValues, Multi = true, Value = rerollDefaultSlots, Callback = function(value)
        RerollState.SelectedSlots = {}
        if type(value) == "table" then
            for slot, selected in next, value do if selected == true then RerollState.SelectedSlots[tostring(slot)] = true end end
            for _, slot in next, value do if type(slot) == "string" then RerollState.SelectedSlots[slot] = true end end
        end
    end })
    RerollSection:Toggle({ Title = "Auto Unlock Next Slot (Coins Only)", Value = false, Callback = function(value) RerollState.AutoUnlockSlot = value == true; RerollState.UnlockAttempted = not RerollState.AutoUnlockSlot end })
    RerollSection:Toggle({ Title = "Return to Original Slot", Value = RerollState.ReturnToOriginalSlot, Callback = function(value) RerollState.ReturnToOriginalSlot = value == true end })
    RerollSection:Button({ Title = "Spin Selected Slots Once", Callback = Reroll.runRerollOnce })
end

-- Initialize the shared CC UI base tabs last. Server controls are appended to
-- the existing Utility section, while the unload action stays in Settings.
local function addServerTools(utilitySection)
    if type(utilitySection) ~= "table" then return end
    ServerInfoLabel = utilitySection:Paragraph({ Title = "Live Status", Desc = "Players: ? | Ping: ?" })
    utilitySection:Button({ Title = "Copy JobId", Callback = function()
        if Srv.copyToClipboard(game.JobId) then
            WindUI:Notify({ Title = "Copy JobId", Content = "JobId copied.", Duration = 3 })
        else
            WindUI:Notify({ Title = "Copy JobId", Content = "Clipboard API unavailable. JobId: " .. game.JobId, Duration = 8 })
        end
    end })
    utilitySection:Slider({ Title = "Min Players", Value = { Min = 1, Max = 50, Default = 1 }, Step = 1, Callback = function(value) ServerState.MinPlayers = tonumber(value) or 1 end })
    utilitySection:Slider({ Title = "Max Players", Value = { Min = 1, Max = 50, Default = 50 }, Step = 1, Callback = function(value) ServerState.MaxPlayers = tonumber(value) or 50 end })
    utilitySection:Button({ Title = "Server Hop (Filters)", Callback = function()
        Srv.hopWithFilters(ServerState.MinPlayers, ServerState.MaxPlayers)
    end })
    utilitySection:Button({ Title = "Rejoin Current Server", Callback = function() pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer) end) end })
    utilitySection:Button({ Title = "Server Hop (Random)", Callback = function() pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end) end })
    Srv.startServerInfoLoop()
end

local function addUnloadButton(settingsTab)
    if type(settingsTab) ~= "table" then return end
    local uiSettingSection
    if type(settingsTab.Elements) == "table" then
        for _, element in next, settingsTab.Elements do
            if type(element) == "table" and element.Title == "Ui setting" then
                uiSettingSection = element
                break
            end
        end
    end
    (uiSettingSection or settingsTab):Button({ Title = "Unload", Callback = unloadScript })
end

if type(Window.InitBaseTabs) == "function" then
    local baseTabs = {}
    local originalTab = Window.Tab
    local okTabs, tabError = pcall(function()
        Window.Tab = function(windowSelf, tabOptions)
            local tab = originalTab(windowSelf, tabOptions)
            baseTabs[tostring(tabOptions and tabOptions.Title or "")] = tab
            return tab
        end
        Window:InitBaseTabs()
    end)
    Window.Tab = originalTab
    if okTabs then
        local miscTab = baseTabs.Misc
        local settingsTab = baseTabs.Settings
        local utilitySection
        if type(miscTab) == "table" and type(miscTab.Elements) == "table" then
            for _, element in next, miscTab.Elements do
                if type(element) == "table" and element.Title == "Utility" then
                    utilitySection = element
                    break
                end
            end
        end
        addServerTools(utilitySection or miscTab)
        addUnloadButton(settingsTab)
    else
        warn("CC UI base tabs failed: " .. tostring(tabError))
    end
else
    local utilityTab = createTab("Utility", "wrench")
    addServerTools(utilityTab:Section({ Title = "Utility", Icon = "wrench", Side = "left" }) or utilityTab)
    local fallbackSettings = createTab("Settings", "settings")
    addUnloadButton(fallbackSettings)
end

local configApplied = Config.LoadConfig()
Config.flushConfig()

WindUI:Notify({ Title = "Dungeon Lootr", Content = "Ready. Enable Auto Farm inside the dungeon." .. (configApplied > 0 and (" Config restored: " .. configApplied .. " settings.") or ""), Duration = 5 })
