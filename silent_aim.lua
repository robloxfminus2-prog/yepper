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

local function getVelocity(part: BasePart): Vector3
    local h = posHistory[part];
    if not h or #h < 2 then return Vector3.zero; end;
    local first = h[1];
    local last = h[#h];
    local dt = last.t - first.t;
    if dt <= 0 then return Vector3.zero; end;
    return (last.p - first.p) / dt;
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

--==[ Bullet impact tracer (v3) ]==--
-- Hooks CosmeticProjectiles. Every time a bullet WE fired finishes its flight
-- (parent destroyed), pins a cyan ball at the last known position and prints
-- the distance from that point to the prediction we returned for that shot.
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

            if predictionAtFire then
                local d = lastPos - predictionAtFire;
                print(string.format(
                    "[yepper] impact %.2f studs from prediction  (dx=%.2f dy=%.2f dz=%.2f)",
                    d.Magnitude, d.X, d.Y, d.Z
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
                    local tVel = getVelocity(c);

                    local r = pos - plr.Character.Head.Position;
                    local v = tVel - plr.Character.Head.AssemblyLinearVelocity;

                    local a = v:Dot(v) - vel * vel;
                    local b = 2 * r:Dot(v);
                    local c0 = r:Dot(r);

                    local disc = b * b - 4 * a * c0;
                    if disc < 0 then
                        lastPrediction = pos;
                        lastPredictionAt = os.clock();
                        return pos;
                    end;

                    local sqrtDisc = math.sqrt(disc);
                    local t1 = (-b - sqrtDisc) / (2 * a);
                    local t2 = (-b + sqrtDisc) / (2 * a);

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

                    local prediction = pos + (tVel * t) * LEAD_MULTIPLIER;

                    lastPrediction = prediction;
                    lastPredictionAt = os.clock();

                    return prediction;
                end;
                return old(...);
            end)));
        elseif n == "bulletMagnetism" then
            -- Native magnetism returns a BasePart (or nil). Returning a
            -- Vector3 from this confused the game's downstream logic and
            -- caused it to fall back to its own aim path at range. Hard-nil
            -- it so Crosshair is the only voice in the room.
            hookfunction(rawget(getfenv(anon), k), newcclosure(function() return nil; end));
        end;
    end;
end;

--==[ Shoot hook — sets lastFireAt so the impact tracer only logs OUR shots ]==--
local oldShoot; oldShoot = clonefunction(hookfunction(rawget(wm, "Shoot"), newcclosure(function(...)
    lastFireAt = os.clock();
    return oldShoot(...);
end)));

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

SG["success"]("Silent aim v3 loaded — head-only targeting + bullet impact tracer. Watch the cyan ball and F9 console for drift.");
