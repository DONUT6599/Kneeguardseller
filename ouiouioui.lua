
local G = getgenv()
local prev = G.AutoFish
if prev then
	prev.enabled = false
	for _, c in ipairs(prev.conns or {}) do pcall(function() c:Disconnect() end) end
	if prev.cleanup then pcall(prev.cleanup)
	elseif prev.espFolder then pcall(function() prev.espFolder:Destroy() end) end
end

local AF = {
	enabled = true,      -- engine alive (false = unloaded)
	on = false,          -- Auto Fish toggle
	mining = false,      -- Auto Mine toggle
	autoSellOre = false, sellOreAt = 25, -- sell trip once you carry this many ores
	busy = nil,          -- set while eating/buying; fishing pauses until it clears
	task = nil,          -- what the busy job is doing, for the status lines
	power = 96,          -- cast power (10-100), jittered ±4 per cast
	shakeInterval = 0.2, -- seconds between SHAKE clicks during the lure phase
	autoEquip = true,
	antiAfk = true,
	spot = nil, useSpot = true, -- fishing spot CFrame; cast loop moves back to it when knocked off
	autoSell = false,
	sellRarities = { Common = true, Uncommon = true },
	autoEat = false, eatBelow = 40,
	autoDrink = false, drinkBelow = 40,
	autoBuy = false, buyAmount = 3,
	walkSpeed = 24,      -- speed while the hub walks you somewhere (applied via SpeedMultiplier)
	noclip = true, float = true, -- travel assists while walking
	esp = false, espRole = true, espName = true, espHealth = true, espHighlight = true, espMaxDist = 1000, espTeams = {},
	espBox = false, espTracer = false,
	bmEsp = false, bmNotify = true,
	backoff = {},        -- [job] = os.clock() until which a failed job isn't retried
	casts = 0, bites = 0, catches = 0, escapes = 0, sold = 0, sinceBite = 0,
	hits = 0, rocksMined = 0, oreSold = 0, oreMoney = 0,
	recent = {},
	conns = {},
}
G.AutoFish = AF

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/DONUT6599/ddgdhdf/refs/heads/main/VaderUI.lua"))()
local Options = Library.Options

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local VirtualUser = game:GetService("VirtualUser")
local LP = Players.LocalPlayer
local ROD = "FishingRod"
local LOG = "autofish_log.txt"
local t0 = os.clock()

function AF.log(s)
	pcall(appendfile, LOG, string.format("[%.1f] %s\n", os.clock() - t0, s))
end
writefile(LOG, "== autofish started ==\n")

local function notify(title, content)
	Library:Notify({ Title = title, Content = content, Duration = 4 })
end

--------------------------- [[ Engine ]] ---------------------------

--  ReplicatedStorage.Tools.Client.FishingRod
local function findRod(char)
	local fallback
	for _, f in ipairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) and debug.info(f, "n") == "PerformCast" then
			local r = { cast = f }
			for i, v in pairs(debug.getupvalues(f)) do
				if type(v) == "table" then
					if rawget(v, "CanCast") ~= nil then r.state = v
					elseif rawget(v, "RunLure") then r.ms = v end
				elseif typeof(v) == "Instance" and v:IsA("Tool") then
					r.tool = v
				elseif type(v) == "boolean" then
					r.eqIdx = i -- the "equipped" flag
				end
			end
			if r.state and r.ms and r.tool and r.eqIdx and r.tool.Parent == char then
				if debug.getupvalue(f, r.eqIdx) == true then return r end
				fallback = fallback or r
			end
		end
	end
	return fallback
end

-- Force MinigameSystem:Start(auto=true) and record the outcome
local function hookStart(ms)
	if ms.Start == AF.hook then return end
	G.AutoFishOrig = G.AutoFishOrig or setmetatable({}, { __mode = "k" })
	local orig = G.AutoFishOrig[ms]
	if not orig then
		orig = ms.Start
		if orig == G.AutoFishStartHook then -- hook left by an older version: unwrap it
			for _, v in pairs(debug.getupvalues(orig)) do
				if type(v) == "function" then orig = v end
			end
		end
		G.AutoFishOrig[ms] = orig
	end
	AF.hook = function(self, auto, rod, rarity, name, ...)
		local A = G.AutoFish
		if A and A.enabled and A.on then
			auto = true
			A.bites += 1
			A.sinceBite = 0
			A.log(string.format("bite: %s (%s)", tostring(name), tostring(rarity)))
			task.spawn(function()
				repeat task.wait(0.1) until not self:IsActive()
				if self:GetProgress() >= 1 then
					A.catches += 1
					table.insert(A.recent, 1, string.format("%s (%s)", tostring(name), tostring(rarity)))
					if #A.recent > 5 then table.remove(A.recent) end
					A.log(string.format("CAUGHT %s (%s) | %d caught, %d escaped", tostring(name), tostring(rarity), A.catches, A.escapes))
				else
					A.escapes += 1
					A.log("escaped: " .. tostring(name))
				end
			end)
		end
		return orig(self, auto, rod, rarity, name, ...)
	end
	G.AutoFishStartHook = AF.hook
	ms.Start = AF.hook
end

-- Hook right away when the rod is out, so an older run's hook is replaced before the toggle is touched
AF.rod = prev and prev.rod or (LP.Character and findRod(LP.Character))
if AF.rod then hookStart(AF.rod.ms) end

--------------------------- [[ Busy jobs + travel ]] ---------------------------

local function fishingBusy()
	local rod = AF.rod
	return rod and rod.tool.Parent == LP.Character and (rod.ms:IsActive() or rod.state.FishingInProgress)
end

-- Runs one job at a time; fishing stops casting and the job waits for a catch in progress to finish
local function withBusy(job, fn)
	if AF.busy or (AF.backoff[job] or 0) > os.clock() then return end
	AF.busy, AF.task = job, job
	local t = os.clock()
	while (fishingBusy() or AF.walking) and os.clock() - t < 30 do task.wait(0.25) end
	local ok, res = pcall(fn)
	if not ok then AF.log("error in " .. job .. ": " .. tostring(res)) end
	if not ok or res == false then AF.backoff[job] = os.clock() + 60 end
	AF.busy, AF.task = nil, nil
end

local FLAT = Vector3.new(1, 0, 1)

-- While walking: noclip (re-applied every step, like IY's) and an invisible anchored platform that follows
-- under your feet at the route's ground height, so a noclipped character can't drop into the void.
local function travelAssist(hrp, groundY)
	local char = hrp.Parent
	local a = { groundY = groundY }
	local conns, collided = {}, {}
	if AF.noclip then
		table.insert(conns, RunService.Stepped:Connect(function()
			for _, p in ipairs(char:GetDescendants()) do
				if p:IsA("BasePart") and p.CanCollide then
					collided[p] = true
					p.CanCollide = false
				end
			end
		end))
	end
	local plat
	if AF.float then
		plat = Instance.new("Part")
		plat.Name = "HubFloat"
		plat.Size = Vector3.new(6, 1, 6)
		plat.Transparency = 1
		plat.Anchored = true
		plat.CFrame = CFrame.new(hrp.Position.X, groundY - 0.5, hrp.Position.Z)
		plat.Parent = workspace
		local y = groundY
		table.insert(conns, RunService.Heartbeat:Connect(function(dt)
			y += math.clamp(a.groundY - y, -20 * dt, 20 * dt) -- ease height changes instead of snapping
			plat.CFrame = CFrame.new(hrp.Position.X, y - 0.5, hrp.Position.Z)
		end))
	end
	function a.stop()
		for _, c in ipairs(conns) do c:Disconnect() end
		if plat then plat:Destroy() end
		for p in pairs(collided) do
			if p.Parent then p.CanCollide = true end
		end
	end
	return a
end

-- Walks there along pathfinding waypoints, then faces cf's direction. Returns whether it arrived.
-- Steers with Humanoid:Move like player input: the game's Animate picks walk/run from MoveDirection,
-- which Humanoid:MoveTo leaves at zero (the character would slide in its idle pose).
-- Speed goes through the character's SpeedMultiplier attribute: the game's Animate script eases WalkSpeed
-- toward its own target every frame (so setting WalkSpeed directly gets pulled back) and scales the
-- walk/run animation by WalkSpeed, so this keeps both the speed and the legs in step.
local function moveTo(cf)
	local char = LP.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and hrp) then return false end
	AF.walking = true -- a busy job waits for this walk to end, so two walks never steer at once
	local target = cf.Position
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local ok = pcall(path.ComputeAsync, path, hrp.Position, target)
	local found = ok and path.Status == Enum.PathStatus.Success
	local points = found and path:GetWaypoints() or { { Position = target, Action = Enum.PathWaypointAction.Walk } }
	local oldMult = char:GetAttribute("SpeedMultiplier")
	char:SetAttribute("SpeedMultiplier", math.clamp(AF.walkSpeed / 16, 0.25, 4))
	local prevY = hrp.Position.Y - 3 -- feet height (R6 root sits 3 studs up)
	local assist = travelAssist(hrp, prevY)
	hum.Sit = false
	local walkTarget
	-- Runs right after the ControlModule's input step, so it wins over keyboard/thumbstick for the walk
	RunService:BindToRenderStep("HubWalk", Enum.RenderPriority.Input.Value + 1, function()
		local d = walkTarget and (walkTarget - hrp.Position) * FLAT
		hum:Move(d and d.Magnitude > 0.5 and d.Unit or Vector3.zero, false)
	end)

	local function walk()
		for _, wp in ipairs(points) do
			if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
			local wpY = found and wp.Position.Y or target.Y - 3
			local segLen = ((wp.Position - hrp.Position) * FLAT).Magnitude
			local timeout = 5 + 2 * segLen / AF.walkSpeed
			local started, best, progressAt = os.clock(), math.huge, os.clock()
			local d = segLen
			walkTarget = wp.Position
			while d > 1.5 do
				if not AF.enabled or hum.Health <= 0 or os.clock() - started > timeout then return false end
				assist.groundY = prevY + (wpY - prevY) * (segLen > 0 and math.clamp(1 - d / segLen, 0, 1) or 1)
				if d < best - 0.5 then
					best, progressAt = d, os.clock()
				elseif os.clock() - progressAt > 1.5 then
					hum.Jump = true -- stuck on something
					progressAt = os.clock()
				end
				task.wait()
				d = ((hrp.Position - wp.Position) * FLAT).Magnitude
			end
			prevY = wpY
		end
		return true
	end

	local okWalk, walked = pcall(walk) -- cleanup below must always run, or the binding keeps steering you
	walked = okWalk and walked
	RunService:UnbindFromRenderStep("HubWalk")
	hum:Move(Vector3.zero, false)
	assist.stop()
	char:SetAttribute("SpeedMultiplier", oldMult)
	AF.walking = false
	if not walked then return false end
	hrp.CFrame = CFrame.new(hrp.Position) * cf.Rotation
	task.wait(0.3)
	return ((hrp.Position - target) * FLAT).Magnitude <= 3
end

-- Fishing spot: position + facing, saved to a file so it survives rejoins
local SPOT_FILE = "autofish_spot.txt"

local function setSpot(cf)
	AF.spot = cf
	pcall(writefile, SPOT_FILE, cf and table.concat({ cf:GetComponents() }, ",") or "")
end

do
	local ok, saved = pcall(readfile, SPOT_FILE)
	local n = ok and saved and string.split(saved, ",") or {}
	if #n == 12 then
		local c = {}
		for i, v in ipairs(n) do c[i] = tonumber(v) end
		AF.spot = CFrame.new(table.unpack(c))
	end
end

local function offSpot(char)
	local hrp = AF.useSpot and AF.spot and char:FindFirstChild("HumanoidRootPart")
	return hrp and ((hrp.Position - AF.spot.Position).Magnitude > 3 or hrp.CFrame.LookVector:Dot(AF.spot.LookVector) < 0.97)
end

-- Shake clicker for the lure phase
task.spawn(function()
	while AF.enabled do
		local ms = AF.rod and AF.rod.ms
		if AF.on and ms and ms:IsActive() and ms:GetPhase() == "shake" then
			pcall(ms.HandleClick, ms, nil, nil)
		end
		task.wait(AF.shakeInterval)
	end
end)

-- Cast loop
task.spawn(function()
	while AF.enabled do
		local char = LP.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not AF.on or AF.busy or not hum or hum.Health <= 0 then
			task.wait(0.5)
			continue
		end

		-- Go to the spot first (before the rod comes out), but never in the middle of a catch
		if offSpot(char) and not fishingBusy() then
			AF.toSpot = true
			local arrived = moveTo(AF.spot)
			AF.toSpot = false
			if not arrived then
				AF.log("couldn't walk to the fishing spot")
				task.wait(5)
			end
			continue
		end

		local tool = char:FindFirstChild(ROD)
		if not tool then
			local bp = AF.autoEquip and LP.Backpack:FindFirstChild(ROD)
			if bp then hum:EquipTool(bp) end
			task.wait(1)
			continue
		end

		local rod = AF.rod
		if not rod or rod.tool ~= tool or debug.getupvalue(rod.cast, rod.eqIdx) ~= true then
			rod = findRod(char)
			AF.rod = rod
			if not rod then
				AF.log("PerformCast not found yet, retrying")
				task.wait(2)
				continue
			end
			hookStart(rod.ms)
			AF.log("hooked " .. rod.tool:GetFullName())
		end

		local s = rod.state
		if s.CanCast and not (s.Casted or s.FishingInProgress or s.CastingCooldown) and not rod.ms:IsActive() then
			task.wait(0.4 + math.random() * 0.8)
			if not AF.enabled or not AF.on or AF.busy or not s.CanCast or s.Casted then continue end
			if AF.sinceBite >= 4 then
				AF.log("4 casts without a bite")
				notify("No bites", "Face the water or change cast power")
				AF.sinceBite = 0
			end
			local p = math.clamp(AF.power + (math.random() * 8 - 4), 10, 100)
			AF.casts += 1
			AF.sinceBite += 1
			task.spawn(rod.cast, math.floor(p * 10) / 10)
			task.wait(1)
		else
			task.wait(0.2)
		end
	end
end)

table.insert(AF.conns, LP.Idled:Connect(function()
	if AF.antiAfk then
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end
end))

-- The game reports "seconds since last input" every 20 s (PlayerScripts.JourneyProbeClient, reset on
-- UserInputService.InputBegan). Tapping an unbound key now and then counts as input without moving
-- the camera or the character, so auto-fishing doesn't show up as hours of idle.
local VirtualInputManager = game:GetService("VirtualInputManager")
task.spawn(function()
	while AF.enabled do
		task.wait(25 + math.random() * 25)
		if AF.enabled and AF.antiAfk then
			pcall(function()
				VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F15, false, game)
				task.wait(0.05 + math.random() * 0.1)
				VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F15, false, game)
			end)
		end
	end
end)

-- Selling: same remote the catch prompt's Sell button and the inventory use
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Unknown", "Mythical", "Secret" }
local FishingSystem = RS:WaitForChild("FishingSystem")
local InventoryEvents = FishingSystem:WaitForChild("InventoryEvents")
local SellFish = InventoryEvents:WaitForChild("Inventory_SellFish")
local GetData = InventoryEvents:WaitForChild("Inventory_GetData")

local function sell(id, name, rarity)
	local ok, res = pcall(SellFish.InvokeServer, SellFish, id)
	if ok and res == true then
		AF.sold += 1
		AF.log(string.format("sold %s (%s)", tostring(name), tostring(rarity)))
		return true
	end
	AF.log(string.format("sell failed %s (%s): %s", tostring(name), tostring(rarity), tostring(res)))
	return false
end

-- Auto sell: answer the catch prompt the server sends after each catch
table.insert(AF.conns, FishingSystem:WaitForChild("CatchPrompt").OnClientEvent:Connect(function(data)
	if not (AF.autoSell and type(data) == "table" and type(data.Id) == "string" and AF.sellRarities[data.Rarity]) then
		return
	end
	task.wait(0.4 + math.random() * 0.6)
	if sell(data.Id, data.Name, data.Rarity) then
		local gui = LP.PlayerGui:FindFirstChild("MainGui")
		local prompt = gui and gui:FindFirstChild("CatchPrompt")
		if prompt then prompt.Visible = false end
	end
end))

-- Sell every non-favorited fish in the inventory that matches the selected rarities
local function sellInventory()
	local ok, data = pcall(GetData.InvokeServer, GetData)
	if not ok or type(data) ~= "table" then
		notify("Sell", "Couldn't read the inventory")
		return
	end
	local n = 0
	for _, f in ipairs(data.Fish or {}) do
		if not f.isFavorited and AF.sellRarities[f.rarity] then
			if sell(f.uniqueId, f.name, f.rarity) then n += 1 end
			task.wait(0.15)
		end
	end
	notify("Sell", string.format("Sold %d fish", n))
end

--------------------------- [[ Survival ]] ---------------------------

local ToolEvent = RS.Remotes.Tool.Event
local FOODS = { CerealBar = true, Popcorn = true }
local DRINKS = { Soda = true, BloxyCola = true }
local NEEDS = {
	{ stat = "Hunger", toggle = "autoEat", below = "eatBelow", action = "Eat", kind = "Food", items = FOODS },
	{ stat = "Thirst", toggle = "autoDrink", below = "drinkBelow", action = "Drink", kind = "Drink", items = DRINKS },
}

-- Tools of a set in backpack + hands, partly eaten first; total counts stacks
local function items(set)
	local list, total = {}, 0
	for _, where in ipairs({ LP.Character, LP.Backpack }) do
		if where then
			for _, t in ipairs(where:GetChildren()) do
				if t:IsA("Tool") and set[t.Name] then
					table.insert(list, t)
					total += t:GetAttribute("Count") or 1
				end
			end
		end
	end
	table.sort(list, function(a, b) return (a:GetAttribute("Step") or 0) > (b:GetAttribute("Step") or 0) end)
	return list, total
end

-- Vending machines, standing 3 studs out from the coin slot (front face); spots inside walls are skipped
local MACHINES = {}
do
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LP.Character }
	for _, d in ipairs(workspace.Map:GetDescendants()) do
		if d:IsA("Model") and d:GetAttribute("InteractionType") == "VendingMachine" and d:FindFirstChild("Money") then
			local cf, size = d:GetBoundingBox()
			local coin = d.Money.Position
			local dir = (coin - cf.Position) * Vector3.new(1, 0, 1)
			local spot = Vector3.new(coin.X, cf.Position.Y - size.Y / 2 + 3, coin.Z) + (dir.Magnitude > 0 and dir.Unit or Vector3.zero) * 3
			local blocked = false
			for _, p in ipairs(workspace:GetPartBoundsInRadius(spot, 1, params)) do
				if p.CanCollide then blocked = true break end
			end
			if not blocked then
				table.insert(MACHINES, {
					area = d:GetFullName():match("^Workspace%.Map%.([^%.]+)") or d.Name,
					coin = coin,
					spot = spot,
					prompt = d.Money:FindFirstChild("Prompt"),
				})
			end
		end
	end
end

local function buyAt(kind, set, n)
	local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	if not hrp or #MACHINES == 0 then return false end
	local m, best
	for _, c in ipairs(MACHINES) do
		local d = (c.spot - hrp.Position).Magnitude
		if not best or d < best then m, best = c, d end
	end
	local back = hrp.CFrame
	AF.task = "Walking to the " .. m.area .. " vending machine"
	if not moveTo(CFrame.lookAt(m.spot, Vector3.new(m.coin.X, m.spot.Y, m.coin.Z))) then
		AF.log("couldn't reach the vending machine at " .. m.area)
		AF.task = "Walking back"
		moveTo(back)
		return false
	end
	AF.task = "Buying " .. kind:lower() .. " at " .. m.area
	local event = m.prompt[kind].Event
	local bought = 0
	for _ = 1, n + 3 do
		if bought >= n or (LP:GetAttribute("Money") or 0) < 3 then break end
		local _, before = items(set)
		event:FireServer()
		local t = os.clock()
		repeat task.wait(0.1) until select(2, items(set)) > before or os.clock() - t > 2.5
		if select(2, items(set)) > before then bought += 1 end
		task.wait(0.8 + math.random() * 0.4)
	end
	AF.task = "Walking back"
	moveTo(back)
	AF.log(string.format("bought %d %s at %s", bought, kind, m.area))
	return bought > 0
end

local function consume(action, set, stat)
	local item = items(set)[1]
	local char = LP.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (item and hum) then return false end
	AF.task = action == "Eat" and "Eating" or "Drinking"
	local held = char:FindFirstChildOfClass("Tool")
	local start = LP:GetAttribute(stat) or 0
	hum:EquipTool(item)
	local t = os.clock()
	repeat task.wait(0.1) until item.Parent == char or os.clock() - t > 2
	task.wait(0.6)
	for _ = 1, 6 do
		if item.Parent ~= char or (LP:GetAttribute(stat) or 100) >= 85 then break end
		local w = os.clock()
		while item:GetAttribute("OnCooldown") and os.clock() - w < 3 do task.wait(0.1) end
		ToolEvent:FireServer(action, item)
		task.wait(1.2)
	end
	if held and held ~= item and held.Parent then hum:EquipTool(held) else hum:UnequipTools() end
	AF.log(string.format("%s: %s %s -> %s", action, stat, tostring(start), tostring(LP:GetAttribute(stat))))
	return (LP:GetAttribute(stat) or 0) > start
end

task.spawn(function()
	while AF.enabled do
		task.wait(1)
		local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
		if AF.busy or not hum or hum.Health <= 0 then continue end
		for _, need in ipairs(NEEDS) do
			if AF[need.toggle] and (LP:GetAttribute(need.stat) or 100) < AF[need.below] then
				if select(2, items(need.items)) == 0 and AF.autoBuy then
					withBusy("Buy " .. need.kind, function() return buyAt(need.kind, need.items, AF.buyAmount) end)
				end
				if select(2, items(need.items)) > 0 then
					withBusy(need.action, function() return consume(need.action, need.items, need.stat) end)
				end
			end
		end
	end
end)

--------------------------- [[ Mining ]] ---------------------------

-- Same hit the Pickaxe client sends on its swing's "Hit" marker (ReplicatedStorage.Tools.Client.Pickaxe):
-- a rock inside a 3x6x4 box 2 studs in front of you gets Tool.Event("MineOres", pickaxe, rock).
-- The server takes 5 Health off the rock and locks the pickaxe for ~1 s (player attribute PickaxeLocked).
local Rocks = workspace.Tasks.Prisoner.Rocks
local PICKAXES = { Pickaxe = true, PremiumPickaxe = true }
local rockParams = OverlapParams.new()
rockParams.FilterType = Enum.RaycastFilterType.Include
rockParams.RespectCanCollide = false
rockParams.FilterDescendantsInstances = { Rocks }
local skipRock = setmetatable({}, { __mode = "k" }) -- [rock] = os.clock() until which it's left alone

local function rockUp(r)
	return not r:GetAttribute("Destroyed") and (r:GetAttribute("Health") or 0) > 0
end

local function inReach(hrp, rock)
	for _, p in ipairs(workspace:GetPartBoundsInBox(hrp.CFrame * CFrame.new(0, 0, -2), Vector3.new(3, 6, 4), rockParams)) do
		if p == rock then return true end
	end
	return false
end

local function faceRock(hrp, rock)
	hrp.CFrame = CFrame.lookAt(hrp.Position, Vector3.new(rock.Position.X, hrp.Position.Y, rock.Position.Z))
end

-- Ore lands in the backpack as stacked tools (Count attribute); Economy.Ores holds each one's price.
-- Selling is what the Mineral Buyer's window does (GuiTemplates.Center.Reseller): SellOre(name, amount) per ore.
local SellOre = RS.Remotes.SellOre
local ORES = {}
for _, o in ipairs(RS.Economy.Ores:GetChildren()) do ORES[o.Name] = o end

local function oreCounts()
	local counts, total = {}, 0
	for _, where in ipairs({ LP.Character, LP.Backpack }) do
		if where then
			for _, t in ipairs(where:GetChildren()) do
				if t:IsA("Tool") and ORES[t.Name] then
					local n = math.max(1, math.floor(tonumber(t:GetAttribute("Count")) or 1))
					counts[t.Name] = (counts[t.Name] or 0) + n
					total += n
				end
			end
		end
	end
	return counts, total
end

local function sellOres()
	local _, total = oreCounts()
	local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	local npc = workspace.Entities:FindFirstChild("Mineral Buyer")
	local root = npc and npc:FindFirstChild("HumanoidRootPart")
	if total == 0 or not (hrp and root) then return total == 0 end
	AF.task = "Walking to the Mineral Buyer"
	local stand = root.Position + root.CFrame.LookVector * 3
	if not moveTo(CFrame.lookAt(stand, Vector3.new(root.Position.X, stand.Y, root.Position.Z))) then
		AF.log("couldn't reach the Mineral Buyer")
		return false
	end
	AF.task = "Selling ore"
	local money = LP:GetAttribute("Money") or 0
	pcall(function() root.Prompt.Interact.Event:FireServer() end) -- same as pressing E on it
	task.wait(0.8 + math.random() * 0.4)
	for _ = 1, 3 do -- the window's Sell All asks for 100 at a time
		local counts = oreCounts()
		if not next(counts) then break end
		for name, n in pairs(counts) do
			SellOre:FireServer(name, math.min(n, 100))
			task.wait(0.4 + math.random() * 0.3)
		end
		task.wait(1)
	end
	local gui = LP.PlayerGui:FindFirstChild("MainGui")
	local window = gui and gui:FindFirstChild("Center") and gui.Center:FindFirstChild("Reseller")
	if window then window.Visible = false end
	local focus = LP.PlayerGui:FindFirstChild("StaticGui") and LP.PlayerGui.StaticGui:FindFirstChild("Focus")
	if focus then focus.Visible = false end
	local _, left = oreCounts()
	local earned = (LP:GetAttribute("Money") or 0) - money
	AF.oreSold += total - left
	AF.oreMoney += earned
	AF.log(string.format("sold %d ore for $%d (%d left)", total - left, earned, left))
	return left < total
end

task.spawn(function()
	local misses = 0
	while AF.enabled do
		local char = LP.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not AF.mining or AF.busy or not (hum and hrp) or hum.Health <= 0 then
			task.wait(0.5)
			continue
		end

		if AF.autoSellOre and select(2, oreCounts()) >= AF.sellOreAt and (AF.backoff["Sell ore"] or 0) < os.clock() then
			withBusy("Sell ore", sellOres)
			continue
		end

		local tool = char:FindFirstChildOfClass("Tool")
		if tool and not PICKAXES[tool.Name] then tool = nil end
		if not tool then
			local bp
			for _, t in ipairs(LP.Backpack:GetChildren()) do
				if t:IsA("Tool") and PICKAXES[t.Name] then bp = t break end
			end
			if bp then
				AF.mineState = "Equipping pickaxe"
				hum:EquipTool(bp)
				task.wait(1)
				continue
			end
			-- no pickaxe: the yard (Map.Exterior.PickaxeZone) hands one out on the way in, so head for a rock anyway
		end

		local rock, best
		for _, r in ipairs(Rocks:GetChildren()) do
			local d = rockUp(r) and (skipRock[r] or 0) < os.clock() and (r.Position - hrp.Position).Magnitude
			if d and (not best or d < best) then rock, best = r, d end
		end
		if not rock then
			AF.mineState = "Waiting for rocks to respawn"
			task.wait(2)
			continue
		end

		if not inReach(hrp, rock) then
			AF.mineState = "Walking to a rock"
			if best > 8 then
				local away = (hrp.Position - rock.Position) * FLAT
				local stand = rock.Position + (away.Magnitude > 0 and away.Unit or Vector3.xAxis) * 4
				moveTo(CFrame.lookAt(stand, Vector3.new(rock.Position.X, stand.Y, rock.Position.Z)))
			end
			-- last few studs straight at it
			local t = os.clock()
			hum:MoveTo(rock.Position)
			repeat task.wait() until inReach(hrp, rock) or os.clock() - t > 2
			hum:MoveTo(hrp.Position)
			faceRock(hrp, rock)
			if not inReach(hrp, rock) then
				skipRock[rock] = os.clock() + 30
				AF.log("couldn't reach a rock, trying another")
			end
			continue
		end

		if not tool then
			AF.mineState = "Waiting for the yard's pickaxe"
			task.wait(1)
			continue
		end

		AF.mineState = "Mining"
		faceRock(hrp, rock)
		local hitIt = false
		while AF.mining and not AF.busy and rockUp(rock) and tool.Parent == char and inReach(hrp, rock) do
			if LP:GetAttribute("PickaxeLocked") or tool:GetAttribute("OnCooldown") then
				task.wait(0.05)
				continue
			end
			task.wait(0.05 + math.random() * 0.25)
			ToolEvent:FireServer("MineOres", tool, rock)
			local t = os.clock()
			repeat task.wait(0.05) until LP:GetAttribute("PickaxeLocked") or os.clock() - t > 1
			if LP:GetAttribute("PickaxeLocked") then
				AF.hits += 1
				hitIt, misses = true, 0
			else
				misses += 1
				if misses >= 3 then
					misses = 0
					skipRock[rock] = os.clock() + 30
					AF.log("server ignored 3 hits in a row, trying another rock")
					break
				end
			end
		end
		if hitIt and not rockUp(rock) then
			AF.rocksMined += 1
			AF.log("broke a rock (" .. AF.rocksMined .. ")")
		end
	end
end)

--------------------------- [[ Black Market ]] ---------------------------

local Weapons = RS.Economy.Weapons
local BM_AREAS = { ["1"] = "Cells - Basement", ["2"] = "Gym - Floor 0", ["3"] = "Eat Place - Back Kitchen", ["4"] = "Gym - Floor 2 Lobby", ["5"] = "Central Court" }

local function bmNpc()
	local f = workspace.Entities:FindFirstChild("Black Market")
	local npc = f and f:FindFirstChild("Black Market")
	return npc, npc and npc:FindFirstChild("HumanoidRootPart"), f
end

local function bmArea()
	local _, root, f = bmNpc()
	if not root then return "Not spawned" end
	local best, bd
	for _, s in ipairs(f.Spawns:GetChildren()) do
		local d = (s.Position - root.Position).Magnitude
		if not bd or d < bd then best, bd = s, d end
	end
	return best and bd < 25 and (BM_AREAS[best.Name] or "Spawn " .. best.Name) or "Unknown spot"
end

--------------------------- [[ ESP ]] ---------------------------

local espFolder = Instance.new("Folder")
espFolder.Name = "HubESP"
espFolder.Parent = gethui and gethui() or game:GetService("CoreGui")
AF.espFolder = espFolder
local esp = {}

local function makeTag(height)
	local bb = Instance.new("BillboardGui")
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(180, height)
	bb.StudsOffset = Vector3.new(0, 3, 0)
	bb.Parent = espFolder
	return bb
end

local function makeLabel(parent, y, size, bold)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, size + 2)
	l.Position = UDim2.fromOffset(0, y)
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextSize = size
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeTransparency = 0.4
	l.Parent = parent
	return l
end

local function makeHighlight()
	local hl = Instance.new("Highlight")
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillTransparency = 0.7
	hl.OutlineTransparency = 0
	hl.Parent = espFolder
	return hl
end

local function makeEsp(p)
	local bb = makeTag(44)
	local bar = Instance.new("Frame")
	bar.BorderSizePixel = 0
	bar.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
	bar.Size = UDim2.new(0.5, 0, 0, 4)
	bar.Position = UDim2.new(0.25, 0, 0, 34)
	bar.Parent = bb
	local fill = Instance.new("Frame")
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	fill.Parent = bar
	local e = { hl = makeHighlight(), bb = bb, role = makeLabel(bb, 0, 14, true), name = makeLabel(bb, 16, 12), bar = bar, fill = fill }
	if Drawing then
		e.box = Drawing.new("Quad")
		e.box.Thickness = 1
		e.box.Filled = false
		e.box.Visible = false
		e.tracer = Drawing.new("Line")
		e.tracer.Thickness = 1
		e.tracer.Visible = false
	end
	esp[p] = e
	return e
end

local function removeEsp(p)
	local e = esp[p]
	if not e then return end
	e.hl:Destroy()
	e.bb:Destroy()
	if e.box then
		e.box:Remove()
		e.tracer:Remove()
	end
	esp[p] = nil
end

-- Who to show and in what color; shared by the tag loop and the per-frame box/tracer pass
local function espTarget(p, myPos)
	local char = p.Character
	local head = char and char:FindFirstChild("Head")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local dist = head and myPos and (head.Position - myPos).Magnitude or math.huge
	local show = AF.esp and hum ~= nil and dist <= AF.espMaxDist and (p.Team == nil or AF.espTeams[p.Team.Name] == true)
	return show, char, head, hum, dist, p.Team and p.Team.TeamColor.Color or Color3.new(1, 1, 1)
end

local bm = { hl = makeHighlight(), bb = makeTag(36) }
bm.title = makeLabel(bm.bb, 0, 14, true)
bm.info = makeLabel(bm.bb, 16, 12)
bm.title.Text = "BLACK MARKET"
bm.title.TextColor3 = Color3.fromRGB(255, 200, 60)
bm.hl.FillColor, bm.hl.OutlineColor = Color3.fromRGB(255, 200, 60), Color3.fromRGB(255, 200, 60)

table.insert(AF.conns, Players.PlayerRemoving:Connect(removeEsp))

local function updateEsp()
	local myRoot = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then
			local e = esp[p] or makeEsp(p)
			local show, char, head, hum, dist, color = espTarget(p, myRoot and myRoot.Position)
			e.hl.Adornee = show and AF.espHighlight and char or nil
			e.hl.Enabled = show and AF.espHighlight
			e.hl.FillColor, e.hl.OutlineColor = color, color
			e.bb.Adornee = show and head or nil
			e.bb.Enabled = show
			if show then
				e.role.Visible = AF.espRole
				e.role.Text = p.Team and p.Team.Name or "No role"
				e.role.TextColor3 = color
				e.name.Visible = AF.espName
				e.name.Text = string.format("%s · %dm", p:GetAttribute("RoleplayName") or p.DisplayName, math.floor(dist))
				local hp = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
				e.bar.Visible = AF.espHealth
				e.fill.Size = UDim2.fromScale(hp, 1)
				e.fill.BackgroundColor3 = Color3.fromHSV(hp * 0.33, 0.85, 0.95)
			end
		end
	end

	local npc, root = bmNpc()
	local showBm = AF.bmEsp and root ~= nil
	bm.hl.Adornee = showBm and npc or nil
	bm.hl.Enabled = showBm
	bm.bb.Adornee = showBm and root or nil
	bm.bb.Enabled = showBm
	if showBm then
		bm.info.Text = string.format("%s · %dm", bmArea(), myRoot and math.floor((root.Position - myRoot.Position).Magnitude) or 0)
	end
end

task.spawn(function()
	local lastArea
	while AF.enabled do
		pcall(updateEsp)
		local area = bmArea()
		if lastArea and area ~= lastArea and AF.bmNotify then notify("Black Market moved", area) end
		lastArea = area
		task.wait(0.2)
	end
end)

-- Boxes and tracers: Drawing objects need a per-frame update to stick to the camera
local function drawEsp()
	local cam = workspace.CurrentCamera
	local myRoot = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	local vp = cam.ViewportSize
	for p, e in pairs(esp) do
		if e.box then
			local show, char, _, _, _, color = espTarget(p, myRoot and myRoot.Position)
			local boxOn, tracerOn = false, false
			if show and (AF.espBox or AF.espTracer) then
				-- Camera-facing box centered on the bounding box, so it keeps its width from any angle
				local cf, size = char:GetBoundingBox()
				local right = cam.CFrame.RightVector * math.clamp(size.X, 2, 6) / 2
				local up = Vector3.yAxis * math.clamp(size.Y, 3, 8) / 2
				local corners = {}
				for i, offset in ipairs({ up - right, up + right, right - up, -right - up }) do
					local v = cam:WorldToViewportPoint(cf.Position + offset)
					if v.Z <= 0 then corners = nil break end
					corners[i] = Vector2.new(v.X, v.Y)
				end
				if corners then
					boxOn, tracerOn = AF.espBox, AF.espTracer
					e.box.PointA, e.box.PointB, e.box.PointC, e.box.PointD = corners[1], corners[2], corners[3], corners[4]
					e.box.Color = color
					e.tracer.From = Vector2.new(vp.X / 2, vp.Y)
					e.tracer.To = (corners[3] + corners[4]) / 2
					e.tracer.Color = color
				end
			end
			e.box.Visible = boxOn
			e.tracer.Visible = tracerOn
		end
	end
end
table.insert(AF.conns, RunService.RenderStepped:Connect(function() pcall(drawEsp) end))

function AF.cleanup()
	pcall(RunService.UnbindFromRenderStep, RunService, "HubWalk")
	for p in pairs(esp) do removeEsp(p) end
	espFolder:Destroy()
end

--------------------------- [[ Status text ]] ---------------------------

local function stateText()
	if not AF.on then return "Off" end
	if AF.busy then return "Paused: " .. (AF.task or AF.busy) end
	if AF.toSpot then return "Walking to the spot" end
	local char = LP.Character
	if not (char and char:FindFirstChild(ROD)) then return "Equip your Fishing Rod" end
	local rod = AF.rod
	if not rod then return "Starting..." end
	if rod.ms:IsActive() then
		return rod.ms:GetPhase() == "shake" and "Luring a fish" or "Reeling"
	end
	return rod.state.Casted and "Cast out" or "Casting"
end

local function spotText()
	if not AF.spot then return "Not set: turning Auto Fish on saves where you stand" end
	local p = AF.spot.Position
	local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	return string.format("%d, %d, %d%s", math.floor(p.X), math.floor(p.Y), math.floor(p.Z),
		hrp and string.format("  ·  %dm away", math.floor((hrp.Position - p).Magnitude)) or "")
end

local function mineText()
	local state = not AF.mining and "Off" or AF.busy and "Paused: " .. (AF.task or AF.busy) or AF.mineState or "Starting..."
	local counts, total = oreCounts()
	local value = 0
	for name, n in pairs(counts) do value += n * ORES[name].Value end
	return string.format("%s\nHits %d  ·  Rocks broken %d  ·  RocksLeft %s\nCarrying %d ore ($%d)  ·  Sold %d for $%d",
		state, AF.hits, AF.rocksMined, tostring(LP:GetAttribute("RocksLeft") or "?"), total, value, AF.oreSold, AF.oreMoney)
end

local function survivalText()
	return string.format("Hunger %d  ·  Thirst %d  ·  Food %d  ·  Drinks %d  ·  $%d\n%s",
		math.floor(LP:GetAttribute("Hunger") or 0), math.floor(LP:GetAttribute("Thirst") or 0),
		select(2, items(FOODS)), select(2, items(DRINKS)), math.floor(LP:GetAttribute("Money") or 0),
		AF.task or "Idle")
end

local WEAPON_NAMES = {}
for _, w in ipairs(Weapons:GetChildren()) do table.insert(WEAPON_NAMES, w.Name) end
table.sort(WEAPON_NAMES, function(a, b) return (Weapons[a]:GetAttribute("Price") or 0) < (Weapons[b]:GetAttribute("Price") or 0) end)

local function stockText()
	local lines = {}
	for _, name in ipairs(WEAPON_NAMES) do
		local w = Weapons:FindFirstChild(name)
		if w then table.insert(lines, string.format("%s  ·  %d left  ·  $%d", name, w.Value, math.floor(w:GetAttribute("Price") or 0))) end
	end
	return table.concat(lines, "\n")
end

local TEAM_NAMES = {}
for _, t in ipairs(Teams:GetChildren()) do
	table.insert(TEAM_NAMES, t.Name)
	AF.espTeams[t.Name] = true
end
table.sort(TEAM_NAMES)

--------------------------- [[ UI ]] ---------------------------

local Window = Library:CreateWindow({
	Title = "Prison RP",
	SubTitle = "VaderHug - Custom",
	Size = UDim2.fromOffset(600, 460),
	TabWidth = 180,
	Theme = "Dark",
	MinimizeKey = Enum.KeyCode.RightControl,
})

local Main = Window:AddTab({ Title = "Fishing" })
local Mining = Window:AddTab({ Title = "Mining" })
local Survival = Window:AddTab({ Title = "Survival" })
local EspTab = Window:AddTab({ Title = "ESP" })
local Market = Window:AddTab({ Title = "Black Market" })
local Settings = Window:AddTab({ Title = "Settings" })

-- Fishing

local Status = Main:AddParagraph({ Title = "Status", Content = "Off" })
local Recent = Main:AddParagraph({ Title = "Recent catches", Content = "None yet" })

local Controls = Main:AddSection("Auto Fish")

Controls:AddToggle("AutoFish", {
	Title = "Auto Fish",
	Description = "Stand still facing the water",
	Default = false,
	Callback = function(Value)
		AF.on = Value
		AF.log(Value and "on" or "off")
		if Value and Options.AutoMine then Options.AutoMine:SetValue(false) end -- both would fight over the tool
		local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		if Value and not AF.spot and hrp then
			setSpot(hrp.CFrame)
			notify("Fishing spot", "Saved where you're standing")
		end
	end,
})

Controls:AddKeybind("AutoFishKey", {
	Title = "Toggle key",
	Description = "Click, then press a key (Esc cancels)",
	Default = "F6",
	Callback = function()
		Options.AutoFish:SetValue(not Options.AutoFish.Value)
	end,
})

local SpotSection = Main:AddSection("Fishing Spot")

local SpotInfo = SpotSection:AddParagraph({ Title = "Spot", Content = "" })

SpotSection:AddToggle("UseSpot", {
	Title = "Stay on spot",
	Description = "Walks you to the spot and its facing before equipping the rod, and back whenever you're pushed off",
	Default = true,
	Callback = function(Value)
		AF.useSpot = Value
	end,
})

SpotSection:AddButton({
	Title = "Set spot here",
	Description = "Saves where you stand and the way you face",
	Callback = function()
		local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			setSpot(hrp.CFrame)
			notify("Fishing spot", "Saved")
		end
	end,
})

SpotSection:AddButton({
	Title = "Clear spot",
	Description = "Turning Auto Fish on will save where you stand again",
	Callback = function()
		setSpot(nil)
	end,
})

local Selling = Main:AddSection("Auto Sell")

Selling:AddDropdown("SellRarities", {
	Title = "Sell rarities",
	Values = RARITIES,
	Multi = true,
	Default = { "Common", "Uncommon" },
	Callback = function(Picked)
		AF.sellRarities = Picked
	end,
})

Selling:AddToggle("AutoSell", {
	Title = "Auto Sell",
	Description = "Sells each catch of a picked rarity right away",
	Default = false,
	Callback = function(Value)
		AF.autoSell = Value
	end,
})

Selling:AddButton({
	Title = "Sell inventory now",
	Description = "Sells fish you already have in the picked rarities (skips favorites)",
	Callback = function()
		task.spawn(sellInventory)
	end,
})

local Tuning = Main:AddSection("Tuning")

Tuning:AddSlider("CastPower", {
	Title = "Cast power",
	Description = "Lower it if the hook flies past the water",
	Min = 10,
	Max = 100,
	Default = 96,
	Rounding = 0,
	Callback = function(Value)
		AF.power = Value
	end,
})

Tuning:AddSlider("ShakeSpeed", {
	Title = "Shake clicks per second",
	Min = 1,
	Max = 10,
	Default = 5,
	Rounding = 0,
	Callback = function(Value)
		AF.shakeInterval = 1 / Value
	end,
})

Tuning:AddToggle("AutoEquip", {
	Title = "Auto equip rod",
	Default = true,
	Callback = function(Value)
		AF.autoEquip = Value
	end,
})

Tuning:AddToggle("AntiAfk", {
	Title = "Anti-AFK",
	Description = "Prevents the idle kick and keeps the game's idle timer low",
	Default = true,
	Callback = function(Value)
		AF.antiAfk = Value
	end,
})

Tuning:AddButton({
	Title = "Reset stats",
	Callback = function()
		AF.casts, AF.bites, AF.catches, AF.escapes, AF.sold = 0, 0, 0, 0, 0
		table.clear(AF.recent)
	end,
})

-- Mining

local MineStatus = Mining:AddParagraph({ Title = "Status", Content = "Off" })

Mining:AddSection("Auto Mine"):AddToggle("AutoMine", {
	Title = "Auto Mine",
	Description = "Walks to the nearest rock in the yard and mines it; the yard hands out the pickaxe (turns Auto Fish off)",
	Default = false,
	Callback = function(Value)
		AF.mining = Value
		AF.log(Value and "mining on" or "mining off")
		if Value and Options.AutoFish then Options.AutoFish:SetValue(false) end
	end,
})

local OreSelling = Mining:AddSection("Sell Ore")

OreSelling:AddToggle("AutoSellOre", {
	Title = "Auto Sell ore",
	Description = "While mining: walks to the Mineral Buyer once you carry enough ore, sells it all, then goes back to the rocks",
	Default = false,
	Callback = function(Value)
		AF.autoSellOre = Value
	end,
})

OreSelling:AddSlider("SellOreAt", {
	Title = "Sell when carrying",
	Min = 5,
	Max = 100,
	Default = 25,
	Rounding = 0,
	Callback = function(Value)
		AF.sellOreAt = Value
	end,
})

OreSelling:AddButton({
	Title = "Sell ore now",
	Description = "Walks to the Mineral Buyer and sells every ore you carry",
	Callback = function()
		task.spawn(withBusy, "Sell ore", sellOres)
	end,
})

-- Survival

local SurvivalStatus = Survival:AddParagraph({ Title = "Status", Content = "" })

local Needs = Survival:AddSection("Food & Drink")

Needs:AddToggle("AutoEat", {
	Title = "Auto Eat",
	Description = "Cereal Bar / Popcorn from your backpack",
	Default = false,
	Callback = function(Value)
		AF.autoEat = Value
	end,
})

Needs:AddSlider("EatBelow", {
	Title = "Eat when Hunger is below",
	Min = 10,
	Max = 90,
	Default = 40,
	Rounding = 0,
	Callback = function(Value)
		AF.eatBelow = Value
	end,
})

Needs:AddToggle("AutoDrink", {
	Title = "Auto Drink",
	Description = "Soda / Bloxy Cola from your backpack",
	Default = false,
	Callback = function(Value)
		AF.autoDrink = Value
	end,
})

Needs:AddSlider("DrinkBelow", {
	Title = "Drink when Thirst is below",
	Min = 10,
	Max = 90,
	Default = 40,
	Rounding = 0,
	Callback = function(Value)
		AF.drinkBelow = Value
	end,
})

local Vending = Survival:AddSection("Auto Buy")

Vending:AddToggle("AutoBuy", {
	Title = "Auto Buy",
	Description = "Out of food or drinks: goes to the nearest vending machine ($3 each), then back",
	Default = false,
	Callback = function(Value)
		AF.autoBuy = Value
	end,
})

Vending:AddSlider("BuyAmount", {
	Title = "Buy per trip",
	Min = 1,
	Max = 5,
	Default = 3,
	Rounding = 0,
	Callback = function(Value)
		AF.buyAmount = Value
	end,
})

Vending:AddButton({
	Title = "Buy food now",
	Callback = function()
		task.spawn(withBusy, "Buy Food", function() return buyAt("Food", FOODS, AF.buyAmount) end)
	end,
})

Vending:AddButton({
	Title = "Buy drinks now",
	Callback = function()
		task.spawn(withBusy, "Buy Drink", function() return buyAt("Drink", DRINKS, AF.buyAmount) end)
	end,
})

-- ESP

local Visuals = EspTab:AddSection("Players")

Visuals:AddToggle("Esp", {
	Title = "ESP",
	Default = false,
	Callback = function(Value)
		AF.esp = Value
	end,
})

Visuals:AddToggle("EspRole", {
	Title = "Role tag",
	Description = "Team name above the head in team color",
	Default = true,
	Callback = function(Value)
		AF.espRole = Value
	end,
})

Visuals:AddToggle("EspName", {
	Title = "Name + distance",
	Default = true,
	Callback = function(Value)
		AF.espName = Value
	end,
})

Visuals:AddToggle("EspHealth", {
	Title = "Health bar",
	Default = true,
	Callback = function(Value)
		AF.espHealth = Value
	end,
})

Visuals:AddToggle("EspHighlight", {
	Title = "Highlight",
	Description = "Outline through walls in team color",
	Default = true,
	Callback = function(Value)
		AF.espHighlight = Value
	end,
})

Visuals:AddToggle("EspBox", {
	Title = "Boxes",
	Description = Drawing and "2D box that faces the camera" or "Needs Drawing support, which this executor lacks",
	Default = false,
	Callback = function(Value)
		AF.espBox = Value
	end,
})

Visuals:AddToggle("EspTracer", {
	Title = "Tracers",
	Description = "Line from the bottom of the screen to each player",
	Default = false,
	Callback = function(Value)
		AF.espTracer = Value
	end,
})

Visuals:AddSlider("EspDistance", {
	Title = "Max distance",
	Min = 50,
	Max = 2000,
	Default = 1000,
	Rounding = 0,
	Callback = function(Value)
		AF.espMaxDist = Value
	end,
})

Visuals:AddDropdown("EspTeams", {
	Title = "Show roles",
	Values = TEAM_NAMES,
	Multi = true,
	Default = TEAM_NAMES,
	Callback = function(Picked)
		AF.espTeams = Picked
	end,
})

-- Black Market

local BmLocation = Market:AddParagraph({ Title = "Location", Content = "" })
local BmStock = Market:AddParagraph({ Title = "Stock", Content = "" })

local Locate = Market:AddSection("Locate")

Locate:AddToggle("BmEsp", {
	Title = "Black Market ESP",
	Description = "Marks the NPC through walls",
	Default = false,
	Callback = function(Value)
		AF.bmEsp = Value
	end,
})

Locate:AddToggle("BmNotify", {
	Title = "Notify when it moves",
	Default = true,
	Callback = function(Value)
		AF.bmNotify = Value
	end,
})

-- Settings

local Travel = Settings:AddSection("Travel")

Travel:AddSlider("WalkSpeed", {
	Title = "Walk speed",
	Description = "While walking you to vending machines, the Mineral Buyer, your fishing spot and rocks (normal is 16, game caps at 64)",
	Min = 16,
	Max = 64,
	Default = 24,
	Rounding = 0,
	Callback = function(Value)
		AF.walkSpeed = Value
	end,
})

Travel:AddToggle("Noclip", {
	Title = "Noclip while walking",
	Description = "Walks through walls, doors and players on the way",
	Default = true,
	Callback = function(Value)
		AF.noclip = Value
	end,
})

Travel:AddToggle("Float", {
	Title = "Float (anti-void)",
	Description = "Invisible platform under your feet while walking, so you can't fall through the map",
	Default = true,
	Callback = function(Value)
		AF.float = Value
	end,
})

local Interface = Settings:AddSection("Interface")

Interface:AddDropdown("Theme", {
	Title = "Theme",
	Values = { "Dark", "Amethyst", "Light" },
	Default = "Dark",
	Callback = function(Name)
		Library:SetTheme(Name)
	end,
})

Library.MinimizeKeybind = Interface:AddKeybind("MinimizeKey", {
	Title = "Minimize key",
	Default = "RightControl",
})

Interface:AddButton({
	Title = "Unload",
	Description = "Stops everything and removes the UI",
	Callback = function()
		Library:Destroy()
	end,
})

-- Live status; stops the engine when the UI is gone
task.spawn(function()
	while AF.enabled and not Library.Unloaded do
		Status:SetDesc(string.format("%s\nCasts %d  ·  Bites %d  ·  Caught %d  ·  Escaped %d  ·  Sold %d",
			stateText(), AF.casts, AF.bites, AF.catches, AF.escapes, AF.sold))
		Recent:SetDesc(#AF.recent > 0 and table.concat(AF.recent, "\n") or "None yet")
		SpotInfo:SetDesc(spotText())
		MineStatus:SetDesc(mineText())
		SurvivalStatus:SetDesc(survivalText())
		local _, root = bmNpc()
		local myRoot = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		BmLocation:SetDesc(bmArea() .. (root and myRoot and string.format("  ·  %dm away", math.floor((root.Position - myRoot.Position).Magnitude)) or ""))
		BmStock:SetDesc(stockText())
		task.wait(0.5)
	end
	AF.enabled = false
	AF.on = false
	for _, c in ipairs(AF.conns) do pcall(function() c:Disconnect() end) end
	AF.cleanup()
end)

Window:SelectTab(1)

notify("Prison RP Hub", "Loaded. F6 toggles fishing, RightControl hides the window")
