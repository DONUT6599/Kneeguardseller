local Players = game.Players
local LC = Players.LocalPlayer
local char = LC.Character or LC.CharacterAdded:Wait()
local color = char["Body Colors"].TorsoColor
local woof = char:WaitForChild("HumanoidRootPart")

print(color)

local ReGui = loadstring(game:HttpGet('https://raw.githubusercontent.com/depthso/Dear-ReGui/refs/heads/main/ReGui.lua'))()

local Window = ReGui:Window({
    Title = 'Main',
    Size = UDim2.fromOffset(300, 200),
}) --> Canvas & WindowClass

Window:Label({ Text = 'Esc Tungtung' })
local highlights = {}

Window:Checkbox({
    Value = true,
    Label = "ESP tungtung",
    Callback = function(self, Value: boolean)
        if Value then
            for _, name in ipairs({"tungtungbackup", "Smlik"}) do
                local obj = workspace:FindFirstChild(name)
                if obj then
                    local hl = Instance.new("Highlight")
                    hl.Parent = obj
                    hl.FillColor = Color3.fromRGB(255, 255, 255)
                    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
                    hl.OutlineTransparency = 0
                    hl.FillTransparency = 0.5
                    table.insert(highlights, hl)
                end
            end
        else
            for _, hl in ipairs(highlights) do
                hl:Destroy()
            end
            highlights = {}
        end
    end
})



Window:Checkbox({
    Value = false,
    Label = "Auto Meals",
    Callback = function(self, Value: boolean)
        if Value == true then
            local w = workspace.Collectible
            for i, v in pairs(w:GetDescendants()) do
                if v:IsA("ProximityPrompt") then
                    local pongmungtie = v.Parent
                    if pongmungtie:IsA("BasePart") then
                    woof.CFrame = pongmungtie.CFrame + Vector3.new(0, 3, 0)
                    elseif pongmungtie:IsA("Model") and pongmungtie.PrimaryPart then
                        woof.CFrame = pongmungtie.PrimaryPart.CFrame + Vector3.new(0, 3, 0)
                    end
                    task.wait(0.2)
                    fireproximityprompt(v)    
                end
            end
        end
    end
})
Window:Checkbox({
    Value = false,
    Label = "Auto Collect Coins",
    Callback = function(self, Value: boolean)
            if Value == true then
            task.spawn(function()
                while self.Value do
                    for _, v in pairs(workspace:GetDescendants()) do
                        if v.Name == "CoinPrefab" and v:IsA("BasePart") then
                            woof.CFrame = v.CFrame + Vector3.new(0, 3, 0)
                            task.wait(0.1)
                        end
                    end
                    task.wait(0.1)
                end
            end)
        end
    end
})