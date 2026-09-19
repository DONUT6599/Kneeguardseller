--!nonstrict
-- amitoofast hub (lite) - same features as the full hub with the status paragraphs and
-- the one-click Start button removed. Controls only.
--
--   loadstring(game:HttpGet("<raw url>/Main.lua"))()
--
-- Status text now goes nowhere on screen; the underlying state variables are
-- still updated, so console prints or a paragraph can be re-added later.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local os_clock    = os.clock

-- Calling into the game's own ModuleScripts drops this thread's capabilities,
-- after which Fluent's theme code fails with
--   "cannot access 'Instance' (lacking capability Plugin)".
-- Restore identity before touching the UI again. Name varies by executor.
local function raiseIdentity()
	local setter = (typeof(setthreadidentity) == "function" and setthreadidentity)
		or (typeof(setidentity) == "function" and setidentity)
		or (typeof(syn) == "table" and syn.set_thread_identity)
		or (typeof(set_thread_identity) == "function" and set_thread_identity)

	if setter then
		pcall(setter, 8)
	end
end

raiseIdentity()

-- Fluent -----------------------------------------------------------------------

local okFluent, Fluent = pcall(function()
	return loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
end)

if not okFluent or Fluent == nil then
	warn("[hub] couldn't load Fluent: " .. tostring(Fluent))
	return
end

local _, SaveManager = pcall(function()
	return loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"))()
end)

local _, InterfaceManager = pcall(function()
	return loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"))()
end)

-- Game modules (all optional; each feature degrades on its own) ------------------

local function tryRequire(...)
	local node = ReplicatedStorage
	for _, name in { ... } do
		node = node and node:FindFirstChild(name)
	end
	if node == nil then
		return nil
	end
	local ok, mod = pcall(require, node)
	return ok and mod or nil
end

local Checker                 = tryRequire("CAM", "Global", "Checker")
local Combat_presets          = tryRequire("CAM", "Global", "Combat_presets")
local Character_info_provider = tryRequire("CAM", "Global", "Character_info_provider")
local Items                   = tryRequire("CAM", "Global", "Collectibles", "Items")
local Utility                 = tryRequire("CAM", "Global", "Utility")
local QuestsModule            = tryRequire("CAM", "Global", "Subsets", "Gameplay", "Quests")
local DialogueModule          = tryRequire("CAM", "Client", "Modules", "GamePlay", "Dialogue")

local CAM        = ReplicatedStorage:FindFirstChild("CAM")
local CurPower   = CAM and CAM.Client.Controllers.Skills_Provider:FindFirstChild("CurPower")
local Animations = ReplicatedStorage:FindFirstChild("Assets")
	and ReplicatedStorage.Assets:FindFirstChild("Animations")

local Event = ReplicatedStorage
	:WaitForChild("Communication")
	:WaitForChild("ServerAndClient")
	:WaitForChild("Signals")
	:WaitForChild("SignalEvent")
	:WaitForChild("Event")

--------------------------------------------------------------------------------
-- COMBAT
--------------------------------------------------------------------------------

-- Defined in the BEHIND section below; forward-declared so the combat loop
-- can refuse to swing when nothing is actually there.
local targetValid

-- Set by the BEHIND heartbeat, read by the combat loop: true while the current
-- target is blocking. Hitting into a block feeds their block meter, so back off
-- instead.
local targetShielded = false
local avoidShield    = true
local avoidDistance  = 10

-- Set when the humanoid loses health; while it holds we reposition instead of
-- standing in the same spot trading hits.
local dodgeOnHit   = true
local dodgeStuds   = 12
local dodgeTime    = 1.0
local dodgeUntil   = 0
local dodgeAngle   = 0

local playerScripts = LocalPlayer:WaitForChild("PlayerScripts", 15)
local CU            = playerScripts and playerScripts:WaitForChild("CU", 10)
local combatScript  = CU and CU:FindFirstChild("Combat")

local ComboValue = combatScript and combatScript:FindFirstChild("ComboValue")

-- Route 1: the game's own punch(), a global in CU.Combat's environment.
-- Route 2: Main_Combat_Script_Client.Do via require - full anims/effects.
-- Route 3: raw FireServer - wire-identical but no client-side effects.
local punch, Do

if combatScript ~= nil then
	if typeof(getsenv) == "function" then
		local ok, env = pcall(getsenv, combatScript)
		if ok and type(env) == "table" and type(rawget(env, "punch")) == "function" then
			punch = rawget(env, "punch")
		end
	end

	local module = combatScript:FindFirstChild("Main_Combat_Script_Client")
	if module ~= nil then
		local ok, mod = pcall(require, module)
		if ok and type(mod) == "table" and type(mod.Do) == "function" then
			Do = mod.Do
		end
	end
end

local combatRoute = punch and 1 or Do and 2 or 3
local combatRouteName = combatRoute == 1 and "punch() via getsenv"
	or combatRoute == 2 and "Do() via require"
	or "raw FireServer"

local function getEquippedCombat()
	if LocalPlayer.Character == nil or Animations == nil then
		return nil
	end

	if CurPower ~= nil then
		for _, power in ipairs(string.split(CurPower.Value, ",")) do
			if Animations:FindFirstChild(power .. "_Combat_Anims") then
				return power
			end
		end
	end

	if Character_info_provider ~= nil then
		local ok, tool = pcall(Character_info_provider.Get_equipped_tool, LocalPlayer)
		if ok and tool ~= nil then
			local item = Items and Items[tool.Name]
			if (item ~= nil and item.HasCombat) or Animations:FindFirstChild(tool.Name .. "_Combat_Anims") then
				return tool.Name
			end
		end
	end

	return nil
end

-- Tool_Accessories under the character mirrors what is ACTUALLY equipped,
-- and the model name is a Combat_presets key directly ("Regular Katana"),
-- skipping the Items[x].CombatPreset indirection. The folder carries a second
-- "<name>Sheathed1" model for the sheath, which is not a preset.
-- Empty folder = unarmed = the "Combat" preset.
local function presetFromTools()
	if Combat_presets == nil then
		return nil
	end

	local humanoids = Workspace:FindFirstChild("Humanoids")
	local char = (humanoids and humanoids:FindFirstChild(LocalPlayer.Name)) or LocalPlayer.Character
	local tools = char and char:FindFirstChild("Tool_Accessories")
	if tools == nil then
		return nil
	end

	local kids = tools:GetChildren()
	if #kids == 0 then
		-- nothing held: unarmed preset
		return Combat_presets.Presets["Combat"] and "Combat" or nil
	end

	for _, model in kids do
		local name = model.Name
		if not string.find(name, "Sheathed") and Combat_presets.Presets[name] then
			return name
		end
	end

	-- held something unrecognised; strip a trailing Sheathed<n> and retry
	for _, model in kids do
		local bare = string.gsub(model.Name, "Sheathed%d*$", "")
		if Combat_presets.Presets[bare] then
			return bare
		end
	end

	return nil
end

-- Returns preset, presetName (remote arg 2), powerName.
local function resolvePreset()
	if Combat_presets == nil then
		return nil
	end

	-- Tool_Accessories is the most direct signal; fall back to the game's own
	-- CurPower / equipped-tool chain when it tells us nothing.
	local fromTools = presetFromTools()
	if fromTools ~= nil then
		return Combat_presets.Presets[fromTools], fromTools, nil
	end

	local equipped = getEquippedCombat()
	if equipped == nil then
		return nil
	end

	local preset = Combat_presets.Presets[equipped]
	if preset ~= nil then
		return preset, equipped, nil
	end

	local item = Items and Items[equipped]
	local presetName, powerName
	if item == nil or (item.Breathing == nil and not item.HasCombat and item.CombatPreset == nil) then
		presetName, powerName = equipped, nil
	else
		presetName, powerName = item.CombatPreset or "Regular Katana", equipped
	end

	return Combat_presets.Presets[presetName], presetName, powerName
end

local lastPunch, lastCombovalue = 0, 0
local combatStatus = "off"

-- punch(): v9 = default, or final ONLY when `u4 >= Max and ComboValue < Max`.
-- Both halves matter - dropping the first charges the 1.65s recovery after
-- every hit instead of only after the finisher.
local function gapFor(preset)
	local max = preset.Max or 5
	local wait = preset.default or 0.25
	local current = ComboValue and ComboValue.Value or 1
	if lastCombovalue >= max and current < max then
		wait = preset.final or wait
	end
	return wait
end

local function combatStep()
	local preset, presetName, powerName = resolvePreset()
	if preset == nil or presetName == nil then
		combatStatus = "no combat equipped"
		return nil
	end
	if ComboValue == nil then
		combatStatus = "no ComboValue - is CU.Combat running?"
		return nil
	end

	local gap = gapFor(preset)
	local since = os_clock() - lastPunch
	if gap >= since then
		combatStatus = string.format("cooling down (%.2fs)", gap - since)
		return gap - since
	end

	if Checker ~= nil and Checker.check(LocalPlayer, "combat") ~= true then
		combatStatus = "blocked by Checker (stun / ragdoll / cutscene)"
		return nil
	end

	local max = preset.Max or 5
	local value = ComboValue.Value

	if combatRoute == 2 then
		local ok, result = pcall(Do, ComboValue, preset, presetName, powerName)
		if not ok then
			return nil
		end
		lastCombovalue = (type(result) == "table" and result.combovalue) or value
	else
		local beforeSwing = (preset.delay_before_swing and preset.delay_before_swing[value])
			or preset.default_before_swing
			or (Combat_presets and Combat_presets.Default_Swing_Wait)
			or 0
		local beforeHit = (preset.delay_before_hit and preset.delay_before_hit[value])
			or preset.default_before_hit
			or beforeSwing

		local mult = 1
		if Combat_presets and type(Combat_presets.attackSpeedMult) == "function" then
			local okMult, m = pcall(Combat_presets.attackSpeedMult, LocalPlayer)
			if okMult and type(m) == "number" and m > 0 then
				mult = m
			end
		end

		Event:FireServer("Combat_Service", presetName, value, false,
			(beforeHit - beforeSwing) / mult, false, nil)

		lastCombovalue = value
	end

	if Combat_presets then
		Combat_presets.Last_Combo = value
	end
	ComboValue.Value = (value == max or value == 7) and 1 or value + 1
	lastPunch = os_clock()
	combatStatus = string.format("punching %s combo %d/%d", presetName, value, max)

	return gapFor(preset)
end

local autoPunch = false

task.spawn(function()
	while true do
		if Fluent.Unloaded then break end

		if autoPunch and dodgeOnHit and os_clock() < dodgeUntil then
			combatStatus = "took a hit - repositioning"
			task.wait(0.1)
		elseif autoPunch and avoidShield and targetShielded then
			-- Backing off is handled by the heartbeat; just stop swinging.
			combatStatus = "target is blocking - holding off"
			task.wait(0.2)
		elseif autoPunch and behindOn and not targetValid() then
			-- Auto Farm is on but nothing selected is in the map. Swinging at
			-- air just spams the remote, so wait for a target instead.
			combatStatus = "waiting - no selected NPC nearby"
			task.wait(0.25)
		elseif autoPunch then
			local ok, wait
			if combatRoute == 1 then
				ok, wait = pcall(punch)
				-- punch() reports no reason, only its next delay.
				if not ok then
					combatStatus = "punch() errored: " .. tostring(wait)
				elseif wait == nil then
					combatStatus = "punch() refused (nothing equipped, or Checker)"
				else
					combatStatus = string.format("punching (next in %.2fs)", wait)
				end
			else
				ok, wait = pcall(combatStep)
				if not ok then
					combatStatus = "error: " .. tostring(wait)
				end
			end
			task.wait((ok and wait) or 0.25)
		else
			combatStatus = "off"
			task.wait(0.1)
		end
	end
end)

--------------------------------------------------------------------------------
-- BEHIND
--------------------------------------------------------------------------------

local behindOn       = false
local behindDistance = 3.5
local behindHeight   = 0
-- Set of NPC folder names to hunt, e.g. { Bandit = true }. Empty = anything.
local behindTargets  = { ["*Civilian*"] = true }
local behindRegion   = "Windy Peak"

local regions = Workspace:WaitForChild("Humanoids", 15)
regions = regions and regions:WaitForChild("Regions", 10)

local function regionNames()
	local names = {}
	if regions ~= nil then
		for _, region in regions:GetChildren() do
			table.insert(names, region.Name)
		end
	end
	table.sort(names)
	return names
end

local function activeNpcs()
	local region = regions and regions:FindFirstChild(behindRegion)
	return region and region:FindFirstChild("ActiveNpcs") or nil
end

-- Distinct NPC folder names present in the selected region right now.
local function npcNames()
	local names, seen = {}, {}
	local active = activeNpcs()

	if active ~= nil then
		for _, folder in active:GetChildren() do
			if folder:IsA("Folder") and not seen[folder.Name] then
				seen[folder.Name] = true
				table.insert(names, folder.Name)
			end
		end
	end

	return names
end

local function myRoot()
	local character = LocalPlayer.Character
	local humanoid  = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
end

-- Each NPC is a Folder holding a Model of the same name. Resolve by name -
-- GetChildren() order shifts as NPCs die and respawn.
local function pickTarget()
	local root = myRoot()
	local active = activeNpcs()
	if root == nil or active == nil then
		return nil
	end

	local best, bestDist, bestRoot

	for _, folder in active:GetChildren() do
		local wanted = next(behindTargets) == nil or behindTargets[folder.Name]

		if folder:IsA("Folder") and wanted then
			local model = folder:FindFirstChild(folder.Name)
			if model ~= nil and model:IsA("Model") then
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local npcRoot  = model:FindFirstChild("HumanoidRootPart")
				if humanoid ~= nil and npcRoot ~= nil and humanoid.Health > 0 then
					local dist = (npcRoot.Position - root.Position).Magnitude
					if bestDist == nil or dist < bestDist then
						best, bestDist, bestRoot = model, dist, npcRoot
					end
				end
			end
		end
	end

	return best, bestRoot
end

local target, targetRoot

local function hookHumanoid(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid == nil then return end

	local last = humanoid.Health
	humanoid.HealthChanged:Connect(function(health)
		-- only damage counts; regen must not trigger a dodge
		if health < last and dodgeOnHit then
			dodgeUntil = os_clock() + dodgeTime
			dodgeAngle = math.rad(math.random(90, 270))
		end
		last = health
	end)
end

LocalPlayer.CharacterAdded:Connect(hookHumanoid)
if LocalPlayer.Character then
	task.spawn(hookHumanoid, LocalPlayer.Character)
end

-- A blocking NPC gains an extra Frame under OverHead.Holder. Normally Holder
-- only carries List / NameHolder / AVanityTitle, plus ZHealth once damaged,
-- so a plain "Frame" child is the block indicator.
local SHIELD_FRAME = "Frame"

local function isShielded(model)
	if model == nil then
		return false
	end

	local overhead = model:FindFirstChild("OverHead", true)
	local holder = overhead and overhead:FindFirstChild("Holder")
	-- Presence alone means shielded. Holder normally carries only List /
	-- NameHolder / AVanityTitle (plus ZHealth once damaged); a child named
	-- "Frame" is added while blocking and removed afterwards. No Visible
	-- check - the element existing is the signal.
	return holder ~= nil and holder:FindFirstChild(SHIELD_FRAME) ~= nil
end

function targetValid()
	if target == nil or targetRoot == nil then
		return false
	end
	if target.Parent == nil or targetRoot.Parent == nil then
		return false
	end
	local humanoid = target:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

RunService.Heartbeat:Connect(function()
	if not behindOn or Fluent.Unloaded then
		return
	end

	local root = myRoot()
	if root == nil then
		target, targetRoot = nil, nil
		targetShielded = false
		return
	end

	if not targetValid() then
		target, targetRoot = pickTarget()
		if target == nil then
			targetShielded = false
			return
		end
	end

	-- Back off while they are blocking, rather than standing in the block.
	targetShielded = avoidShield and isShielded(target) or false
	local dodging = dodgeOnHit and os_clock() < dodgeUntil

	local distance = behindDistance
		+ (targetShielded and avoidDistance or 0)
		+ (dodging and dodgeStuds or 0)

	-- Roblox models face -Z, so +Z is behind them. While dodging, rotate round
	-- them first so we do not retreat along the line they are swinging on.
	local base = targetRoot.CFrame
	if dodging then
		base = base * CFrame.Angles(0, dodgeAngle, 0)
	end

	local spot = base * CFrame.new(0, behindHeight, distance)
	root.CFrame = CFrame.lookAt(spot.Position, targetRoot.Position)

	-- Without this, repeated CFrame sets build up velocity and fling you.
	root.AssemblyLinearVelocity  = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end)

--------------------------------------------------------------------------------
-- QUEST
--------------------------------------------------------------------------------

local function questsFolder()
	if Utility ~= nil and type(Utility.GetData) == "function" then
		local ok, data = pcall(Utility.GetData, LocalPlayer)
		if ok and data ~= nil then
			local quests = data:FindFirstChild("Quests")
			if quests ~= nil then
				return quests
			end
		end
	end

	local service = ReplicatedStorage:FindFirstChild("Player_Service")
	local all     = service and service:FindFirstChild("Data")
	local mine    = all and all:FindFirstChild(LocalPlayer.Name)
	local slots   = mine and mine:FindFirstChild("slots")

	if slots ~= nil then
		for _, slot in slots:GetChildren() do
			local quests = slot:FindFirstChild("Quests")
			if quests ~= nil and quests:FindFirstChild("Holder") ~= nil then
				return quests
			end
		end
	end
end

-- Tasks are Configurations holding Value / Max / Code, per Quests.QuestTask.
local function questLines()
	local folder = questsFolder()
	local holder = folder and folder:FindFirstChild("Holder")

	if holder == nil then
		return "no quest data"
	end

	local parts = {}

	for _, quest in holder:GetChildren() do
		local bits  = {}
		local tasks = quest:FindFirstChild("Tasks")

		if tasks ~= nil then
			for _, t in tasks:GetChildren() do
				local value = t:FindFirstChild("Value")
				local max   = t:FindFirstChild("Max")
				table.insert(bits, ("%s  %d/%d"):format(
					t.Name,
					value and value.Value or 0,
					max and max.Value or 0))
			end
		end

		table.insert(parts, ("%s\n%s"):format(quest.Name, table.concat(bits, "\n")))
	end

	if #parts == 0 then
		return "no active quests"
	end

	return table.concat(parts, "\n\n")
end

-- Quests.Holder keys ARE the accept strings - the same value Dialogue passes
-- to the server. 92 of them, most with their level gate in the name.
local function questKeys()
	local keys = {}
	if QuestsModule ~= nil and type(QuestsModule.Holder) == "table" then
		for k in pairs(QuestsModule.Holder) do
			table.insert(keys, tostring(k))
		end
	end
	table.sort(keys)
	return keys
end

local function activeQuestCount()
	local folder = questsFolder()
	local holder = folder and folder:FindFirstChild("Holder")
	return holder and #holder:GetChildren() or 0
end

-- LastTime's epoch isn't documented; ignore future or absurdly old readings
-- rather than blocking forever.
local function questCooldownLeft()
	local folder = questsFolder()
	local lastTime = folder and folder:FindFirstChild("LastTime")
	local cd = (QuestsModule and QuestsModule.QuestCD) or 30

	if lastTime == nil or lastTime.Value <= 0 then
		return 0
	end

	local elapsed = os.time() - lastTime.Value
	if elapsed < 0 or elapsed > 86400 then
		return 0
	end

	return math.max(0, cd - elapsed)
end

-- Delegates to the game's own AddQuest, which runs the Requirements /
-- WenCostOnAccept / ItemCostOnAccept / CanAddQuest gates and fires the remote
-- itself, returning a reason string on refusal.
local function acceptQuest(name)
	local fn = DialogueModule and DialogueModule.Functions and DialogueModule.Functions.AddQuest
	if type(fn) ~= "function" then
		return false, "NoAddQuestFunction"
	end

	local ok, reason = pcall(fn, name)
	if not ok then
		return false, tostring(reason)
	end
	if reason ~= nil then
		return false, tostring(reason)
	end
	return true
end

-- Quest givers are static NPCs at
--   Workspace.Debree.Regions.<Region>.StationaryNpcs.<OfferNpc>
-- NOT in ActiveNpcs, which only holds spawned combat NPCs.
local function findGiver(npcName)
	if npcName == nil then
		return nil
	end

	local debree  = Workspace:FindFirstChild("Debree")
	local regions = debree and debree:FindFirstChild("Regions")
	if regions == nil then
		return nil
	end

	for _, region in regions:GetChildren() do
		local folder = region:FindFirstChild("StationaryNpcs")
		local npc    = folder and folder:FindFirstChild(npcName)
		if npc ~= nil then
			local part = npc:IsA("Model") and (npc.PrimaryPart or npc:FindFirstChild("HumanoidRootPart"))
				or (npc:IsA("BasePart") and npc)
			if part ~= nil then
				return part.Position, region.Name
			end
		end
	end
end

local function questDef(questName)
	return QuestsModule and type(QuestsModule.Holder) == "table"
		and QuestsModule.Holder[questName] or nil
end

-- OfferNpc is the giver's NAME (a string), not a boolean.
local function questGiverName(questName)
	local def = questDef(questName)
	return def ~= nil and type(def.OfferNpc) == "string" and def.OfferNpc or nil
end

-- Position is the OBJECTIVE area, not the giver - they differ by ~145 studs
-- for "Ill take 3 bandits". Only 9 of 92 quests carry one.
local function questObjective(questName)
	local def = questDef(questName)
	return def ~= nil and typeof(def.Position) == "Vector3" and def.Position or nil
end

-- Quests in your data are named by DISPLAY name ("Defeat The Bandit Boss"),
-- while Holder is keyed by ACCEPT string ("Ill take the bandit boss(Lv 7)").
-- QuestInstance.Name bridges the two.
local function acceptKeyFor(displayName)
	if QuestsModule == nil or type(QuestsModule.Holder) ~= "table" then
		return nil
	end

	for key, def in pairs(QuestsModule.Holder) do
		if key == displayName then
			return key
		end
		local inst = def ~= nil and def.QuestInstance
		if typeof(inst) == "Instance" and inst.Name == displayName then
			return key
		end
	end
end

-- HARDCODED objective positions, keyed by ACCEPT string.
--
-- Only needed for the 12 quests that carry neither a top-level Position nor
-- any Markers. Everything else resolves from game data below. Add your own as
-- you find them - this table wins over everything.
--
-- Still blank (target unknown): Ill deliver the package (Elara),
-- Ill find the pages, Ill get this letter delivered, Ill look for it(Lv 10),
-- Ill look for the penny(Lv 14), Ill see you to Windy Peak(Lv 105),
-- Ill learn the Reaping Blades/Soryu/Tai Chi Style, Muzan Quest.
local QUEST_POSITIONS = {
	-- Village spies are the *Civilian* NPCs scattered through Windy Peak
	-- village; this is roughly the middle of them.
	["Ill help clear them out"] = Vector3.new(-607, 1245, -1110),

	-- "Report to Noote" - the objective is the NPC itself.
	["Ill bring him the notes"] = Vector3.new(-515, 1245, -1251),
}

-- Find a named NPC anywhere: spawned combat NPCs first, then static ones.
local function findNpcAnywhere(npcName)
	if npcName == nil then
		return nil
	end

	local function positionOf(inst)
		local model = inst:IsA("Model") and inst or inst:FindFirstChild(inst.Name)
		local part = model and (model.PrimaryPart or model:FindFirstChild("HumanoidRootPart"))
		return part and part.Position or nil
	end

	local humanoids = Workspace:FindFirstChild("Humanoids")
	local regionRoot = humanoids and humanoids:FindFirstChild("Regions")
	for _, region in (regionRoot and regionRoot:GetChildren() or {}) do
		local act = region:FindFirstChild("ActiveNpcs")
		local hit = act and act:FindFirstChild(npcName)
		if hit then
			local pos = positionOf(hit)
			if pos then
				return pos, region.Name
			end
		end
	end

	local pos, region = findGiver(npcName)
	return pos, region
end

-- Markers hold either an explicit Position or an { Npc = "name" } to look up.
local function markerPosition(acceptKey)
	local def = questDef(acceptKey)
	local markers = def ~= nil and def.Markers
	if type(markers) ~= "table" then
		return nil
	end

	-- explicit coordinates win; they need nothing loaded
	for label, m in pairs(markers) do
		if type(m) == "table" and typeof(m.Position) == "Vector3" then
			return m.Position, tostring(label)
		end
	end

	for label, m in pairs(markers) do
		if type(m) == "table" and type(m.Npc) == "string" then
			local pos = findNpcAnywhere(m.Npc)
			if pos ~= nil then
				return pos, tostring(label) .. " (" .. m.Npc .. ")"
			end
		end
	end

	return nil
end

-- Full resolution for one accept key, best source first.
local function questWaypoint(acceptKey)
	if acceptKey == nil then
		return nil
	end

	local hard = QUEST_POSITIONS[acceptKey]
	if hard ~= nil then
		return hard, "hardcoded"
	end

	local pos = questObjective(acceptKey)
	if pos ~= nil then
		return pos, "Position"
	end

	local mpos, label = markerPosition(acceptKey)
	if mpos ~= nil then
		return mpos, "marker: " .. tostring(label)
	end

	return nil
end

-- The objective of the quest you are actually holding, not the dropdown pick.
local function activeObjective()
	local folder = questsFolder()
	local holder = folder and folder:FindFirstChild("Holder")

	for _, quest in (holder and holder:GetChildren() or {}) do
		local key = acceptKeyFor(quest.Name)
		local pos, source = questWaypoint(key)
		if pos ~= nil then
			return pos, quest.Name, source
		end
	end
end

local function teleportTo(position)
	local root = myRoot()
	if root == nil or position == nil then
		return false
	end

	root.CFrame = CFrame.new(position + Vector3.new(0, 3, 4))
	root.AssemblyLinearVelocity  = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return true
end

--------------------------------------------------------------------------------
-- QUEST FARM
--------------------------------------------------------------------------------

-- A quest task carries a Code ("KaruVillageBandit", "VillageSpy", "Zuko") that
-- kills are credited against. That Code is resolved SERVER-side - it appears
-- nowhere on the NPC in the client's view - so mapping Code to an NPC folder
-- name needs rules rather than a lookup.
--
-- Confirmed pairs: KaruVillageBandit -> Bandit, VillageSpy -> *Civilian*,
-- Zuko -> Zuko.
local CODE_OVERRIDES = {
	VillageSpy = { "*Civilian*" },
}

local questFarm       = false
local questFarmStatus = "off"

-- Master switch: drives every other toggle from one place.
local autoAll       = false
local autoAllStatus = "off"
local autoPickQuest = true

-- Weapon state lives up here so the master loop can drive it; the Equip tab
-- assigns the item and slot further down.
local autoWeapon  = false
local toolbarItem = nil
local toolbarSlot = "One"
local combatQuestsOnly = true

-- Accept key of the quest you currently hold (data names it by display name).
local function activeQuestKey()
	local folder = questsFolder()
	local holder = folder and folder:FindFirstChild("Holder")
	for _, quest in (holder and holder:GetChildren() or {}) do
		return acceptKeyFor(quest.Name), quest.Name
	end
end

-- Quests worth auto-running, cheapest level first. BossHunt and Muzan are
-- excluded: they are repeatable bounties with no OfferNpc to travel to.
--
-- combatQuestsOnly keeps just Category == "Combat". The rest are things this
-- hub cannot do - Dialogue is fetch/deliver, Fishing needs the minigame - and
-- taking one stalls the loop on an objective it can never finish.
local questPlanCache, questPlanKey = nil, nil

local function questPlan()
	local cacheKey = combatQuestsOnly and "combat" or "all"
	if questPlanCache ~= nil and questPlanKey == cacheKey then
		return questPlanCache
	end

	local list = {}
	if QuestsModule ~= nil and type(QuestsModule.Holder) == "table" then
		for key, def in pairs(QuestsModule.Holder) do
			local category = tostring(def.Category or "")
			local giver = type(def.OfferNpc) == "string" and def.OfferNpc or nil
			local wanted = category ~= "BossHunt" and category ~= "Muzan"
				and (not combatQuestsOnly or category == "Combat")
			if giver ~= nil and wanted then
				-- level gate is written into the key, e.g. "(Lv 25)"
				local lvl = tonumber(string.match(key, "%(Lv (%d+)%)")) or 0
				table.insert(list, { key = key, level = lvl, giver = giver })
			end
		end
	end

	table.sort(list, function(a, b)
		if a.level ~= b.level then
			return a.level < b.level
		end
		return a.key < b.key
	end)

	questPlanCache = list
	questPlanKey = combatQuestsOnly and "combat" or "all"
	return list
end

-- First quest the game itself says you may accept. CanAddQuest covers the
-- level gate, already-completed, and the max-quests rule, so we do not have to
-- reimplement any of it.
local function nextEligibleQuest()
	if QuestsModule == nil or type(QuestsModule.CanAddQuest) ~= "function" then
		return nil
	end

	for _, entry in questPlan() do
		local ok, allowed = pcall(QuestsModule.CanAddQuest, entry.key)
		if ok and allowed then
			-- only bother if we can actually reach the giver
			if findGiver(entry.giver) ~= nil then
				return entry.key, entry.giver
			end
		end
	end
end

-- True when you hold a quest and every task on it is at Max.
local function allTasksComplete()
	local folder = questsFolder()
	local holder = folder and folder:FindFirstChild("Holder")
	local any, complete = false, true

	for _, quest in (holder and holder:GetChildren() or {}) do
		local tasks = quest:FindFirstChild("Tasks")
		for _, t in (tasks and tasks:GetChildren() or {}) do
			any = true
			local v = t:FindFirstChild("Value")
			local m = t:FindFirstChild("Max")
			if not (v and m and m.Value > 0 and v.Value >= m.Value) then
				complete = false
			end
		end
	end

	return any and complete
end

-- Task Codes for every quest you currently hold.
local function activeTaskCodes()
	local folder = questsFolder()
	local holder = folder and folder:FindFirstChild("Holder")
	local codes = {}

	for _, quest in (holder and holder:GetChildren() or {}) do
		local tasks = quest:FindFirstChild("Tasks")
		for _, t in (tasks and tasks:GetChildren() or {}) do
			local code  = t:FindFirstChild("Code")
			local value = t:FindFirstChild("Value")
			local max   = t:FindFirstChild("Max")
			local done  = value and max and max.Value > 0 and value.Value >= max.Value

			if code ~= nil and code.Value ~= "" and not done then
				table.insert(codes, code.Value)
			end
		end
	end

	return codes
end

-- Which NPC folder names in the current region satisfy those Codes.
local function resolveQuestTargets()
	local codes = activeTaskCodes()
	if #codes == 0 then
		return {}, "no unfinished quest task"
	end

	local active = activeNpcs()
	if active == nil then
		return {}, "region has no ActiveNpcs"
	end

	local present = {}
	for _, folder in active:GetChildren() do
		if folder:IsA("Folder") then
			present[folder.Name] = true
		end
	end

	local picked = {}

	for _, code in codes do
		local lowerCode = string.lower(code)

		-- 1. exact match (Zuko)
		if present[code] then
			picked[code] = true
		end

		-- 2. explicit override (VillageSpy -> *Civilian*)
		for _, name in (CODE_OVERRIDES[code] or {}) do
			if present[name] then
				picked[name] = true
			end
		end

		-- 3. folder name appears inside the Code (Bandit in KaruVillageBandit)
		for name in pairs(present) do
			local bare = string.lower((string.gsub(name, "%*", "")))
			if #bare > 2 and string.find(lowerCode, bare, 1, true) then
				picked[name] = true
			end
		end
	end

	-- 4. last resort: asterisk-wrapped names are quest-marked variants
	if next(picked) == nil then
		for name in pairs(present) do
			if string.match(name, "^%*.+%*$") then
				picked[name] = true
			end
		end
	end

	if next(picked) == nil then
		return {}, "no NPC here matches " .. table.concat(codes, "/")
	end

	local names = {}
	for name in pairs(picked) do
		table.insert(names, name)
	end
	table.sort(names)

	return picked, table.concat(names, ", ") .. "  <- " .. table.concat(codes, "/")
end

-- While on, this drives behindTargets instead of the dropdown.
task.spawn(function()
	while true do
		if Fluent.Unloaded then break end

		if questFarm then
			local ok, picked, note = pcall(resolveQuestTargets)
			if ok then
				questFarmStatus = note
				if next(picked) ~= nil then
					behindTargets = picked
				else
					-- An empty set means "anything" to pickTarget, which is the
					-- opposite of what we want here. Use a name no folder can
					-- have so nothing matches and the combat loop idles.
					behindTargets = { ["__no_target__"] = true }
				end
			else
				questFarmStatus = "error: " .. tostring(picked)
			end
			task.wait(2)
		else
			questFarmStatus = "off"
			task.wait(0.5)
		end
	end
end)

--------------------------------------------------------------------------------
-- LOOT
--------------------------------------------------------------------------------

local tpToGiver  = true
local questStatus = "off"

local lootOn     = false
local lootRange  = 0      -- 0 = ignore distance entirely
local lootFolder = Workspace:FindFirstChild("LootDrops")

-- Executors name this differently; fall back to driving the prompt by hand.
local function fireProx(prompt)
	local fn = (typeof(fireproximityprompt) == "function" and fireproximityprompt)
		or (typeof(fireprox) == "function" and fireprox)
		or (typeof(syn) == "table" and syn.fireproximityprompt)

	if fn then
		return pcall(fn, prompt)
	end

	-- Manual path: only works in range and without line-of-sight blocking.
	return pcall(function()
		local hold = prompt.HoldDuration
		prompt.HoldDuration = 0
		prompt:InputHoldBegin()
		prompt:InputHoldEnd()
		prompt.HoldDuration = hold
	end)
end

local function lootOnce()
	if lootFolder == nil then
		lootFolder = Workspace:FindFirstChild("LootDrops")
		if lootFolder == nil then
			return 0
		end
	end

	local root = myRoot()
	local fired = 0

	-- Every drop is its own child; never index a fixed .LootDrop.
	for _, drop in lootFolder:GetChildren() do
		local prompt = drop:FindFirstChildWhichIsA("ProximityPrompt", true)

		if prompt ~= nil and prompt.Enabled then
			local inRange = true

			if lootRange > 0 and root ~= nil then
				local part = prompt.Parent
				if part ~= nil and part:IsA("BasePart") then
					inRange = (part.Position - root.Position).Magnitude <= lootRange
				end
			end

			if inRange and fireProx(prompt) then
				fired = fired + 1
			end
		end
	end

	return fired
end

task.spawn(function()
	while true do
		if Fluent.Unloaded then break end

		if lootOn then
			pcall(lootOnce)
			task.wait(0.3)
		else
			task.wait(0.3)
		end
	end
end)

--------------------------------------------------------------------------------
-- EQUIP
--------------------------------------------------------------------------------

-- Remote: FireServer("AccessoryEquip", <slot>, <itemId>, <category>)
-- itemId is the per-save-slot serial from Inventory.HighestId, NOT a global
-- item type id - confirmed by cross-referencing another player's equipped
-- slots against their inventory. Never hardcode one.
local EQUIP_SLOTS      = { "One", "Two", "Three", "Four", "Five" }
local EQUIP_CATEGORIES = { "Stats", "Vanity" }

local function playerData()
	if Utility ~= nil and type(Utility.GetData) == "function" then
		local ok, data = pcall(Utility.GetData, LocalPlayer)
		if ok and data ~= nil then
			return data
		end
	end

	local service = ReplicatedStorage:FindFirstChild("Player_Service")
	local all     = service and service:FindFirstChild("Data")
	local mine    = all and all:FindFirstChild(LocalPlayer.Name)
	local slots   = mine and mine:FindFirstChild("slots")

	if slots ~= nil then
		for _, slot in slots:GetChildren() do
			if slot:FindFirstChild("Inventory") ~= nil then
				return slot
			end
		end
	end
end

-- Owned items live in Inventory.Inventory, each with an Id child.
local function inventoryItems()
	local data  = playerData()
	local outer = data and data:FindFirstChild("Inventory")
	local inner = outer and outer:FindFirstChild("Inventory")
	local items = {}

	if inner ~= nil then
		for _, item in inner:GetChildren() do
			local id     = item:FindFirstChild("Id")
			local amount = item:FindFirstChild("Amount")
			table.insert(items, {
				name   = item.Name,
				id     = id and id.Value or nil,
				amount = amount and amount.Value or 1,
			})
		end
	end

	table.sort(items, function(a, b)
		return (a.id or 0) < (b.id or 0)
	end)

	return items
end


local function findItemId(name)
	for _, item in inventoryItems() do
		if item.name == name then
			return item.id
		end
	end
end

local function equippedSlots(category)
	local data   = playerData()
	local inv    = data and data:FindFirstChild("Inventory")
	local acc    = inv and inv:FindFirstChild("Accessories")
	local folder = acc and acc:FindFirstChild(category or "Stats")
	local out = {}

	if folder ~= nil then
		for _, slot in folder:GetChildren() do
			out[slot.Name] = slot.Value
		end
	end

	return out
end

local function equipAccessory(item, slot, category)
	slot     = slot or "One"
	category = category or "Stats"

	local id = item
	if type(item) == "string" then
		id = findItemId(item)
		if id == nil then
			return false, "not in inventory: " .. tostring(item)
		end
	end

	if type(id) ~= "number" then
		return false, "item must be a name or numeric id"
	end

	Event:FireServer("AccessoryEquip", slot, id, category)
	return true
end

-- Fire-and-forget remote, so confirm the slot actually changed.
local function equipAndWait(item, slot, category, timeout)
	slot     = slot or "One"
	category = category or "Stats"

	local before = equippedSlots(category)[slot]
	local ok, reason = equipAccessory(item, slot, category)
	if not ok then
		return false, reason
	end

	local deadline = os_clock() + (timeout or 2)
	repeat
		task.wait(0.1)
	until equippedSlots(category)[slot] ~= before or os_clock() > deadline

	if equippedSlots(category)[slot] ~= before then
		return true
	end
	return false, "NotApplied"
end

-- Toolbar holds weapons / fighting styles, separate from Accessories.
--   FireServer("Toolbar_Equip", slot, itemId)   -- 3 args, no category
local TOOLBAR_SLOTS = { "One", "Two", "Three", "Four", "Five" }

local function toolbarSlots()
	local data = playerData()
	local inv  = data and data:FindFirstChild("Inventory")
	local tb   = inv and inv:FindFirstChild("Toolbar")
	local out = {}
	for _, slot in (tb and tb:GetChildren() or {}) do
		out[slot.Name] = slot.Value
	end
	return out
end

-- Items worth putting on the toolbar: anything flagged HasCombat.
local function combatItems()
	local names = {}
	for _, item in inventoryItems() do
		local def = Items and Items[item.name]
		if def ~= nil and def.HasCombat then
			table.insert(names, item.name)
		end
	end
	table.sort(names)
	if #names == 0 then
		table.insert(names, "<none>")
	end
	return names
end

-- Toolbar slots are raw key input, not InputHandler actions - GetMapping()
-- returns nil and no "Slot1"/"Toolbar1" action is bound - so pressing the
-- number key is the only way to actually DRAW the weapon.
--
-- Toolbar_Equip only puts an item INTO a slot; until the key is pressed,
-- Tool_Accessories stays empty and the combat preset resolves to nothing.
local VirtualInput = nil
pcall(function() VirtualInput = game:GetService("VirtualInputManager") end)

local SLOT_KEYS = {
	One   = Enum.KeyCode.One,
	Two   = Enum.KeyCode.Two,
	Three = Enum.KeyCode.Three,
	Four  = Enum.KeyCode.Four,
	Five  = Enum.KeyCode.Five,
}

local function pressSlotKey(slotName)
	local key = SLOT_KEYS[slotName]
	if key == nil then
		return false, "bad slot " .. tostring(slotName)
	end
	if VirtualInput == nil then
		return false, "no VirtualInputManager"
	end

	local ok = pcall(function()
		VirtualInput:SendKeyEvent(true, key, false, game)
		task.wait(0.05)
		VirtualInput:SendKeyEvent(false, key, false, game)
	end)

	return ok, ok and "pressed" or "SendKeyEvent failed"
end

-- Is anything actually drawn right now?
local function weaponDrawn()
	local humanoids = Workspace:FindFirstChild("Humanoids")
	local char = (humanoids and humanoids:FindFirstChild(LocalPlayer.Name)) or LocalPlayer.Character
	local tools = char and char:FindFirstChild("Tool_Accessories")
	return tools ~= nil and #tools:GetChildren() > 0
end

local function toolbarEquip(itemName, slot)
	slot = slot or "One"

	local id = findItemId(itemName)
	if id == nil then
		return false, "not in inventory: " .. tostring(itemName)
	end

	local before = toolbarSlots()[slot]
	Event:FireServer("Toolbar_Equip", slot, id)

	local deadline = os_clock() + 2
	repeat
		task.wait(0.1)
	until toolbarSlots()[slot] ~= before or os_clock() > deadline

	if toolbarSlots()[slot] ~= before then
		return true
	end
	return false, "NotApplied"
end

-- Human-readable toolbar + what combat preset that resolves to.
local function equipStatus()
	local slots = toolbarSlots()
	local byId = {}
	for _, item in inventoryItems() do
		if item.id then byId[item.id] = item.name end
	end

	local bits = {}
	for _, slot in TOOLBAR_SLOTS do
		local id = slots[slot] or 0
		if id ~= 0 then
			table.insert(bits, slot .. ": " .. (byId[id] or ("id " .. tostring(id))))
		end
	end

	local line = #bits > 0 and table.concat(bits, "\n") or "toolbar empty"

	local _, presetName = resolvePreset()
	return line .. "\npreset: " .. tostring(presetName or "none - nothing equipped")
end

-- Stats arrive on wildly different scales ("Additional Damage Factor" is
-- ~0.02-0.05 while "Max Health" is 10-150), so weights normalise them into one
-- comparable number. These are a judgement call, not read from the game.
local EQUIP_MODES = {
	balanced = {
		["Additional Damage Factor"] = 1000, ["Additional Damage"] = 10,
		["Damage Reduction Factor"] = 800,   ["Damage Reduction"] = 8,
		["Max Health Factor"] = 600,         ["Max Health"] = 1,
		["Max Stamina"] = 0.8,               ["Movement Speed Factor"] = 600,
		["Health Regen Speed"] = 4,          ["Stamina Regen Speed"] = 3,
		["Block Points"] = 4,                ["Block Regen"] = 4,
	},
	damage = { ["Additional Damage Factor"] = 1000, ["Additional Damage"] = 10 },
	tank = {
		["Max Health"] = 1, ["Max Health Factor"] = 600,
		["Damage Reduction Factor"] = 800, ["Damage Reduction"] = 8,
		["Health Regen Speed"] = 4, ["Block Points"] = 4, ["Block Regen"] = 4,
	},
	stamina = { ["Max Stamina"] = 1, ["Stamina Regen Speed"] = 4 },
	speed = { ["Movement Speed Factor"] = 1000 },
}

local function scoreItem(name, mode)
	local def = Items and Items[name]
	local stats = def and def.Stats
	if type(stats) ~= "table" then
		return nil
	end

	local weights = EQUIP_MODES[mode or "balanced"] or EQUIP_MODES.balanced
	local score = 0
	for key, value in pairs(stats) do
		if type(value) == "number" then
			score = score + value * (weights[key] or 0)
		end
	end
	return score
end

local function rankedItems(mode)
	local ranked = {}
	for _, item in inventoryItems() do
		local score = scoreItem(item.name, mode)
		if score ~= nil then
			table.insert(ranked, { name = item.name, id = item.id, score = score })
		end
	end
	table.sort(ranked, function(a, b)
		return a.score > b.score
	end)
	return ranked
end

-- Slot/EquipType compatibility rules are unknown - one player has EquipType=3
-- items across all five Stats slots while another has an EquipType=5 haori in
-- Stats.One - so assign greedily and verify each landed rather than assume.
local function equipBest(mode, category, dryRun)
	category = category or "Stats"
	local ranked = rankedItems(mode)

	if #ranked == 0 then
		return { note = "no owned item has a Stats field", equipped = {}, failed = {}, skipped = {} }
	end

	local already = equippedSlots(category)
	local taken = {}
	for _, value in pairs(already) do
		if value ~= 0 then
			taken[value] = true
		end
	end

	local report = { equipped = {}, failed = {}, skipped = {} }
	local index = 1

	for _, slot in EQUIP_SLOTS do
		while index <= #ranked and taken[ranked[index].id] do
			table.insert(report.skipped, ranked[index].name)
			index = index + 1
		end
		if index > #ranked then
			break
		end

		local pick = ranked[index]

		if already[slot] == pick.id then
			table.insert(report.skipped, pick.name)
		elseif dryRun then
			table.insert(report.equipped, pick.name .. " -> " .. slot)
		else
			local ok, reason = equipAndWait(pick.id, slot, category)
			if ok then
				table.insert(report.equipped, pick.name .. " -> " .. slot)
				taken[pick.id] = true
			else
				table.insert(report.failed, pick.name .. " -> " .. slot .. ": " .. tostring(reason))
			end
		end

		index = index + 1
	end

	return report
end


-- Quest givers carry a ProximityPrompt at <Npc>.HumanoidRootPart.<Npc>,
-- tagged "Dialogue", key T, HoldDuration 0, MaxActivationDistance 10.
-- Componentloader listens on PromptTriggered and opens the dialogue from it,
-- so firing the prompt is the same as pressing T.
local function findDialoguePrompt(npcName)
	if npcName == nil then return nil end

	local debree = Workspace:FindFirstChild("Debree")
	local regions = debree and debree:FindFirstChild("Regions")

	for _, region in (regions and regions:GetChildren() or {}) do
		local sf = region:FindFirstChild("StationaryNpcs")
		local npc = sf and sf:FindFirstChild(npcName)
		if npc then
			for _, d in npc:GetDescendants() do
				if d:IsA("ProximityPrompt") and d.Enabled then
					return d
				end
			end
		end
	end
end

-- Componentloader ignores PromptTriggered unless prompts are visible, so make
-- sure that flag is on before firing - otherwise nothing happens at all.
local function allowPrompts()
	local cam = ReplicatedStorage:FindFirstChild("CAM")
	local layout = cam and cam.Client and cam.Client:FindFirstChild("Components")
	layout = layout and layout:FindFirstChild("Layout")
	local vis = layout and layout:FindFirstChild("Visibility")
	local prompts = vis and vis:FindFirstChild("Prompts")
	if prompts ~= nil and prompts.Value == false then
		pcall(function() prompts.Value = true end)
	end
end

-- Walk up to the NPC and press T on them.
local function talkTo(npcName)
	local prompt = findDialoguePrompt(npcName)
	if prompt == nil then
		return false, "no dialogue prompt on " .. tostring(npcName)
	end

	-- get inside MaxActivationDistance; firing bypasses it but the server
	-- still cares where you are standing
	local part = prompt.Parent
	if part and part:IsA("BasePart") then
		teleportTo(part.Position)
		task.wait(0.3)
	end

	allowPrompts()

	local ok = fireProx(prompt)
	return ok and true or false, ok and "talked" or "fire failed"
end

--------------------------------------------------------------------------------
-- TRAVEL
--------------------------------------------------------------------------------

-- Region hubs are SpawnCrystal models under Workspace.Debree.Regions.<Region>.
-- Their parts are not streamed in, so GetPivot() is the only way to read a
-- position off them - PrimaryPart and GetChildren() both come back empty.
local function regionHubs()
	local out, order = {}, {}
	local debree = Workspace:FindFirstChild("Debree")
	local regions = debree and debree:FindFirstChild("Regions")

	for _, region in (regions and regions:GetChildren() or {}) do
		for _, c in region:GetChildren() do
			if string.find(c.Name, "SpawnCrystal") and c:IsA("Model") then
				local ok, cf = pcall(function() return c:GetPivot() end)
				if ok then
					local label = tostring(c:GetAttribute("SpawnArea") or region.Name)
					if out[label] == nil then
						out[label] = cf.Position
						table.insert(order, label)
					end
				end
			end
		end
	end

	table.sort(order)
	return out, order
end

local BREATHING_TRAINERS = {
	"Flame Trainer Rengu", "Insect Trainer Shinora", "Serpent Trainer Obari",
	"Sound Trainer Tengai", "Stone Trainer Gyorei", "Thunder Trainer Zentaro",
	"Water Trainer Urokodaki", "Wind Trainer Saneri",
}

-- Trainers are StationaryNpcs, which only stream in near their region, so their
-- positions cannot all be read from one spot. Seeded with the two that were
-- reachable; the rest fill in automatically the first time one is seen.
local TRAINER_POSITIONS = {
	-- read live from StationaryNpcs
	["Flame Trainer Rengu"]     = Vector3.new(-967, 1025, 1188),
	["Serpent Trainer Obari"]   = Vector3.new(36, 1307, -1179),
	-- supplied as CFrames; only the position component is used
	["Insect Trainer Shinora"]  = Vector3.new(-1798.93994, 350.16803, -189.343994),
	["Sound Trainer Tengai"]    = Vector3.new(464.881012, 1487.79883, -3272.79712),
	["Stone Trainer Gyorei"]    = Vector3.new(2578.58301, 1091.5, -828.401001),
	["Thunder Trainer Zentaro"] = Vector3.new(1970.1803, 1662.5, -609.810913),
	["Water Trainer Urokodaki"] = Vector3.new(667.17395, 1021, -228.240005),
	["Wind Trainer Saneri"]     = Vector3.new(-275.575989, 1189.98682, -3436.65308),
}

-- Record any trainer currently loaded. Returns how many were newly learned.
local function scanTrainers()
	local learned = {}
	for _, name in BREATHING_TRAINERS do
		if TRAINER_POSITIONS[name] == nil then
			local pos = findNpcAnywhere(name)
			if pos ~= nil then
				TRAINER_POSITIONS[name] = pos
				table.insert(learned, name)
			end
		end
	end
	return learned
end

-- Live lookup first (it may have moved), then whatever we have recorded.
local function trainerPosition(name)
	local pos = findNpcAnywhere(name)
	if pos ~= nil then
		TRAINER_POSITIONS[name] = pos
		return pos, "live"
	end

	local known = TRAINER_POSITIONS[name]
	if known ~= nil then
		return known, "recorded"
	end

	return nil
end

--------------------------------------------------------------------------------
-- CLAN SPIN
--------------------------------------------------------------------------------

-- Two remotes, in this order (verified in game):
--   SignalFunction.Function:InvokeServer("ClanSpin")  -> returns the clan NAME
--   SignalEvent.Event:FireServer("ClanSpinComplete")  -> acknowledges it
--
-- The roll applies IMMEDIATELY - data.Clan is overwritten each spin and there
-- is no claim step, so there is no safety net: one more spin replaces whatever
-- you just rolled. ClanBag stayed empty across 30 spins, so it is for
-- something else.
--
-- Rarity ladder skips 4:
--   1 Common(60%)  2 Uncommon(23%)  3 Rare(12%)
--   5 Legendary(4%)  6 Mythic(0.9%)  7 Supreme(0.1%)
local Signals = ReplicatedStorage
	:WaitForChild("Communication")
	:WaitForChild("ServerAndClient")
	:WaitForChild("Signals")

local SpinFunction = Signals:WaitForChild("SignalFunction"):WaitForChild("Function")

local ClansModule = nil
do
	local cam = ReplicatedStorage:FindFirstChild("CAM")
	local node = cam and cam:FindFirstChild("Clans")
	if node then
		local ok, mod = pcall(require, node)
		ClansModule = ok and mod or nil
	end
end

local SPIN_COST = 1
do
	local ok, Clan = pcall(function()
		return require(ReplicatedStorage.CAM.Global.Spinners.Clan)
	end)
	if ok and type(Clan) == "table" and type(Clan.Cost) == "number" then
		SPIN_COST = math.max(1, Clan.Cost)
	end
end

local RARITY_LABELS = {
	["1 Common"] = 1, ["2 Uncommon"] = 2, ["3 Rare"] = 3,
	["5 Legendary"] = 5, ["6 Mythic"] = 6, ["7 Supreme"] = 7,
}
local RARITY_ORDER = { "1 Common", "2 Uncommon", "3 Rare", "5 Legendary", "6 Mythic", "7 Supreme" }

local autoSpin       = false
local spinMinRarity  = 5          -- stop at Legendary or better
local spinStatus     = "off"
local spinLast       = "-"

local function spinningFolder()
	local data = playerData()
	return data and data:FindFirstChild("Spinning") or nil
end

local function spinsLeft()
	local sp = spinningFolder()
	local paid = sp and sp:FindFirstChild("Spins")
	local free = sp and sp:FindFirstChild("FreeClanSpins")
	return (paid and paid.Value or 0) + (free and free.Value or 0)
end

local function currentClan()
	local data = playerData()
	local c = data and data:FindFirstChild("Clan")
	return c and tostring(c.Value) or "?"
end

-- name -> rarity number, label
local function clanTier(name)
	if ClansModule == nil or type(ClansModule.TierOf) ~= "function" then
		return 0, "?"
	end
	local ok, t = pcall(ClansModule.TierOf, name)
	if ok and type(t) == "table" then
		return tonumber(t.rarity) or 0, tostring(t.name)
	end
	return 0, "?"
end

-- One spin. Returns ok, clanName, rarity, label.
local function spinOnce()
	local ok, result = pcall(function()
		return SpinFunction:InvokeServer("ClanSpin")
	end)

	if not ok then
		return false, tostring(result)
	end

	pcall(function()
		Event:FireServer("ClanSpinComplete")
	end)

	local name = tostring(result)
	local rarity, label = clanTier(name)

	-- The invoke returns the clan name directly; fall back to live data if not.
	if rarity == 0 then
		name = currentClan()
		rarity, label = clanTier(name)
	end

	return true, name, rarity, label
end

task.spawn(function()
	local stalls = 0

	while true do
		if Fluent.Unloaded then break end

		if autoSpin then
			local before = spinsLeft()

			if before < SPIN_COST then
				spinStatus = "out of spins"
				autoSpin = false
			else
				local ok, name, rarity, label = spinOnce()

				if not ok then
					spinStatus = "invoke failed: " .. tostring(name)
					autoSpin = false
				else
					spinLast = name .. " [" .. tostring(label) .. "]"
					spinStatus = string.format("%d left - last %s", spinsLeft(), spinLast)

					if rarity >= spinMinRarity then
						spinStatus = "FOUND " .. spinLast .. " - stopped"
						autoSpin = false
					elseif spinsLeft() >= before then
						-- count never dropped: something is refusing
						stalls = stalls + 1
						if stalls >= 3 then
							spinStatus = "spin count never dropped - stopped"
							autoSpin = false
						end
					else
						stalls = 0
					end
				end
			end

			task.wait(0.35)
		else
			task.wait(0.4)
		end
	end
end)

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

-- Read the live tree BEFORE building UI, then restore identity once.
local regionNamesCached = regionNames()
local npcNamesCached    = npcNames()
local questKeysCached   = questKeys()
local combatItemsCached = combatItems()
raiseIdentity()

local Window = Fluent:CreateWindow({
	Title = "amitoofast",
	SubTitle = "powered by DEXAI & donut",
	TabWidth = 150,
	Size = UDim2.fromOffset(560, 440),
	Acrylic = false,  -- blur can be detectable; off by default
	Theme = "Dark",
	MinimizeKey = Enum.KeyCode.RightControl,
})

local Tabs = {
	Combat   = Window:AddTab({ Title = "Combat",   Icon = "swords" }),
	Position = Window:AddTab({ Title = "Position", Icon = "crosshair" }),
	Quest    = Window:AddTab({ Title = "Quest",    Icon = "scroll-text" }),
	Loot     = Window:AddTab({ Title = "Loot",     Icon = "package" }),
	Equip    = Window:AddTab({ Title = "Equip",    Icon = "shirt" }),
	Travel   = Window:AddTab({ Title = "Travel",   Icon = "map" }),
	Spin     = Window:AddTab({ Title = "Spin",     Icon = "dices" }),
	Settings = Window:AddTab({ Title = "Settings", Icon = "settings" }),
}

-- Combat ----------------------------------------------------------------------

-- One switch for the whole farm loop: hold position behind the target AND
-- run the combo. Keeping these separate meant two clicks for the only
-- combination that is actually useful.
local farmToggle = Tabs.Combat:AddToggle("AutoFarm", {
	Title = "Auto Farm",
	Description = "Teleports behind the nearest selected enemy and runs the combo",
	Default = false,
})

farmToggle:OnChanged(function(value)
	autoPunch = value
	behindOn  = value
	if not value then
		target, targetRoot = nil, nil
	end
end)

-- One click: accept -> travel -> fight -> loot -> repeat.
local autoAllToggle = Tabs.Combat:AddToggle("AutoAll", {
	Title = "AUTO FARM (smart)",
	Description = "Accepts a quest, travels to it, kills what it needs, loots, repeats",
	Default = false,
})

autoAllToggle:OnChanged(function(value)
	autoAll = value
	if not value then
		-- hand control back rather than leaving the sub-toggles stuck on
		autoPunch, behindOn, lootOn, questFarm = false, false, false, false
		autoWeapon = false
		target, targetRoot = nil, nil
	end
end)

local autoPickToggle = Tabs.Combat:AddToggle("AutoPickQuest", {
	Title = "Pick quests automatically",
	Description = "Works down the quest list by level, using the game's own CanAddQuest",
	Default = true,
})

autoPickToggle:OnChanged(function(value)
	autoPickQuest = value
end)

local combatOnlyToggle = Tabs.Combat:AddToggle("CombatQuestsOnly", {
	Title = "Kill quests only",
	Description = "Skip fetch, delivery and fishing quests - nothing automates those",
	Default = true,
})

combatOnlyToggle:OnChanged(function(value)
	combatQuestsOnly = value
	questPlanCache = nil
end)

local questFarmToggle = Tabs.Combat:AddToggle("AutoFarmQuest", {
	Title = "Auto Farm Quest",
	Description = "Overrides the target list with whatever your quest needs",
	Default = false,
})

questFarmToggle:OnChanged(function(value)
	questFarm = value
	target, targetRoot = nil, nil
end)

-- Turns a silent no-op into a visible reason. "no combat equipped" is the one
-- that bites - nothing else in the game reports it.
-- Position ----------------------------------------------------------------------

-- The on/off switch lives on the Combat tab as "Auto Farm"; these are its
-- settings.
local regionDropdown = Tabs.Position:AddDropdown("Region", {
	Title = "Region",
	Values = regionNamesCached,
	Multi = false,
	Default = 1,
})

regionDropdown:SetValue(behindRegion)

local targetDropdown = Tabs.Position:AddDropdown("Target", {
	Title = "Targets",
	Description = "Pick any number. None = nearest of anything. Ignored while Auto Farm Quest is on.",
	Values = npcNamesCached,
	Multi = true,
	Default = {},
})

regionDropdown:OnChanged(function(value)
	behindRegion = value
	target, targetRoot = nil, nil
	-- NPC names are per-region, so refresh the list and drop stale picks.
	local names = npcNames()
	raiseIdentity()
	targetDropdown:SetValues(names)
	behindTargets = {}
end)

-- Multi dropdowns hand back a SET: { ["Bandit"] = true }. Copy it rather than
-- aliasing, since Fluent reuses its own table.
targetDropdown:OnChanged(function(value)
	local picked = {}
	if type(value) == "table" then
		for name, on in pairs(value) do
			if on then
				picked[name] = true
			end
		end
	end
	behindTargets = picked
	target, targetRoot = nil, nil
end)

-- OnChanged fires on registration, so set the default after wiring it up.
if table.find(npcNamesCached, "*Civilian*") then
	targetDropdown:SetValue({ ["*Civilian*"] = true })
end

Tabs.Position:AddButton({
	Title = "Rescan NPCs",
	Description = "Reload the target list from the current region",
	Callback = function()
		local names = npcNames()
		raiseIdentity()
		targetDropdown:SetValues(names)
		Fluent:Notify({ Title = "amitoofast", Content = "NPC list refreshed", Duration = 3 })
	end,
})

local avoidToggle = Tabs.Position:AddToggle("AvoidShield", {
	Title = "Avoid shield",
	Description = "Back off and stop swinging while the target is blocking",
	Default = true,
})

avoidToggle:OnChanged(function(value)
	avoidShield = value
	if not value then
		targetShielded = false
	end
end)

local dodgeToggle = Tabs.Position:AddToggle("DodgeOnHit", {
	Title = "Dodge when hit",
	Description = "Swing round to a new angle after taking damage",
	Default = true,
})

dodgeToggle:OnChanged(function(value)
	dodgeOnHit = value
	if not value then
		dodgeUntil = 0
	end
end)

local dodgeStudsSlider = Tabs.Position:AddSlider("DodgeStuds", {
	Title = "Dodge distance",
	Default = 12,
	Min = 0,
	Max = 40,
	Rounding = 0,
})

dodgeStudsSlider:OnChanged(function(value)
	dodgeStuds = value
end)

local dodgeTimeSlider = Tabs.Position:AddSlider("DodgeTime", {
	Title = "Dodge time",
	Description = "Seconds to stay off after a hit",
	Default = 1,
	Min = 0,
	Max = 5,
	Rounding = 1,
})

dodgeTimeSlider:OnChanged(function(value)
	dodgeTime = value
end)

local avoidSlider = Tabs.Position:AddSlider("AvoidDistance", {
	Title = "Back off by",
	Description = "Extra studs to retreat while they block",
	Default = 10,
	Min = 0,
	Max = 40,
	Rounding = 0,
})

avoidSlider:OnChanged(function(value)
	avoidDistance = value
end)

local distanceSlider = Tabs.Position:AddSlider("BehindDistance", {
	Title = "Distance",
	Description = "Studs behind the target",
	Default = behindDistance,
	Min = 1,
	Max = 15,
	Rounding = 1,
})

distanceSlider:OnChanged(function(value)
	behindDistance = value
end)

local heightSlider = Tabs.Position:AddSlider("BehindHeight", {
	Title = "Height",
	Default = behindHeight,
	Min = -10,
	Max = 10,
	Rounding = 1,
})

heightSlider:OnChanged(function(value)
	behindHeight = value
end)

-- Quest -------------------------------------------------------------------------

-- Static placeholder on purpose: calling questLines() here would run game
-- code mid-constructor and strip the capabilities Fluent needs. The refresh
-- loop below fills it in a moment later.
Tabs.Quest:AddButton({
	Title = "Refresh now",
	Callback = function()
		local text = questLines()
		raiseIdentity()
	end,
})

local selectedQuest = questKeysCached[1]

local questDropdown = Tabs.Quest:AddDropdown("QuestPick", {
	Title = "Quest",
	Description = #questKeysCached .. " available - the (Lv n) suffix is its level gate",
	Values = questKeysCached,
	Multi = false,
	Default = 1,
})

questDropdown:OnChanged(function(value)
	selectedQuest = value
end)

Tabs.Quest:AddButton({
	Title = "Accept selected quest",
	Description = "Runs the game's own gates and reports the refusal reason",
	Callback = function()
		if selectedQuest == nil then
			return
		end

		local ok, reason = acceptQuest(selectedQuest)
		raiseIdentity()

		Fluent:Notify({
			Title = ok and "Quest accepted" or "Refused",
			Content = selectedQuest,
			SubContent = (not ok) and tostring(reason) or nil,
			Duration = 6,
		})
	end,
})

local autoQuestToggle = Tabs.Quest:AddToggle("AutoQuest", {
	Title = "Auto Accept",
	Description = "Re-accepts the selected quest whenever you have none",
	Default = false,
})

local autoQuest = false
autoQuestToggle:OnChanged(function(value)
	autoQuest = value
end)

local tpToGiverToggle = Tabs.Quest:AddToggle("TpToGiver", {
	Title = "Teleport to giver first",
	Description = "The server refuses an accept unless you are near the OfferNpc",
	Default = true,
})

tpToGiverToggle:OnChanged(function(value)
	tpToGiver = value
end)

Tabs.Quest:AddButton({
	Title = "Teleport to giver",
	Description = "Stationary NPC that offers the selected quest",
	Callback = function()
		local npc = questGiverName(selectedQuest)
		local pos, region = findGiver(npc)
		local ok = teleportTo(pos)
		raiseIdentity()

		local content
		if npc == nil then
			content = "this quest names no OfferNpc"
		elseif pos == nil then
			content = "couldn't find " .. npc .. " in any StationaryNpcs"
		elseif not ok then
			content = "no character to move"
		else
			content = npc .. " (" .. tostring(region) .. ")"
		end

		Fluent:Notify({ Title = "Teleport", Content = content, Duration = 5 })
	end,
})

Tabs.Quest:AddButton({
	Title = "Talk to giver (press T)",
	Description = "Fires the NPC's Dialogue prompt - use it to hand a quest in",
	Callback = function()
		local heldKey = activeQuestKey()
		local giver = questGiverName(heldKey or selectedQuest)
		local ok, why = talkTo(giver)
		raiseIdentity()

		Fluent:Notify({
			Title = ok and "Talked" or "Failed",
			Content = tostring(giver or "no giver"),
			SubContent = tostring(why),
			Duration = 5,
		})
	end,
})

Tabs.Quest:AddButton({
	Title = "Teleport to objective",
	Description = "Uses the quest you are holding; falls back to the dropdown",
	Callback = function()
		-- The quest you hold matters more than whatever the dropdown shows.
		local pos, which, source = activeObjective()
		if pos == nil then
			pos, source = questWaypoint(selectedQuest)
			which = selectedQuest
		end

		local ok = teleportTo(pos)
		raiseIdentity()

		local content
		if pos == nil then
			content = "no Position on " .. tostring(which or selectedQuest)
		elseif not ok then
			content = "no character to move"
		else
			content = tostring(which)
		end

		Fluent:Notify({
			Title = "Teleport",
			Content = content,
			SubContent = (pos ~= nil) and tostring(source) or nil,
			Duration = 5,
		})
	end,
})

-- Max is 1 quest with a 30s cooldown, so this waits rather than spamming.
--
-- AddQuest passing its CLIENT gates does not mean the server granted it: the
-- server also checks you are near the OfferNpc. So teleport first when asked,
-- then verify the quest actually landed in Holder instead of trusting the
-- return value - otherwise this re-fires the remote every second forever.
task.spawn(function()
	while true do
		if Fluent.Unloaded then break end

		if autoQuest and selectedQuest ~= nil then
			local active = activeQuestCount()
			local maxQuests = (QuestsModule and QuestsModule.MaxQuestsPerPlayer) or 1

			if active >= maxQuests then
				questStatus = "have a quest"
				task.wait(1)
			else
				local left = questCooldownLeft()
				if left > 0 then
					questStatus = string.format("cooldown %ds", math.ceil(left))
					task.wait(math.min(left, 5))
				else
					if tpToGiver then
						local pos = findGiver(questGiverName(selectedQuest))
						if pos ~= nil then
							teleportTo(pos)
							task.wait(0.4)
						end
					end

					local before = activeQuestCount()
					local ok, reason = acceptQuest(selectedQuest)

					if not ok then
						questStatus = "refused: " .. tostring(reason)
						raiseIdentity()
						task.wait(3)
					else
						-- Wait for the server, not the client's opinion.
						local deadline = os_clock() + 2
						repeat
							task.wait(0.1)
						until activeQuestCount() > before or os_clock() > deadline

						raiseIdentity()

						if activeQuestCount() > before then
							questStatus = "accepted " .. selectedQuest
							task.wait(1)
						else
							questStatus = "fired but not granted - too far from " ..
								tostring(questGiverName(selectedQuest) or "the giver") .. "?"
							task.wait(5)
						end
					end
				end
			end
		else
			questStatus = autoQuest and "no quest selected" or "off"
			task.wait(0.5)
		end
	end
end)

-- Master loop ----------------------------------------------------------------------
--
-- Defined here, after the Quest tab, because it needs selectedQuest. It owns
-- the other toggles while running: flipping them by hand is pointless until
-- AUTO FARM is switched off.
task.spawn(function()
	local lastTravel = 0

	while true do
		if Fluent.Unloaded then break end

		if not autoAll then
			task.wait(0.5)
		else
			-- these stay on for the whole run
			lootOn = true
			questFarm = true
			autoWeapon = true

			-- Nothing drawn means the combat preset resolves to nothing and the
			-- whole farm silently does nothing, so fix it before anything else.
			if not weaponDrawn() then
				local slots = toolbarSlots()
				if toolbarItem ~= nil and toolbarItem ~= "<none>"
					and (slots[toolbarSlot] or 0) == 0 then
					pcall(toolbarEquip, toolbarItem, toolbarSlot)
				end
				pcall(pressSlotKey, toolbarSlot)
				raiseIdentity()
			end

			local active = activeQuestCount()

			if active == 0 then
				-- No quest: stop swinging, go get one.
				autoPunch, behindOn = false, false

				local left = questCooldownLeft()
				if left > 0 then
					autoAllStatus = string.format("quest cooldown %ds", math.ceil(left))
					task.wait(math.min(left, 5))
				else
					-- Pick for ourselves unless the user pinned one.
					local questKey = selectedQuest
					if autoPickQuest then
						local nextKey = nextEligibleQuest()
						if nextKey ~= nil then
							questKey = nextKey
						end
					end

					-- No `continue` here: it is Luau-only and Lua 5.1 parsers
					-- (obfuscators, linters) read it as an identifier and fail
					-- with "'=' expected". Plain if/else works everywhere.
					if questKey == nil then
						autoAllStatus = "nothing eligible - check level / givers nearby"
						task.wait(3)
					else
					selectedQuest = questKey
					local giver = questGiverName(selectedQuest)
					local pos = findGiver(giver)
					if pos ~= nil then
						teleportTo(pos)
						task.wait(0.5)
					end

					local before = activeQuestCount()
					local ok, reason = acceptQuest(selectedQuest)

					if not ok then
						autoAllStatus = "refused: " .. tostring(reason)
						task.wait(3)
					else
						local deadline = os_clock() + 2
						repeat
							task.wait(0.1)
						until activeQuestCount() > before or os_clock() > deadline

						if activeQuestCount() > before then
							autoAllStatus = "accepted " .. tostring(selectedQuest)
							lastTravel = 0
						else
							autoAllStatus = "not granted - too far from " .. tostring(giver or "giver")
							task.wait(4)
						end
					end
					end
				end

			elseif allTasksComplete() then
				-- Objective done: walk up and press T on the giver to hand in.
				autoPunch, behindOn = false, false

				local heldKey = activeQuestKey()
				local giver = questGiverName(heldKey or selectedQuest)

				if os_clock() - lastTravel > 4 then
					local ok, why = talkTo(giver)
					lastTravel = os_clock()
					autoAllStatus = "turning in at " .. tostring(giver or "?")
						.. " - " .. tostring(why)
				end

				task.wait(2)

			else
				-- Have a quest with work left: fight what it needs.
				autoPunch, behindOn = true, true

				if not targetValid() then
					-- Nothing in range. Travel to the objective, but not more
					-- than once every few seconds or it fights the behind-TP.
					if os_clock() - lastTravel > 5 then
						local pos, which = activeObjective()
						if pos ~= nil then
							teleportTo(pos)
							lastTravel = os_clock()
							autoAllStatus = "travelling to " .. tostring(which)
						else
							autoAllStatus = "no objective position - fighting where you stand"
						end
					end
				else
					autoAllStatus = "farming: " .. tostring(questFarmStatus)
				end
			end

			task.wait(1)
		end
	end
end)

-- Loot ----------------------------------------------------------------------------

local lootToggle = Tabs.Loot:AddToggle("AutoLoot", {
	Title = "Auto Loot",
	Description = "Fires every LootDropPrompt under Workspace.LootDrops",
	Default = false,
})

lootToggle:OnChanged(function(value)
	lootOn = value
end)

local lootRangeSlider = Tabs.Loot:AddSlider("LootRange", {
	Title = "Range",
	Description = "0 = ignore distance (fireproximityprompt bypasses it anyway)",
	Default = 0,
	Min = 0,
	Max = 200,
	Rounding = 0,
})

lootRangeSlider:OnChanged(function(value)
	lootRange = value
end)

Tabs.Loot:AddButton({
	Title = "Loot once",
	Callback = function()
		local n = lootOnce()
		raiseIdentity()
		Fluent:Notify({
			Title = "Loot",
			Content = n > 0 and ("fired " .. n .. " prompt(s)") or "nothing on the ground",
			Duration = 4,
		})
	end,
})

-- Equip ---------------------------------------------------------------------------

toolbarItem = combatItemsCached[1]
toolbarSlot = "One"

local toolbarItemDropdown = Tabs.Equip:AddDropdown("ToolbarItem", {
	Title = "Weapon / style",
	Description = "Inventory items flagged HasCombat",
	Values = combatItemsCached,
	Multi = false,
	Default = 1,
})

toolbarItemDropdown:OnChanged(function(value)
	toolbarItem = value
end)

local toolbarSlotDropdown = Tabs.Equip:AddDropdown("ToolbarSlot", {
	Title = "Toolbar slot",
	Values = TOOLBAR_SLOTS,
	Multi = false,
	Default = 1,
})

toolbarSlotDropdown:OnChanged(function(value)
	toolbarSlot = value
end)

local autoWeaponToggle = Tabs.Equip:AddToggle("AutoEquipWeapon", {
	Title = "Auto equip weapon",
	Description = "Re-equips the selection below whenever that slot empties",
	Default = false,
})

autoWeaponToggle:OnChanged(function(value)
	autoWeapon = value
end)

-- Without a weapon in the toolbar the combat preset resolves to nothing and
-- the farm silently does nothing, so this is worth having on.
task.spawn(function()
	while true do
		if Fluent.Unloaded then break end

		if autoWeapon and toolbarItem ~= nil and toolbarItem ~= "<none>" then
			local slots = toolbarSlots()
			if (slots[toolbarSlot] or 0) == 0 then
				-- slot emptied (death, swap, rejoin)
				pcall(toolbarEquip, toolbarItem, toolbarSlot)
				raiseIdentity()
			elseif not weaponDrawn() then
				-- in the slot but sheathed; press its number key to draw it
				pcall(pressSlotKey, toolbarSlot)
				raiseIdentity()
			end
		end

		task.wait(5)
	end
end)

Tabs.Equip:AddButton({
	Title = "Equip to toolbar",
	Description = "Toolbar_Equip, then presses the slot key to draw it",
	Callback = function()
		local ok, reason = toolbarEquip(toolbarItem, toolbarSlot)
		if ok then
			pressSlotKey(toolbarSlot)
			task.wait(0.3)
		end
		raiseIdentity()
		Fluent:Notify({
			Title = ok and "Equipped" or "Failed",
			Content = tostring(toolbarItem) .. " -> " .. toolbarSlot,
			SubContent = (not ok) and tostring(reason) or nil,
			Duration = 5,
		})
	end,
})

-- Category is fixed to Stats: that is where stat-bearing accessories go.
-- Vanity slots are cosmetic and nothing there is ranked.
local equipCategory = "Stats"
local equipMode     = "balanced"

local modeDropdown = Tabs.Equip:AddDropdown("EquipMode", {
	Title = "Best mode",
	Description = "How stats are weighted when ranking - the weights are tunable guesses",
	Values = { "balanced", "damage", "tank", "stamina", "speed" },
	Multi = false,
	Default = 1,
})

modeDropdown:OnChanged(function(value)
	equipMode = value
end)

Tabs.Equip:AddButton({
	Title = "Equip best (preview)",
	Description = "Ranks and reports without firing anything",
	Callback = function()
		local report = equipBest(equipMode, equipCategory, true)
		raiseIdentity()
		Fluent:Notify({
			Title = "Equip best - preview",
			Content = report.note or (#report.equipped .. " change(s)"),
			SubContent = #report.equipped > 0 and table.concat(report.equipped, ", ") or nil,
			Duration = 7,
		})
	end,
})

Tabs.Equip:AddButton({
	Title = "Equip best",
	Callback = function()
		local report = equipBest(equipMode, equipCategory, false)
		raiseIdentity()
		Fluent:Notify({
			Title = "Equip best",
			Content = report.note or (#report.equipped .. " equipped, " .. #report.failed .. " failed"),
			SubContent = #report.equipped > 0 and table.concat(report.equipped, ", ") or nil,
			Duration = 7,
		})
	end,
})


-- Trainers only stream in with their region, so keep learning their
-- positions in the background.
task.spawn(function()
	while true do
		if Fluent.Unloaded then break end
		pcall(scanTrainers)
		raiseIdentity()
		task.wait(5)
	end
end)

-- Travel --------------------------------------------------------------------------

local hubPositions, hubOrder = regionHubs()
raiseIdentity()

local selectedHub = hubOrder[1]

local hubDropdown = Tabs.Travel:AddDropdown("TravelRegion", {
	Title = "Region",
	Values = hubOrder,
	Multi = false,
	Default = 1,
})

hubDropdown:OnChanged(function(value)
	selectedHub = value
end)

Tabs.Travel:AddButton({
	Title = "Teleport to region",
	Callback = function()
		local pos = hubPositions[selectedHub]
		local ok = teleportTo(pos)
		raiseIdentity()
		Fluent:Notify({
			Title = "Travel",
			Content = pos == nil and "unknown region" or (ok and tostring(selectedHub) or "no character"),
			Duration = 4,
		})
	end,
})

local selectedTrainer = BREATHING_TRAINERS[1]

local trainerDropdown = Tabs.Travel:AddDropdown("TravelTrainer", {
	Title = "Breathing trainer",
	Values = BREATHING_TRAINERS,
	Multi = false,
	Default = 1,
})

trainerDropdown:OnChanged(function(value)
	selectedTrainer = value
end)

Tabs.Travel:AddButton({
	Title = "Teleport to trainer",
	Description = "Only works once that trainer\'s region has streamed in",
	Callback = function()
		local pos, source = trainerPosition(selectedTrainer)
		local ok = teleportTo(pos)
		raiseIdentity()

		local content
		if pos == nil then
			content = selectedTrainer .. " is not loaded - teleport to its region first"
		elseif not ok then
			content = "no character to move"
		else
			content = selectedTrainer .. " (" .. tostring(source) .. ")"
		end

		Fluent:Notify({ Title = "Travel", Content = content, Duration = 5 })
	end,
})

Tabs.Travel:AddButton({
	Title = "Scan for trainers here",
	Description = "Records any trainer loaded right now so it stays teleportable",
	Callback = function()
		local learned = scanTrainers()
		raiseIdentity()
		Fluent:Notify({
			Title = "Travel",
			Content = #learned > 0 and ("learned " .. table.concat(learned, ", ")) or "none new here",
			Duration = 5,
		})
	end,
})

-- Spin ----------------------------------------------------------------------------

local rarityDropdown = Tabs.Spin:AddDropdown("SpinMinRarity", {
	Title = "Stop at",
	Description = "Stops as soon as a clan of this tier or better is rolled",
	Values = RARITY_ORDER,
	Multi = false,
	Default = 4,
})

rarityDropdown:OnChanged(function(value)
	spinMinRarity = RARITY_LABELS[value] or 5
end)

rarityDropdown:SetValue("5 Legendary")

Tabs.Spin:AddButton({
	Title = "Spin once",
	Callback = function()
		if spinsLeft() < SPIN_COST then
			raiseIdentity()
			Fluent:Notify({ Title = "Spin", Content = "out of spins", Duration = 4 })
			return
		end

		local ok, name, _, label = spinOnce()
		raiseIdentity()

		Fluent:Notify({
			Title = ok and "Spin" or "Spin failed",
			Content = ok and (tostring(name) .. " [" .. tostring(label) .. "]") or tostring(name),
			SubContent = ok and (spinsLeft() .. " left") or nil,
			Duration = 5,
		})
	end,
})

local autoSpinToggle = Tabs.Spin:AddToggle("AutoSpin", {
	Title = "Auto Spin",
	Description = "Rolls until the chosen tier is hit, or spins run out",
	Default = false,
})

autoSpinToggle:OnChanged(function(value)
	autoSpin = value
end)

-- Settings ----------------------------------------------------------------------

if SaveManager ~= nil and InterfaceManager ~= nil then
	SaveManager:SetLibrary(Fluent)
	InterfaceManager:SetLibrary(Fluent)
	SaveManager:IgnoreThemeSettings()
	SaveManager:SetIgnoreIndexes({})
	InterfaceManager:SetFolder("amitoofast")
	SaveManager:SetFolder("amitoofast/amitoofast")
	InterfaceManager:BuildInterfaceSection(Tabs.Settings)
	SaveManager:BuildConfigSection(Tabs.Settings)
end

-- Autostart hooks, for the one-click launcher.
--   _G.amitoofast_QUEST     = "Ill take 3 bandits"   -- accept key to farm
--   _G.amitoofast_AUTOSTART = true                   -- flip AUTO FARM on
-- Set these BEFORE loading this file.
if type(_G.amitoofast_QUEST) == "string" and table.find(questKeysCached, _G.amitoofast_QUEST) then
	questDropdown:SetValue(_G.amitoofast_QUEST)
end

if _G.amitoofast_AUTOSTART then
	-- give the dropdowns a beat to settle before the loop reads them
	task.delay(1, function()
		autoAllToggle:SetValue(true)
		Fluent:Notify({
			Title = "amitoofast",
			Content = "Auto farm started",
			SubContent = tostring(_G.amitoofast_QUEST or "quest: first in list"),
			Duration = 5,
		})
	end)
end

Window:SelectTab(1)

Fluent:Notify({
	Title = "amitoofast",
	Content = "Loaded - combat route: " .. combatRouteName,
	Duration = 6,
})
