-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingPedestrianWalker.lua
-- Fresh pedestrian walking controller for the Jonesing agenty_dummy.
-- Replaces the previous jonesingGtaNpc.lua approach.
--
-- Core mechanic — "head anchor":
--   The dummy's topmost node (head crown) is teleported each frame to a slowly
--   advancing target position. Every other body node is fully physics-simulated,
--   so vehicles, projectiles, and explosions hit the body normally. The
--   stabiliser beams in AgentY_Dummy_stabilizers.jbeam keep the dummy upright;
--   a strong impact will overwhelm / break those beams and send the body flying.
--   Once the thorax velocity spikes above RAGDOLL_VEL the head override stops
--   and the dummy enters full ragdoll (RAGDOLL state) forever.
--
-- Walk movement:
--   After world-placement is detected the head target advances by
--   (walkSpeed * dt) in the current walk direction every frame.  Terrain
--   following on Z: the target Z is only allowed to rise (tracks uphill),
--   never forced down (prevents sinking / fighting gravity).
--
-- Obstacle avoidance (raycasting):
--   Every RAY_INTERVAL seconds the controller probes the path ahead.
--   • castRayStatic() when available — detects walls, terrain steps, buildings.
--   • Vehicle-cone scan — any other vehicle whose centre falls in the forward
--     cone (within TURN_DIST m ahead and TURN_CONE_HALF m laterally) counts.
--   On a hit the walk direction is reversed with a small random offset so the
--   dummy turns around and walks the other way, mimicking pedestrian traffic.
--
-- World-placement detection (SETUP → WALKING):
--   Traffic scripts call init() before placing the vehicle at its final world
--   position. We wait until the topmost (head) node jumps more than 2 m in one
--   frame, which reliably signals the traffic-script world teleport, then
--   capture the initial head anchor position and begin walking.
--
-- Ragdoll detection (WALKING → RAGDOLL):
--   The thorax node position is tracked each frame; a per-frame XY displacement
--   larger than (RAGDOLL_VEL * dt) means the torso was given a large external
--   impulse — i.e. something physically hit the dummy — and we stop all
--   overrides so the dummy tumbles/flies naturally.
--
-- States:  SETUP → WALKING → RAGDOLL
--   SETUP   — waiting for the traffic-script world-placement teleport
--   WALKING — head anchor active; body is free physics
--   RAGDOLL — no overrides; full physics forever

local M = {}

-- ── state ─────────────────────────────────────────────────────────────────────
local state = "setup"   -- "setup", "walking", "ragdoll"

-- node IDs
local headCid   = nil   -- topmost node at init time (head crown / headtip)
local thoraxCid = nil   -- chest reference node for hit-velocity detection
local allCids   = {}    -- all node cids (used only during init scan)

-- head anchor (world position the head node is placed at each frame)
local headTargetX = 0.0
local headTargetY = 0.0
local headTargetZ = 0.0

-- accumulated walk offset (added to the spawn-time anchor each frame)
local walkOffsetX = 0.0
local walkOffsetY = 0.0

-- walk state
local walkDir        = 0.0  -- radians; direction measured from +Y axis, clockwise
local walkTimer      = 0.0  -- accumulator for periodic direction drift
local rayTimer       = 0.0  -- accumulator for obstacle checks
local walkGraceTimer = 0.0  -- brief no-ragdoll window right after WALKING begins

-- SETUP: previous head node position for jump detection
local prevHeadX = nil
local prevHeadY = nil

-- WALKING: previous thorax XY for velocity estimation
local prevThoraxX = nil
local prevThoraxY = nil

-- ── tuneable parameters (overridable from jbeam slot data) ────────────────────
local walkSpeed        = 1.2   -- m/s  pedestrian pace
local walkChangePeriod = 6.0   -- s    seconds between random direction tweaks
local RAY_INTERVAL     = 0.30  -- s    seconds between forward obstacle probes
local TURN_DIST        = 4.0   -- m    obstacle turn-trigger distance
local TURN_CONE_HALF   = 1.5   -- m    lateral half-width of the forward cone
local RAGDOLL_VEL      = 5.0   -- m/s  thorax per-frame speed that means "got hit"
local WALK_GRACE       = 0.4   -- s    grace period after WALKING start (no ragdoll check)

-- Distance² threshold for detecting the traffic-script world teleport
local PLACED_JUMP_SQ = 2.0 * 2.0  -- (2 m)²

-- Named nodes (fallback to auto-detect highest/thorax if absent in a skin)
local HEAD_NODE_NAME   = "dummy1_headtip"
local THORAX_NODE_NAME = "dummy1_thoraxtfl"

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Safely get player vehicle world position (vec3 or nil)
local function getPlayerPos()
    local ok, r = pcall(function()
        local pv = be:getPlayerVehicle(0)
        if not pv then return nil end
        local p = pv:getPosition()
        return vec3(p.x, p.y, p.z)
    end)
    return (ok and r) or nil
end

-- Returns true if an obstacle exists within TURN_DIST m in the given direction.
-- Uses castRayStatic (when available) for static geometry plus a vehicle-cone
-- scan for dynamic objects.
local function obstacleAhead(fromPos, dirX, dirY)
    -- 1. Static geometry ray (walls, terrain steps, buildings)
    local ok, rayHit = pcall(function()
        if not castRayStatic then return nil end
        local toPos = vec3(
            fromPos.x + dirX * TURN_DIST,
            fromPos.y + dirY * TURN_DIST,
            fromPos.z)
        return castRayStatic(fromPos, toPos)
    end)
    if ok and rayHit then return true end

    -- 2. Dynamic objects: other vehicles in the forward cone
    local myId  = obj:getId()
    local count = be:getVehicleCount()
    for i = 0, count - 1 do
        local veh = be:getVehicle(i)
        if veh and veh:getID() ~= myId then
            local vp  = veh:getPosition()
            local ex  = vp.x - fromPos.x
            local ey  = vp.y - fromPos.y
            local dot   = ex * dirX + ey * dirY       -- projection onto forward
            local cross = ex * dirY - ey * dirX       -- signed lateral offset
            if dot > 0 and dot < TURN_DIST and math.abs(cross) < TURN_CONE_HALF then
                return true
            end
        end
    end
    return false
end

-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────

local function init(jbeamData)
    -- Apply any per-slot overrides from the jbeam part entry
    walkSpeed        = jbeamData.walkSpeed        or walkSpeed
    walkChangePeriod = jbeamData.walkChangePeriod or walkChangePeriod
    TURN_DIST        = jbeamData.turnDist         or TURN_DIST
    RAGDOLL_VEL      = jbeamData.ragdollVel       or RAGDOLL_VEL

    -- Scan all nodes: find the topmost (head anchor) and named thorax node
    headCid   = nil
    thoraxCid = nil
    allCids   = {}
    local maxZ = -math.huge

    for _, n in pairs(v.data.nodes) do
        local cid = n.cid
        table.insert(allCids, cid)

        if n.name == THORAX_NODE_NAME then
            thoraxCid = cid
        end

        -- Named head node wins; otherwise track the highest Z at init time
        if n.name == HEAD_NODE_NAME then
            headCid = cid
        elseif headCid == nil then
            local p = vec3(obj:getNodePosition(cid))
            if p.z > maxZ then
                maxZ    = p.z
                headCid = cid
            end
        end
    end

    -- Fallback: if thorax node name not found use the head node
    if not thoraxCid then thoraxCid = headCid end

    -- Per-instance random seed: vehicle ID ensures uniqueness even when many
    -- dummies are spawned within the same wall-clock second.
    math.randomseed(obj:getId())

    -- Reset all walk state
    walkDir        = math.random() * 2 * math.pi
    walkOffsetX    = 0
    walkOffsetY    = 0
    walkTimer      = 0
    rayTimer       = 0
    walkGraceTimer = 0
    prevHeadX      = nil
    prevHeadY      = nil
    prevThoraxX    = nil
    prevThoraxY    = nil
    state          = "setup"
end


local function reset()
    -- Re-randomise direction and restart from SETUP on vehicle reset.
    -- Mix in os.time() so repeated resets produce different directions.
    math.randomseed(obj:getId() + os.time())
    walkDir        = math.random() * 2 * math.pi
    walkOffsetX    = 0
    walkOffsetY    = 0
    walkTimer      = 0
    rayTimer       = 0
    walkGraceTimer = 0
    prevHeadX      = nil
    prevHeadY      = nil
    prevThoraxX    = nil
    prevThoraxY    = nil
    state          = "setup"
end


local function updateGFX(dt)
    if dt <= 0 then return end
    if not headCid  then return end

    -- ── RAGDOLL: no overrides, just let physics run ───────────────────────────
    if state == "ragdoll" then return end

    local hp = vec3(obj:getNodePosition(headCid))

    -- ── SETUP: wait for the traffic-script world-placement teleport ───────────
    if state == "setup" then
        if prevHeadX ~= nil then
            local ddx = hp.x - prevHeadX
            local ddy = hp.y - prevHeadY
            if (ddx * ddx + ddy * ddy) >= PLACED_JUMP_SQ then
                -- Vehicle was just teleported to its world spawn position.
                -- Initialise the head anchor from the current real position.
                headTargetX    = hp.x
                headTargetY    = hp.y
                headTargetZ    = hp.z
                walkOffsetX    = 0
                walkOffsetY    = 0

                -- Seed an initial walk direction aligned with the road:
                -- player→dummy vector is roughly road-perpendicular; rotate 90°
                -- to get road-parallel, then randomly flip to pick a lane.
                local pp = getPlayerPos()
                if pp and (math.abs(pp.x - hp.x) > 1.0 or
                           math.abs(pp.y - hp.y) > 1.0) then
                    local dx = pp.x - hp.x
                    local dy = pp.y - hp.y
                    local d  = math.sqrt(dx * dx + dy * dy)
                    -- Perpendicular-to-player vector = road-parallel direction
                    local nx = -dy / d
                    local ny =  dx / d
                    walkDir = math.atan2(nx, ny)
                    if math.random() > 0.5 then walkDir = walkDir + math.pi end
                end
                -- else: keep the random direction chosen at init()

                -- Capture initial thorax position for velocity tracking
                if thoraxCid then
                    local tp = vec3(obj:getNodePosition(thoraxCid))
                    prevThoraxX = tp.x
                    prevThoraxY = tp.y
                end

                walkGraceTimer = WALK_GRACE
                state          = "walking"
                return
            end
        end
        prevHeadX = hp.x
        prevHeadY = hp.y
        return
    end

    -- ── WALKING state ─────────────────────────────────────────────────────────

    -- Tick down grace period (no ragdoll check during the first WALK_GRACE seconds)
    if walkGraceTimer > 0 then
        walkGraceTimer = walkGraceTimer - dt
    end

    -- 1. Hit detection: estimate thorax XY velocity from position deltas.
    --    A large velocity means an external impulse hit the body → ragdoll.
    if walkGraceTimer <= 0 and thoraxCid and prevThoraxX ~= nil then
        local tp  = vec3(obj:getNodePosition(thoraxCid))
        local spd = math.sqrt(
            (tp.x - prevThoraxX) * (tp.x - prevThoraxX) +
            (tp.y - prevThoraxY) * (tp.y - prevThoraxY)) / dt
        if spd > RAGDOLL_VEL then
            state = "ragdoll"
            return
        end
        prevThoraxX = tp.x
        prevThoraxY = tp.y
    elseif thoraxCid then
        local tp = vec3(obj:getNodePosition(thoraxCid))
        prevThoraxX = tp.x
        prevThoraxY = tp.y
    end

    -- 2. Obstacle check: probe the path ahead; turn around if blocked.
    rayTimer = rayTimer + dt
    if rayTimer >= RAY_INTERVAL then
        rayTimer = 0
        local dirX    = math.sin(walkDir)
        local dirY    = math.cos(walkDir)
        local fromPos = vec3(headTargetX + walkOffsetX,
                             headTargetY + walkOffsetY,
                             headTargetZ)
        if obstacleAhead(fromPos, dirX, dirY) then
            -- Reverse with a ±30° random kick so the dummy doesn't just oscillate
            walkDir = walkDir + math.pi + (math.random() - 0.5) * math.pi / 3
        end
    end

    -- 3. Periodic gentle direction drift (mimics natural pedestrian wandering)
    walkTimer = walkTimer + dt
    if walkTimer >= walkChangePeriod then
        walkTimer = 0
        walkDir   = walkDir + (math.random() - 0.5) * math.pi / 9  -- ±20°
    end

    -- 4. Advance the horizontal walk offset
    local effSpeed = math.min(walkSpeed, 3.0)  -- hard cap prevents runaway
    walkOffsetX = walkOffsetX + math.sin(walkDir) * effSpeed * dt
    walkOffsetY = walkOffsetY + math.cos(walkDir) * effSpeed * dt

    -- 5. Terrain-following Z: allow the head anchor to rise (uphill) but
    --    never force it down (prevents fighting gravity / sinking into terrain).
    if hp.z > headTargetZ then
        headTargetZ = hp.z
    end

    -- 6. Place the head anchor node at the desired world position.
    --    All other nodes are free physics — car hits, ball throws, etc. all work.
    obj:setNodePosition(headCid, vec3(
        headTargetX + walkOffsetX,
        headTargetY + walkOffsetY,
        headTargetZ
    ))
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
