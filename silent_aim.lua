if not game:IsLoaded() then game.Loaded:Wait(); end;

local cloneref = cloneref or function(i: Instance) return i; end;
local clonefunction = clonefunction or function(f: (...any) -> (...any)) return f; end;
local newcclosure = newcclosure or clonefunction;
local executor = (identifyexecutor and select(2, pcall(identifyexecutor))) and identifyexecutor() or "Your executor";
local SG = loadstring(game:HttpGet("https://raw.githubusercontent.com/sneekygoober/sneeky-s-notifications/refs/heads/main/main.luau"))();

if not (hookfunction and require) then
    local err = executor .. " is missing " .. (not hookfunction and "hookfunction " or "") .. (not require and "require" or "");
    SG["error"](err);
    return error(err);
end;

local RS: ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"));
local Players: Players = cloneref(game:GetService("Players"));
local UIS: UserInputService = cloneref(game:GetService("UserInputService"));
local CS: CollectionService = cloneref(game:GetService("CollectionService"));
local RunService: RunService = cloneref(game:GetService("RunService"));

local plr = Players.LocalPlayer;
local cam = workspace.CurrentCamera;

local isMobile = UIS.TouchEnabled and not UIS.KeyboardEnabled and not UIS.MouseEnabled;

local s, wm = pcall(require, RS.WeaponModule);
if not s then
    return warn(executor .. " returned an error while trying to require RS.WeaponModule:" .. wm);
end;

local anon = debug.getupvalue(rawget(wm, "Shoot"), 3);
if not anon or typeof(anon) ~= "function" then
    for _, v in next, debug.getupvalues(rawget(wm, "Shoot")) do
        if type(v) == "function" then
            anon = v;
            break;
        end;
    end;
end;

if not anon then
    local err = "Failed to retrieve function";
    SG["error"](err);
    return warn(err);
end;

local cp = workspace:FindFirstChild("CosmeticProjectiles");
if not cp then
    local err = "Script needs updating";
    SG["error"](err);
    return warn(err);
end;

local rp = RaycastParams.new();
rp.CollisionGroup = "Projectiles";
rp.FilterType = Enum.RaycastFilterType.Exclude;
rp.IgnoreWater = true;

local isVisible = function(part: BasePart): (boolean, Instance?)
    local char = plr.Character;
    if not (char and part) then return false, nil; end;

    rp.FilterDescendantsInstances = CS:GetTagged("ShootThrough");
    rp.FilterDescendantsInstances[#rp.FilterDescendantsInstances+1] = char;
    rp.FilterDescendantsInstances[#rp.FilterDescendantsInstances+1] = cp;

    local origin = cam.CFrame.Position;

    local dir = part.Position - origin;
    local result: RaycastResult = workspace:Raycast(origin, dir, rp);
    if not result then return true, nil; end;

    if result.Instance:IsDescendantOf(part.Parent) then
        return true, result.Instance;
    end;

    return false, result.Instance;
end;

local getTarget = function()
    local cPart, cDistance = nil, getgenv().fov or 300;

    for _, player: Player in next, Players:GetPlayers() do
        if player == plr or player.Team == plr.Team then continue; end;

        local char = player.Character;
        if not char or char:FindFirstChildOfClass("ForceField") or (char:FindFirstChild("Humanoid") and char.Humanoid.Health <= 0) then continue; end;

        -- v3: skip half-formed characters (death anims, respawn race, headless custom models).
        -- the game's own visualiseCharacter errors on these, and our shots register inconsistently.
        local head = char:FindFirstChild("Head");
        if not head then continue; end;
        local tPart: BasePart = head;

        local pos, onScreen = cam:WorldToViewportPoint(tPart.Position);
        if not onScreen then continue; end;

        local v, nTPart = isVisible(tPart);
        if not v then
            v, nTPart = isVisible(char.PrimaryPart or char:FindFirstChild("HumanoidRootPart"));
            if not v then continue; end;
        end;

        if nTPart then tPart = nTPart; end;

        local distance = (Vector2.new(pos.X, pos.Y) - (isMobile and Vector2.new(cam.ViewportSize.X/2, cam.ViewportSize.Y/2) or UIS:GetMouseLocation())).Magnitude;
        if distance < cDistance then
            cPart = tPart;
            cDistance = distance;
        end;
    end;

    return cPart;
end;

loadstring(game:HttpGet("https://raw.githubusercontent.com/sneekygoober/sneeky-s-fov-lib/refs/heads/main/main.luau"))()(getgenv().fov or 300, getTarget, true);

local vel: number;
local tool: Tool;
local equippedData;  -- live ref to the WeaponModule data table for the current weapon
local lastFireAt = 0;  -- timestamp of the last time WE actually pulled the trigger (wm.Shoot)

--==[ Tunables ]==--
local LEAD_MULTIPLIER = 1.0    -- 1.0 = pure lead. <1.0 if shots land AHEAD. >1.0 if shots land BEHIND.
local VEL_WINDOW_SEC  = 0.18   -- velocity computed from positional delta over this many seconds. ~180ms is the sweet spot for 20Hz replication.

-- Spread / inaccuracy attribute names this engine uses. Anything found on the
-- tool gets nailed to 0 every frame so the bullet leaves the muzzle dead-on.
local SPREAD_ATTRS = {
    "SpreadDefault", "Spread", "SpreadIncrease", "SpreadDecrease",
    "SpreadRecover", "SpreadAimMultiplier", "SpreadMoveMultiplier",
    "SpreadJumpMultiplier", "Recoil", "RecoilSpring", "RecoilDamper",
};

-- Mirror keys on the data table (FE-Gun-Kit-style configs read these from the
-- live data table at fire time, not from attributes, so we zero both).
local SPREAD_KEYS = {
    "SpreadDefault", "Spread", "SpreadIncrease", "SpreadDecrease",
    "SpreadRecover", "SpreadAimMultiplier", "SpreadMoveMultiplier",
    "SpreadJumpMultiplier",
};

local function nukeSpread()
    if tool then
        for _, a in ipairs(SPREAD_ATTRS) do
            -- only set if the attribute already exists (avoid spamming new ones)
            if tool:GetAttribute(a) ~= nil then
                tool:SetAttribute(a, 0);
            end;
        end;
    end;
    if equippedData then
        for _, k in ipairs(SPREAD_KEYS) do
            if equippedData[k] ~= nil then
                equippedData[k] = 0;
            end;
        end;
        if equippedData.RecoilPattern then
            table.clear(equippedData.RecoilPattern);
        end;
    end;
end;

--==[ Position-delta velocity tracker ]==--
-- AssemblyLinearVelocity reads zero on remote players in this game, so we
-- compute velocity from how the part has actually moved through space.
local posHistory: {[BasePart]: {{t: number, p: Vector3}}} = {};

local function trackPosition(part: BasePart)
    local h = posHistory[part];
    if not h then
        h = {};
        posHistory[part] = h;
    end;
    local now = os.clock();
    table.insert(h, {t = now, p = part.Position});
    while #h > 1 and (now - h[1].t) > VEL_WINDOW_SEC do
        table.remove(h, 1);
    end;
end;

-- Returns (velocity, acceleration) for the given part, both in world frame.
-- Velocity is averaged over the full window (smooth, the same low-noise
-- estimate that gave us sub-stud pred-error on linear motion in v4).
-- Acceleration is the difference between late-half and early-half mean
-- velocity, divided by the time between window midpoints. Catches gravity
-- on jumping targets (~ -196 studs/s² in y), and jump-impulse acceleration.
local function getKinematics(part: BasePart): (Vector3, Vector3)
    local h = posHistory[part];
    if not h or #h < 2 then return Vector3.zero, Vector3.zero; end;
    local first = h[1];
    local last = h[#h];
    local dt = last.t - first.t;
    if dt <= 0 then return Vector3.zero, Vector3.zero; end;
    local v = (last.p - first.p) / dt;

    if #h < 4 then return v, Vector3.zero; end;
    local mid = math.floor(#h / 2);
    local vEarly = (h[mid].p - h[1].p) / math.max(h[mid].t - h[1].t, 1e-6);
    local vLate  = (h[#h].p - h[mid].p) / math.max(h[#h].t - h[mid].t, 1e-6);
    local tEarlyMid = (h[1].t   + h[mid].t) / 2;
    local tLateMid  = (h[mid].t + h[#h].t)  / 2;
    if tLateMid - tEarlyMid <= 1e-6 then return v, Vector3.zero; end;
    local accel = (vLate - vEarly) / (tLateMid - tEarlyMid);

    -- Cap to discard replication-jitter spikes. Gravity is ~196, jump
    -- impulses peak around 800-1200 over a frame. 1500 is generous ceiling.
    if accel.Magnitude > 1500 then accel = accel.Unit * 1500; end;
    return v, accel;
end;

RunService.Heartbeat:Connect(function()
    for _, p in next, Players:GetPlayers() do
        if p ~= plr and p.Character then
            local part = p.Character:FindFirstChild("Head")
                or p.Character:FindFirstChild("HumanoidRootPart")
                or p.Character.PrimaryPart;
            if part then trackPosition(part); end;
        end;
    end;
    for part in pairs(posHistory) do
        if not part.Parent then posHistory[part] = nil; end;
    end;

    -- continuous spread/recoil suppression — game writes can't outpace this
    nukeSpread();
end);

--==[ Impact indicator ]==--
local indicator = Instance.new("Part");
indicator.Name = "_aimIndicator";
indicator.Size = Vector3.new(1.25, 1.25, 1.25);
indicator.Shape = Enum.PartType.Ball;
indicator.Material = Enum.Material.Neon;
indicator.Color = Color3.fromRGB(255, 40, 40);
indicator.Transparency = 0.3;
indicator.Anchored = true;
indicator.CanCollide = false;
indicator.CanQuery = false;
indicator.CanTouch = false;
indicator.CastShadow = false;
indicator.Parent = workspace;

local lastPrediction: Vector3? = nil;
local lastPredictionAt = 0;

RunService.RenderStepped:Connect(function()
    if lastPrediction and (os.clock() - lastPredictionAt) < 0.15 then
        indicator.CFrame = CFrame.new(lastPrediction);
        indicator.Transparency = 0.3;
    else
        indicator.Transparency = 1;
    end;
end);

--==[ Hit verification (v5) ]==--
-- Three signals now:
--   1. Cosmetic tracer (cyan ball) — kept for trajectory eyeballing. The LOG
--      is gated so it only prints when the cosmetic dies NEAR an enemy body.
--      Filters out cosmetics that punch into walls/skybox tens of studs past
--      the target (which was making v3's deltas look catastrophic).
--   2. Authoritative hit detector — listens to every enemy Humanoid for
--      health drops within SHOT_WINDOW of OUR Shoot call. Ground truth.
--      (Implemented below the Crosshair hook so it can use lastPrediction.)
--   3. Miss detector — any shot whose SHOT_WINDOW closes without a matching
--      HealthChanged is logged as [yepper MISS] with the same pred-error
--      stats. v5 finally tracks both sides of the accuracy ledger.
local impactMarker = Instance.new("Part");
impactMarker.Name = "_aimImpact";
impactMarker.Size = Vector3.new(0.75, 0.75, 0.75);
impactMarker.Shape = Enum.PartType.Ball;
impactMarker.Material = Enum.Material.Neon;
impactMarker.Color = Color3.fromRGB(60, 200, 255);
impactMarker.Transparency = 1;
impactMarker.Anchored = true;
impactMarker.CanCollide = false;
impactMarker.CanQuery = false;
impactMarker.CanTouch = false;
impactMarker.CastShadow = false;
impactMarker.Parent = workspace;

local lastImpactAt = 0;

RunService.RenderStepped:Connect(function()
    if lastImpactAt > 0 and (os.clock() - lastImpactAt) < 3 then
        impactMarker.Transparency = 0.2;
    else
        impactMarker.Transparency = 1;
    end;
end);

local function findFirstBasePart(inst: Instance): BasePart?
    if inst:IsA("BasePart") then return inst; end;
    return inst:FindFirstChildWhichIsA("BasePart", true);
end;

-- Returns the closest enemy body part to a world point, the distance to it,
-- and which player it belongs to. Used both for the cosmetic-log gate and for
-- correlating Humanoid.HealthChanged events back to the shot that caused them.
local function nearestEnemyPart(point: Vector3): (BasePart?, number, Player?)
    local bestPart, bestDist, bestPlr = nil, math.huge, nil;
    for _, p in next, Players:GetPlayers() do
        if p == plr or p.Team == plr.Team then continue; end;
        local char = p.Character;
        if not char then continue; end;
        for _, body in ipairs({"Head","HumanoidRootPart","UpperTorso","LowerTorso","Torso"}) do
            local part = char:FindFirstChild(body);
            if part and part:IsA("BasePart") then
                local d = (part.Position - point).Magnitude;
                if d < bestDist then
                    bestPart, bestDist, bestPlr = part, d, p;
                end;
            end;
        end;
    end;
    return bestPart, bestDist, bestPlr;
end;

cp.ChildAdded:Connect(function(proj)
    -- only track projectiles that spawned right after WE pulled the trigger.
    -- (Crosshair fires every render frame for UI, so we can't gate on prediction
    -- timestamps — gate on the actual Shoot call instead.)
    if (os.clock() - lastFireAt) > 0.15 then return; end;
    local predictionAtFire = lastPrediction;

    local part = findFirstBasePart(proj);
    if not part then return; end;

    -- proximity gate: our bullets spawn at our muzzle, never 100 studs away.
    -- this filters enemy gunfire that lands in CosmeticProjectiles around us.
    local myChar = plr.Character;
    local myHead = myChar and myChar:FindFirstChild("Head");
    if myHead and (part.Position - myHead.Position).Magnitude > 30 then return; end;

    local lastPos = part.Position;
    local conn;
    conn = RunService.Heartbeat:Connect(function()
        if proj.Parent and part.Parent then
            lastPos = part.Position;
        else
            conn:Disconnect();
            impactMarker.CFrame = CFrame.new(lastPos);
            lastImpactAt = os.clock();

            -- LOG GATE: only print if the cosmetic actually died near a body.
            -- Otherwise it's a tracer that flew into a wall behind the target,
            -- which produces huge single-axis deltas that look like big misses
            -- but are really just the cosmetic continuing past the impact.
            local enemyPart, enemyDist, enemyPlr = nearestEnemyPart(lastPos);
            if enemyPart and enemyDist < 8 and predictionAtFire then
                local d = lastPos - predictionAtFire;
                print(string.format(
                    "[yepper cosmetic] near %s (%.2f studs)  pred-delta %.2f  (dx=%.2f dy=%.2f dz=%.2f)",
                    enemyPlr.Name, enemyDist, d.Magnitude, d.X, d.Y, d.Z
                ));
            end;
        end;
    end);
end);

--==[ Crosshair / bulletMagnetism hooks ]==--
for k, v in next, getfenv(anon) do
    if type(v) == "function" then
        local n = debug.info(v, "n");
        if n == "Crosshair" then
            -- Crosshair returns the world point the bullet aims at. Override
            -- with our predicted point for the closest target in FOV.
            local old; old = clonefunction(hookfunction(rawget(getfenv(anon), k), newcclosure(function(...)
                local c = getTarget();
                if c and vel and tool and plr.Character and plr.Character:FindFirstChild("Head") then
                    local pos = c.Position;
                    local tVel, tAcc = getKinematics(c);

                    local r = pos - plr.Character.Head.Position;
                    local v = tVel - plr.Character.Head.AssemblyLinearVelocity;

                    -- Step 1: initial guess from constant-velocity quadratic
                    -- (this is the v3/v4 solver, identical answer for any
                    -- target whose acceleration is zero).
                    local A = v:Dot(v) - vel * vel;
                    local B = 2 * r:Dot(v);
                    local C = r:Dot(r);

                    local disc = B * B - 4 * A * C;
                    if disc < 0 then
                        lastPrediction = pos;
                        lastPredictionAt = os.clock();
                        return pos;
                    end;

                    local sqrtDisc = math.sqrt(disc);
                    local t1 = (-B - sqrtDisc) / (2 * A);
                    local t2 = (-B + sqrtDisc) / (2 * A);

                    local t;
                    if t1 > 0 and t2 > 0 then
                        t = math.min(t1, t2);
                    elseif t1 > 0 then
                        t = t1;
                    elseif t2 > 0 then
                        t = t2;
                    else
                        lastPrediction = pos;
                        lastPredictionAt = os.clock();
                        return pos;
                    end;

                    -- Step 2: Picard iteration to fold in the 0.5*a*t² term.
                    -- Predict target's relative position at the current t
                    -- estimate, then refine t = |relPos| / bulletSpeed.
                    -- Converges in 2-3 passes for realistic accel magnitudes.
                    for _ = 1, 4 do
                        local relPos = r + v * t + 0.5 * tAcc * (t * t);
                        local newT = relPos.Magnitude / vel;
                        if math.abs(newT - t) < 0.005 then break; end;
                        t = newT;
                    end;

                    local prediction = pos + (tVel * t + 0.5 * tAcc * (t * t)) * LEAD_MULTIPLIER;

                    lastPrediction = prediction;
                    lastPredictionAt = os.clock();

                    return prediction;
                end;
                return old(...);
            end)));
        elseif n == "bulletMagnetism" then
            -- v6: this is the actual silent-aim hammer. Native magnetism
            -- returns the BasePart the bullet "hit"; whatever we return
            -- here is what the engine registers a hit on, regardless of
            -- where the bullet's path actually went. Returning getTarget()
            -- means every fire that has a target in FOV magnetises onto
            -- that target's head — no flight-time prediction needed, no
            -- range falloff, no lead math.
            --
            -- The Crosshair hook above stays for cosmetics (visible bullet
            -- trail still points at the target so spectators don't see a
            -- wild straight-line shot). But the HIT comes from this return.
            --
            -- Returning a Vector3 here used to break things — the engine
            -- expected a Part. A Part is what we give it.
            hookfunction(rawget(getfenv(anon), k), newcclosure(function()
                return getTarget();
            end));
        end;
    end;
end;

--==[ Shoot hook + authoritative hit detector ]==--
-- The Shoot hook now ALSO snapshots, at the moment of fire, the prediction
-- and the head position of whichever enemy was closest to that prediction.
-- When that enemy's Humanoid loses health within SHOT_WINDOW, we know the
-- shot connected and can compute the real prediction error against where the
-- head WAS at fire time (not where it is by the time HealthChanged arrives,
-- which can be 50-200ms later).
local shotHistory: {{t: number, pred: Vector3, targetHead: Vector3?, targetName: string?}} = {};
-- Wide enough to absorb 99th-percentile damage replication latency. Roblox
-- shooters typically deliver HealthChanged 100-300ms after the Shoot call,
-- but spikes to 400-500ms happen on bad routes — v5's 300ms window was
-- misclassifying those as misses.
local SHOT_WINDOW = 0.50;

local oldShoot; oldShoot = clonefunction(hookfunction(rawget(wm, "Shoot"), newcclosure(function(...)
    lastFireAt = os.clock();

    local pred = lastPrediction;
    if pred then
        local _, _, who = nearestEnemyPart(pred);
        local headPos = nil;
        if who and who.Character and who.Character:FindFirstChild("Head") then
            headPos = who.Character.Head.Position;
        end;
        table.insert(shotHistory, {
            t = os.clock(),
            pred = pred,
            targetHead = headPos,
            targetName = who and who.Name or nil,
        });
        -- pruning happens in the miss-sweep heartbeat below; entries that
        -- expire without a matching HealthChanged get logged as misses.
    end;

    return oldShoot(...);
end)));

local function hookEnemyHumanoid(p: Player, char: Model)
    if p == plr then return; end;
    local hum = char:WaitForChild("Humanoid", 5);
    if not hum then return; end;
    local lastHP = hum.Health;
    hum.HealthChanged:Connect(function(newHP)
        local dmg = lastHP - newHP;
        lastHP = newHP;
        if dmg <= 0 then return; end;

        -- Match the OLDEST in-window shot at this player (FIFO). With burst
        -- fire the oldest pending shot is the one whose damage event is most
        -- likely arriving now; matching newest-first would credit the wrong
        -- shot when damage events queue up, leaving real hits flagged as misses.
        local now = os.clock();
        for i = 1, #shotHistory do
            local s = shotHistory[i];
            if (now - s.t) > SHOT_WINDOW then continue; end;
            if s.targetName == p.Name and s.targetHead then
                local err = (s.pred - s.targetHead).Magnitude;
                print(string.format(
                    "[yepper HIT] %s took %.1f dmg  pred-error %.2f studs from head-at-fire  latency %.0fms",
                    p.Name, dmg, err, (now - s.t) * 1000
                ));
                table.remove(shotHistory, i);
                return;
            end;
        end;
        -- damage on enemy with no matching shot — could be teammate fire,
        -- world damage, or our prediction was way off the head we tracked.
    end);
end;

for _, p in next, Players:GetPlayers() do
    if p ~= plr then
        if p.Character then hookEnemyHumanoid(p, p.Character); end;
        p.CharacterAdded:Connect(function(c) hookEnemyHumanoid(p, c); end);
    end;
end;
Players.PlayerAdded:Connect(function(p)
    if p == plr then return; end;
    p.CharacterAdded:Connect(function(c) hookEnemyHumanoid(p, c); end);
end);

--==[ Miss detector ]==--
-- Any shot that ages past MISS_TIMEOUT without a matching HealthChanged
-- correlation is a miss. The 100ms grace over SHOT_WINDOW gives slow
-- replication a chance to deliver the damage event before we judge.
-- Shots without a known target (no enemy near the prediction at fire time)
-- are pruned silently — there's no meaningful "miss" if we weren't aimed
-- at anyone in particular.
local MISS_TIMEOUT = SHOT_WINDOW + 0.05;
RunService.Heartbeat:Connect(function()
    local now = os.clock();
    for i = #shotHistory, 1, -1 do
        local s = shotHistory[i];
        if (now - s.t) > MISS_TIMEOUT then
            if s.targetName and s.targetHead then
                local err = (s.pred - s.targetHead).Magnitude;
                print(string.format(
                    "[yepper MISS] aimed at %s  pred-error %.2f studs from head-at-fire  (no damage in %dms)",
                    s.targetName, err, MISS_TIMEOUT * 1000
                ));
            end;
            table.remove(shotHistory, i);
        end;
    end;
end);

--==[ Equip hook ]==--
local t: thread;
local old; old = clonefunction(hookfunction(rawget(wm, "Equip"), newcclosure(function(data, _)
    if t then
        coroutine.close(t);
        t = nil;
    end;

    local _data = data;
    vel = _data.Tool:GetAttribute("Velocity");
    tool = _data.Tool;
    equippedData = _data;

    -- Optional: extend max range so far shots aren't cut off by the engine.
    -- Comment out if it breaks server checks on a given game.
    if _data.Tool:GetAttribute("ProjectileMaxDistance") then
        _data.Tool:SetAttribute("ProjectileMaxDistance", 5000);
    end;

    nukeSpread();

    if _ == "Equip" then
        t = task.spawn(function()
            while task.wait() do
                nukeSpread();
            end;
        end);
    end;

    return old(_data, _);
end)));

plr.CharacterAdded:Connect(function()
    if t then
        coroutine.close(t);
        t = nil;
    end;
    equippedData = nil;
    tool = nil;
end);

SG["success"]("Silent aim v6 loaded — magnetism-driven hits (no flight-time, no range limit). F9 shows [yepper HIT] / [yepper MISS] for diagnostics.");
