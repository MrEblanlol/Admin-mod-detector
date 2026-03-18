-- Modern Ultra Moderator & Staff Detector (LocalScript)
-- Put in StarterPlayerScripts
-- Features:
--  - Detects local moderators and Roblox staff via many heuristics
--  - HUI/CoreGui parent (if available) with fallback to PlayerGui
--  - Draggable modern GUI (position saved between respawns)
--  - Toast notifications + sound
--  - Highlight on detected players (Highlight + Billboard name/reason)
--  - Live history with export to CSV
--  - Debounced notifications and periodic scanning
--  - Safe: only client-side detection (no server writes)

-- ==== Services & setup ====
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- ==== CONFIG (настройки) ====
local CONFIG = {
    scanInterval = 1.0,                      -- как часто делать полный скан (сек)
    notificationDuration = 6,                -- длительность тоста (сек)
    animateTime = 0.18,                      -- время анимаций
    saveGuiPosAttr = "UltraDetector_GUI_Pos",-- атрибут игрока для сохранения позиции
    enableSound = true,
    soundId = "rbxassetid://184352961",      -- звук уведомления
    showMultipleReasons = true,
    debounceSec = 12,                        -- минимальное время между нотификациями для одного игрока
    highlightColor = Color3.fromRGB(255,90,90),  -- цвет подсветки для Roblox staff
    highlightColorLocal = Color3.fromRGB(255,200,80), -- цвет для локальных модеров
    -- Group IDs commonly used for Roblox staff/testers from earlier samples:
    robloxStaffGroupIDs = {1200769, 3055661, 14593111, 12513722, 10279336, 6821794, 3253689},
    -- accessory patterns to detect QA hats etc.
    accessoryPatterns = {"testing", "valiant", "thoroughly-tested", "qa", "tester"},
    attributeKeys = {"IsModerator","IsAdmin","Admin","Staff","IsStaff"},
    valueNames = {"IsModerator","IsAdmin","Admin","Staff"},
    -- Optional localIdList (nil or table {[id]=true})
    localIdList = nil,
    -- Optional remote url returning JSON array of numeric IDs, if set script will fetch periodically
    remoteModsUrl = nil,
    remoteFetchInterval = 60, -- seconds
}

-- ==== internal state ====
local alerted = {}       -- userId -> {reasons = {...}, lastNotified = os.time()}
local remoteMods = {}    -- userId -> true
local highlights = {}    -- userId -> {highlight = Instance, billboard = Instance}
local scanning = false
local scanningEnabled = true
local lastRemoteFetch = 0

-- ==== utility functions ====
local function safeGetRank(p, gid)
    local ok, v = pcall(function() return p:GetRankInGroup(gid) end)
    if ok and type(v) == "number" then return v end
    return nil
end

local function lower(s) return (type(s) == "string") and s:lower() or "" end
local function now() return os.time() end

-- fetch remote list (non-blocking)
local function fetchRemoteMods()
    if not CONFIG.remoteModsUrl then return end
    spawn(function()
        local ok, body = pcall(function()
            return game:HttpGet(CONFIG.remoteModsUrl, true)
        end)
        if not ok or not body then return end
        local success, data = pcall(function() return HttpService:JSONDecode(body) end)
        if success and type(data) == "table" then
            local newmap = {}
            for _, id in ipairs(data) do
                if type(id) == "number" then newmap[id] = true end
            end
            remoteMods = newmap
            lastRemoteFetch = tick()
        end
    end)
end

-- combine reasons to readable label (short)
local function reasonsLabel(reasons)
    if not reasons or #reasons == 0 then return "Detected" end
    if CONFIG.showMultipleReasons and #reasons > 1 then
        return table.concat(reasons, "; ")
    else
        return reasons[1]
    end
end

-- ==== DETECTION LOGIC (client-side heuristics) ====
local function detectForPlayer(p)
    local reasons = {}

    if not p or not p.UserId then return reasons end

    -- 1) local ID list
    if CONFIG.localIdList and CONFIG.localIdList[p.UserId] then
        table.insert(reasons, "UserId in local list")
    end

    -- 2) remote list
    if CONFIG.remoteModsUrl and remoteMods[p.UserId] then
        table.insert(reasons, "UserId in remote list")
    end

    -- 3) check if game owner
    if p.UserId == game.CreatorId then
        table.insert(reasons, "Game Creator")
    end

    -- 4) check known Roblox staff groups
    for _, gid in ipairs(CONFIG.robloxStaffGroupIDs) do
        local rank = safeGetRank(p, gid)
        if rank and rank >= 1 then
            table.insert(reasons, ("Roblox Group %d (rank %d)"):format(gid, rank))
        end
    end

    -- 5) attributes
    for _, key in ipairs(CONFIG.attributeKeys) do
        local ok, val = pcall(function() return p:GetAttribute(key) end)
        if ok and val ~= nil then
            if type(val) == "boolean" and val == true then
                table.insert(reasons, ("Attribute %s (true)"):format(key))
            else
                table.insert(reasons, ("Attribute %s (%s)"):format(key, tostring(val)))
            end
        end
    end

    -- 6) Value objects under Player or Character
    for _, name in ipairs(CONFIG.valueNames) do
        local v = p:FindFirstChild(name)
        if v and (v:IsA("BoolValue") or v:IsA("StringValue") or v:IsA("IntValue") or v:IsA("NumberValue") or v:IsA("ObjectValue")) then
            table.insert(reasons, ("Value %s"):format(name))
        end
        if p.Character then
            local cv = p.Character:FindFirstChild(name)
            if cv and (cv:IsA("BoolValue") or cv:IsA("StringValue") or cv:IsA("IntValue") or cv:IsA("NumberValue") or cv:IsA("ObjectValue")) then
                table.insert(reasons, ("CharValue %s"):format(name))
            end
        end
    end

    -- 7) accessories (QA hat detection etc.)
    if p.Character then
        for _, obj in ipairs(p.Character:GetChildren()) do
            if obj:IsA("Accessory") then
                local n = lower(obj.Name)
                for _, pat in ipairs(CONFIG.accessoryPatterns) do
                    if n:find(pat) then
                        table.insert(reasons, ("Accessory: %s"):format(obj.Name))
                        break
                    end
                end
            end
        end
    end

    -- 8) name heuristics
    local nlower = lower(p.Name or p.DisplayName or "")
    if nlower:find("admin") or nlower:find("moder") or nlower:find("staff") then
        table.insert(reasons, "Name looks like admin/mod")
    end

    -- unique reasons
    local uniq = {}
    local out = {}
    for _, r in ipairs(reasons) do
        if not uniq[r] then uniq[r] = true; table.insert(out, r) end
    end
    return out
end

-- ==== HIGHLIGHT & BILLBOARD ====
local function createHighlightForPlayer(p, reason, isRobloxStaff)
    -- cleanup existing
    if highlights[p.UserId] then
        local old = highlights[p.UserId]
        if old.highlight and old.highlight.Parent then old.highlight:Destroy() end
        if old.billboard and old.billboard.Parent then old.billboard:Destroy() end
        highlights[p.UserId] = nil
    end

    if not p.Character then return end
    local char = p.Character
    -- create Highlight
    local highlight = Instance.new("Highlight")
    highlight.Adornee = char
    highlight.Parent = workspace
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillTransparency = 0.6
    highlight.OutlineTransparency = 0
    highlight.OutlineColor = Color3.fromRGB(255,255,255)
    highlight.FillColor = isRobloxStaff and CONFIG.highlightColor or CONFIG.highlightColorLocal

    -- create billboard with name + reason
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "DetectorBillboard"
    billboard.Adornee = char:FindFirstChild("Head") or char:FindFirstChildWhichIsA("BasePart")
    billboard.Size = UDim2.new(0,220,0,30)
    billboard.StudsOffset = Vector3.new(0,2.6,0)
    billboard.AlwaysOnTop = true
    billboard.Parent = char

    local frame = Instance.new("Frame", billboard)
    frame.Size = UDim2.new(1,0,1,0)
    frame.BackgroundTransparency = 0.12
    frame.BackgroundColor3 = Color3.fromRGB(20,20,20)
    frame.BorderSizePixel = 0
    frame.ClipsDescendants = true
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0,6)

    local nameLabel = Instance.new("TextLabel", frame)
    nameLabel.Size = UDim2.new(0.6, -8, 1, -8)
    nameLabel.Position = UDim2.new(0,8,0,4)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 14
    nameLabel.TextColor3 = Color3.fromRGB(255,255,255)
    nameLabel.Text = p.Name

    local reasonLabel = Instance.new("TextLabel", frame)
    reasonLabel.Size = UDim2.new(0.4, -8, 1, -8)
    reasonLabel.Position = UDim2.new(0.6, 8, 0, 4)
    reasonLabel.BackgroundTransparency = 1
    reasonLabel.Font = Enum.Font.Gotham
    reasonLabel.TextSize = 12
    reasonLabel.TextColor3 = Color3.fromRGB(220,220,220)
    reasonLabel.Text = reason

    highlights[p.UserId] = { highlight = highlight, billboard = billboard }
end

local function removeHighlightForPlayer(p)
    local rec = highlights[p.UserId]
    if rec then
        if rec.highlight and rec.highlight.Parent then rec.highlight:Destroy() end
        if rec.billboard and rec.billboard.Parent then rec.billboard:Destroy() end
        highlights[p.UserId] = nil
    end
end

-- ==== GUI BUILD (HUI fallback to PlayerGui) ====
local function getHUIParent()
    if syn and syn.gethui then
        return syn.gethui()
    elseif gethui then
        return gethui()
    else
        return playerGui
    end
end

local HUI = getHUIParent()

local gui = Instance.new("ScreenGui")
gui.Name = "UltraModDetector"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = HUI

-- main frame
local main = Instance.new("Frame", gui)
main.Name = "Main"
main.Size = UDim2.new(0,480,0,72)
-- restore saved pos
local saved = localPlayer:GetAttribute(CONFIG.saveGuiPosAttr)
if saved and type(saved) == "string" then
    local x,y = saved:match("([^,]+),([^,]+)")
    local xn, yn = tonumber(x), tonumber(y)
    if xn and yn then main.Position = UDim2.new(0, xn, 0, yn) else main.Position = UDim2.new(0.5, -240, 0.06, 0) end
else
    main.Position = UDim2.new(0.5, -240, 0.06, 0)
end
main.AnchorPoint = Vector2.new(0,0)
main.BackgroundColor3 = Color3.fromRGB(20,20,20)
main.BorderSizePixel = 0
main.ZIndex = 50
local mainCorner = Instance.new("UICorner", main); mainCorner.CornerRadius = UDim.new(0,12)

-- header
local header = Instance.new("Frame", main)
header.Size = UDim2.new(1,0,0,40)
header.BackgroundTransparency = 1

local title = Instance.new("TextLabel", header)
title.Size = UDim2.new(0.6, -12, 1, 0); title.Position = UDim2.new(0,12,0,0)
title.BackgroundTransparency = 1; title.Font = Enum.Font.GothamBold; title.TextSize = 16
title.TextColor3 = Color3.fromRGB(245,245,245); title.Text = "🛡 Ultra Moderator Detector"

local btnContainer = Instance.new("Frame", header)
btnContainer.Size = UDim2.new(0.4, -12,1,0); btnContainer.Position = UDim2.new(0.6,12,0,0); btnContainer.BackgroundTransparency = 1

local function makeBtn(text)
    local b = Instance.new("TextButton"); b.Size = UDim2.new(0,96,0,28); b.BackgroundColor3 = Color3.fromRGB(36,36,36)
    b.BorderSizePixel = 0; Instance.new("UICorner",b).CornerRadius = UDim.new(0,6)
    b.Font = Enum.Font.Gotham; b.TextSize = 13; b.Text = text; b.TextColor3 = Color3.fromRGB(230,230,230)
    return b
end

local refreshBtn = makeBtn("Refresh"); refreshBtn.Parent = btnContainer; refreshBtn.Position = UDim2.new(1,-104,0.5,-14)
local toggleBtn = makeBtn("Scan: ON"); toggleBtn.Parent = btnContainer; toggleBtn.Position = UDim2.new(1,-212,0.5,-14)
local historyBtn = makeBtn("History"); historyBtn.Parent = btnContainer; historyBtn.Position = UDim2.new(1,-320,0.5,-14)

local statusBar = Instance.new("Frame", main); statusBar.Size = UDim2.new(1, -16, 0, 28); statusBar.Position = UDim2.new(0,8,0,44); statusBar.BackgroundTransparency = 0.08
Instance.new("UICorner", statusBar).CornerRadius = UDim.new(0,8)
local statusLabel = Instance.new("TextLabel", statusBar); statusLabel.Size = UDim2.new(1, -12, 1, 0); statusLabel.Position = UDim2.new(0,6,0,0)
statusLabel.BackgroundTransparency = 1; statusLabel.Font = Enum.Font.Gotham; statusLabel.TextSize = 13
statusLabel.TextColor3 = Color3.fromRGB(200,200,200)
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Text = "Status: idle • scanning every "..tostring(CONFIG.scanInterval).."s"

-- history window builder
local historyWindow
local function openHistory()
    if historyWindow and historyWindow.Parent then return end
    historyWindow = Instance.new("Frame", gui)
    historyWindow.Size = UDim2.new(0,760,0,440)
    historyWindow.Position = UDim2.new(0.5, -380, 0.12, 0)
    historyWindow.BackgroundColor3 = Color3.fromRGB(18,18,18)
    historyWindow.BorderSizePixel = 0
    historyWindow.ZIndex = 60
    Instance.new("UICorner", historyWindow).CornerRadius = UDim.new(0,10)

    local top = Instance.new("Frame", historyWindow); top.Size = UDim2.new(1,0,0,36); top.BackgroundTransparency = 1
    local title = Instance.new("TextLabel", top); title.Size = UDim2.new(1,-12,1,0); title.Position = UDim2.new(0,8,0,0)
    title.BackgroundTransparency = 1; title.Font = Enum.Font.GothamBold; title.TextSize = 15; title.TextColor3 = Color3.fromRGB(240,240,240)
    title.Text = "Detection History"

    local closeBtn = Instance.new("TextButton", top); closeBtn.Size = UDim2.new(0,80,0,26); closeBtn.Position = UDim2.new(1,-92,0.5,-13)
    closeBtn.Text = "Close"; closeBtn.Font = Enum.Font.Gotham; closeBtn.TextSize = 12; closeBtn.BackgroundColor3 = Color3.fromRGB(36,36,36); closeBtn.TextColor3 = Color3.fromRGB(230,230,230)
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0,6)

    local search = Instance.new("TextBox", historyWindow); search.Size = UDim2.new(0,300,0,28); search.Position = UDim2.new(0,12,0,44)
    search.PlaceholderText = "Search name / reason..."; search.BackgroundColor3 = Color3.fromRGB(32,32,32); search.TextColor3 = Color3.fromRGB(230,230,230)
    Instance.new("UICorner", search).CornerRadius = UDim.new(0,6)

    local exportBtn = makeBtn("Export CSV"); exportBtn.Parent = historyWindow; exportBtn.Position = UDim2.new(1,-124,0,44)

    local listFrame = Instance.new("ScrollingFrame", historyWindow)
    listFrame.Size = UDim2.new(1,-24,1,-96); listFrame.Position = UDim2.new(0,12,0,84)
    listFrame.CanvasSize = UDim2.new(0,0,0,0); listFrame.BackgroundTransparency = 1; listFrame.ScrollBarThickness = 8
    local layout = Instance.new("UIListLayout", listFrame); layout.Padding = UDim.new(0,6)
    local padding = Instance.new("UIPadding", listFrame); padding.PaddingTop = UDim.new(0,8); padding.PaddingLeft = UDim.new(0,6)

    local function populate(filter)
        for _,c in ipairs(listFrame:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
        local entries = {}
        for uid, rec in pairs(alerted) do entries[#entries+1] = {uid=uid, rec=rec} end
        table.sort(entries, function(a,b) return (a.rec.lastNotified or 0) > (b.rec.lastNotified or 0) end)
        for _, e in ipairs(entries) do
            local name = "Unknown"
            local ok, pl = pcall(function() return Players:GetPlayerByUserId(e.uid) end)
            if ok and pl and pl.Name then name = pl.Name end
            -- frame
            local row = Instance.new("Frame", listFrame); row.Size = UDim2.new(1,-12,0,48); row.BackgroundColor3 = Color3.fromRGB(28,28,28)
            Instance.new("UICorner", row).CornerRadius = UDim.new(0,8)
            local nlabel = Instance.new("TextLabel", row); nlabel.Size = UDim2.new(0.4,0,1,0); nlabel.Position = UDim2.new(0,8,0,0)
            nlabel.BackgroundTransparency = 1; nlabel.Font = Enum.Font.GothamSemibold; nlabel.TextSize = 14; nlabel.TextColor3 = Color3.fromRGB(240,240,240)
            nlabel.Text = name.." ("..tostring(e.uid)..")"
            local rlabel = Instance.new("TextLabel", row); rlabel.Size = UDim2.new(0.5,0,1,0); rlabel.Position = UDim2.new(0.4,8,0,0)
            rlabel.BackgroundTransparency = 1; rlabel.Font = Enum.Font.Gotham; rlabel.TextSize = 12; rlabel.TextColor3 = Color3.fromRGB(200,200,200)
            rlabel.TextWrapped = true; rlabel.Text = table.concat(e.rec.reasons, "; ")
            local tlabel = Instance.new("TextLabel", row); tlabel.Size = UDim2.new(0.1, -16,1,0); tlabel.Position = UDim2.new(0.9,8,0,0)
            tlabel.BackgroundTransparency = 1; tlabel.Font = Enum.Font.Gotham; tlabel.TextSize = 12; tlabel.TextColor3 = Color3.fromRGB(170,170,170)
            tlabel.Text = os.date("%H:%M:%S", e.rec.lastNotified or os.time())
        end
        -- update canvas (small trick)
        local totalHeight = 0
        for _, child in ipairs(listFrame:GetChildren()) do if child:IsA("Frame") then totalHeight = totalHeight + child.AbsoluteSize.Y + 6 end end
        listFrame.CanvasSize = UDim2.new(0,0,0, math.max(1, totalHeight) )
    end

    exportBtn.MouseButton1Click:Connect(function()
        local csv = "username,userId,reasons,timestamp\n"
        for uid, rec in pairs(alerted) do
            local name = "Unknown"
            local ok, pl = pcall(function() return Players:GetPlayerByUserId(uid) end)
            if ok and pl and pl.Name then name = pl.Name end
            csv = csv .. string.format('"%s",%d,"%s","%s"\n', name, uid, table.concat(rec.reasons, "; "), os.date("%Y-%m-%d %H:%M:%S", rec.lastNotified or os.time()))
        end
        pcall(function() setclipboard(csv) end)
    end)

    search:GetPropertyChangedSignal("Text"):Connect(function()
        populate(search.Text)
    end)

    closeBtn.MouseButton1Click:Connect(function() historyWindow:Destroy(); historyWindow = nil end)
    populate()
end

-- ==== TOASTS ====
local toastsFolder = Instance.new("Folder", gui); toastsFolder.Name = "Toasts"
local function playNotifySound()
    if CONFIG.enableSound and CONFIG.soundId then
        pcall(function()
            local s = Instance.new("Sound", main)
            s.SoundId = CONFIG.soundId
            s.Volume = 0.7
            s:Play()
            task.delay(2, function() pcall(function() s:Destroy() end) end)
        end)
    end
end
local function showToast(text)
    local toast = Instance.new("Frame")
    toast.BackgroundColor3 = Color3.fromRGB(36,36,36)
    toast.Size = UDim2.new(0,0,0,0)
    toast.AnchorPoint = Vector2.new(0.5,0)
    toast.Position = UDim2.new(0.5, 0, 0.18, 0)
    toast.ZIndex = 60
    toast.Parent = toastsFolder
    Instance.new("UICorner", toast).CornerRadius = UDim.new(0,8)
    local lbl = Instance.new("TextLabel", toast)
    lbl.Size = UDim2.new(1,-12,1,-12); lbl.Position = UDim2.new(0,6,0,6)
    lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.Gotham; lbl.TextSize = 14; lbl.TextColor3 = Color3.fromRGB(240,240,240)
    lbl.TextWrapped = true; lbl.Text = text

    -- animate in
    TweenService:Create(toast, TweenInfo.new(CONFIG.animateTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = UDim2.new(0,420,0,56)}):Play()
    playNotifySound()

    spawn(function()
        task.wait(CONFIG.notificationDuration)
        pcall(function() TweenService:Create(toast, TweenInfo.new(CONFIG.animateTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = UDim2.new(0,420,0,0)}):Play() end)
        task.wait(CONFIG.animateTime)
        if toast and toast.Parent then toast:Destroy() end
    end)
end

-- ==== EVALUATION & ACTIONS ====
local function handleDetected(player, reasons)
    if not player then return end
    local uid = player.UserId
    if not uid or uid <= 0 then return end

    -- debounce
    local prev = alerted[uid]
    if prev and (tick() - (prev.lastNotified or 0) < CONFIG.debounceSec) then
        return
    end

    -- determine if Roblox staff (any group match or accessory matching staff patterns)
    local isRobloxStaff = false
    for _, gid in ipairs(CONFIG.robloxStaffGroupIDs) do
        local rank = safeGetRank(player, gid)
        if rank and rank >= 1 then isRobloxStaff = true; break end
    end
    -- also treat Creator as top
    if player.UserId == game.CreatorId then isRobloxStaff = true end

    -- build message
    local label = reasonsLabel(reasons)
    local msgType = isRobloxStaff and "Roblox staff" or "Local moderator"
    local toastText = string.format("%s joined — %s (%s)", player.Name, msgType, label)
    showToast(toastText)

    -- add to history
    alerted[uid] = { reasons = reasons, lastNotified = now() }

    -- highlight & billboard
    createHighlightForPlayer(player, label, isRobloxStaff)

    -- log into status bar (simple)
    statusLabel.Text = ("Detected: %s — %s"):format(player.Name, label)
end

local function evaluatePlayerAndMaybeNotify(player)
    local ok, reasons = pcall(function() return detectForPlayer(player) end)
    if not ok then return end
    if not reasons or #reasons == 0 then
        removeHighlightForPlayer(player)
        alerted[player.UserId] = nil
        return
    end
    handleDetected(player, reasons)
end

-- ==== watchers & loops ====
local function watchPlayer(p)
    p.CharacterAdded:Connect(function() task.wait(0.35); evaluatePlayerAndMaybeNotify(p) end)
    if p.Character then
        -- watch accessory changes
        p.Character.ChildAdded:Connect(function() evaluatePlayerAndMaybeNotify(p) end)
        p.Character.ChildRemoved:Connect(function() evaluatePlayerAndMaybeNotify(p) end)
    end
    -- attribute changes
    if p.GetAttributeChangedSignal then
        p:GetAttributeChangedSignal():Connect(function() evaluatePlayerAndMaybeNotify(p) end)
    end
    p.Changed:Connect(function() evaluatePlayerAndMaybeNotify(p) end)
end

-- GUI interactions
refreshBtn.MouseButton1Click:Connect(function()
    fetchRemoteMods()
    fullScan()
end)
toggleBtn.MouseButton1Click:Connect(function()
    scanningEnabled = not scanningEnabled
    toggleBtn.Text = scanningEnabled and "Scan: ON" or "Scan: OFF"
    statusLabel.Text = "Status: "..(scanningEnabled and "scanning" or "paused").." • scanning every "..tostring(CONFIG.scanInterval).."s"
end)
historyBtn.MouseButton1Click:Connect(function() openHistory() end)

-- drag & save
do
    local dragging, dragInput, dragStart, startPos = false, nil, nil, nil
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    -- save absolute position
                    pcall(function()
                        localPlayer:SetAttribute(CONFIG.saveGuiPosAttr, tostring(main.AbsolutePosition.X)..","..tostring(main.AbsolutePosition.Y))
                    end)
                end
            end)
        end
    end)
    header.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement then
            dragInput = input
        end
    end)
    RunService.RenderStepped:Connect(function()
        if dragging and dragInput and dragStart and startPos then
            local delta = dragInput.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- full scan function
function fullScan()
    if scanning then return end
    scanning = true
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer then
            pcall(function() evaluatePlayerAndMaybeNotify(p) end)
        end
    end
    scanning = false
end

-- initialize watchers
for _, p in ipairs(Players:GetPlayers()) do
    watchPlayer(p)
    pcall(function() evaluatePlayerAndMaybeNotify(p) end)
end
Players.PlayerAdded:Connect(function(p) watchPlayer(p); task.wait(0.35); evaluatePlayerAndMaybeNotify(p) end)
Players.PlayerRemoving:Connect(function(p) removeHighlightForPlayer(p); alerted[p.UserId] = nil end)

-- periodic loops
spawn(function()
    fetchRemoteMods()
    while true do
        if scanningEnabled then fullScan() end
        -- periodic remote fetch
        if CONFIG.remoteModsUrl and tick() - lastRemoteFetch > CONFIG.remoteFetchInterval then fetchRemoteMods() end
        task.wait(CONFIG.scanInterval)
    end
end)

-- convenience: double-click title to open history quickly
do
    local lastClick = 0
    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            local t = tick()
            if t - lastClick < 0.35 then
                openHistory()
            end
            lastClick = t
        end
    end)
end

-- initial status
statusLabel.Text = "Status: running • scanning every "..tostring(CONFIG.scanInterval).."s"
