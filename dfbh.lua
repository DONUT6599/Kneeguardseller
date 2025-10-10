-- // Configurable globals
local SelectedSlot = _G.Player or 1     -- set _G.Player before loadstring
local AutoJoinEnabled = _G.AutoJoin or false

-- // Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportEvent = ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("TeleportEvent")

-- // Functions
local function TryJoinTeleporter(teleporterIndex, playerSlot)
    TeleportEvent:FireServer("Add", teleporterIndex)
    task.wait(0.5)
    TeleportEvent:FireServer("Chosen", nil, playerSlot)
    print(string.format("✅ Joined Teleporter %d | Slot %d", teleporterIndex, playerSlot))
end

local function CheckTeleporters(autoJoin, playerSlot)
    for i = 1, 3 do
        local tele = workspace:FindFirstChild("Teleporter" .. i)
        if tele and tele:FindFirstChild("BillboardHolder") then
            local gui = tele.BillboardHolder:FindFirstChild("BillboardGui")
            local playersObj = gui and gui:FindFirstChild("Players")
            local playersText

            if playersObj then
                if playersObj:IsA("TextLabel") or playersObj:IsA("TextBox") then
                    playersText = playersObj.Text
                elseif playersObj:IsA("StringValue") then
                    playersText = playersObj.Value
                end
            end

            if playersText and playersText == "0/5" then
                print("🟢 Teleporter" .. i .. " available!")
                if autoJoin then
                    TryJoinTeleporter(i, playerSlot)
                end
                break
            end
        end
    end
end

-- // Auto-run when _G.AutoJoin = true
if AutoJoinEnabled then
    task.spawn(function()
        while AutoJoinEnabled do
            CheckTeleporters(true, SelectedSlot)
            task.wait(5)
        end
    end)
end
