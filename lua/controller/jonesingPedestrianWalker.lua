-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingPedestrianWalker.lua
-- Pedestrian walking controller for the Jonesing agenty_dummy.
--
-- Core mechanic — "step-push with physics settling":
--   Every WALK_INTERVAL seconds all body nodes are given a small velocity in the
--   walk direction via obj:setNodeVelocity().  The engine then runs freely until
--   the next step: terrain Z is followed automatically via contact forces, walls
--   push back (no clipping), and vehicle collisions apply naturally through the
--   physics solver — no geometry can be "teleported into".
--
-- Walk direction:
--   A random direction is chosen at WALKING start and updated with gentle ±20°
--   drifts every walkChangePeriod seconds.  On detecting an obstacle the
--   direction is reversed with a ±30° random kick.
--
-- Terrain Z following:
--   The Z component of the applied velocity is always 0.  Gravity and terrain
--   contact forces handle vertical position automatically on all surface types.
--
-- Ragdoll detection (WALKING → RAGDOLL):
--   At each step start the RELATIVE position of the inner intestine node ("oi1")
--   vs the outer thorax node is recorded as relBase.  During the settling window
--   the same relative vector is compared to relBase.  Because the velocity push
--   is applied to ALL nodes equally, the relative vector is nearly constant during
--   normal walking.  A vehicle impact applies a collision impulse to the outer
--   thorax shell (which has collision geometry) but NOT to the inner intestine
--   node (no collision surface); the relative vector therefore diverges, signalling
--   a genuine hit.  relBase is refreshed at every step so long-run drift from
--   walking never falsely triggers ragdoll.
--
-- World-placement detection (SETUP → WALKING):
--   Waits for a >2 m head-node jump (traffic-script teleport) or SETUP_TIMEOUT
--   seconds (direct spawn), then collects all node CIDs and starts walking.
--
-- States:  SETUP → WALKING → RAGDOLL
--   SETUP   — waiting for world-placement
--   WALKING — velocity-push active; physics settles between steps; dummy stays upright
--   RAGDOLL — no overrides; full physics forever

local M = {}

-- ── state ─────────────────────────────────────────────────────────────────────
local state = "setup"

-- node IDs
local headCid      = nil   -- topmost node (head crown / headtip) — obstacle ray origin
local thoraxCid    = nil   -- chest reference node (outer shell, has collision)
local intestineCid = nil   -- inner soft node ("oi1") — no collision surface
-- All node CIDs — populated at SETUP→WALKING transition.
-- Only CIDs are needed; spawn positions are NOT stored since we apply velocity
-- rather than teleporting to an absolute position.
local nodeCids = {}

-- walk state
local walkDir           = 0.0  -- radians; +Y axis = north, clockwise
local walkTimer         = 0.0  -- time since last direction drift (in step-units)
local walkIntervalTimer = 0.0  -- time since last velocity push
local walkGraceTimer    = 0.0  -- no-ragdoll window at WALKING start

-- SETUP detection
local prevHeadX  = nil
local prevHeadY  = nil
local setupTimer = 0.0

-- Baseline relative position of intestine node vs thorax node, refreshed at
-- every step start.  Deviation > IMPACT_REL_SQ during the settling window
-- signals a vehicle impact (outer shell pushed hard, inner intestine lags).
local relBaseX = nil
local relBaseY = nil
local relBaseZ = nil

-- ── tuneable parameters (overridable from jbeam slot data) ────────────────────
-- NOTE: with velocity-push locomotion, walkSpeed is a true velocity (m/s) that is
-- applied directly via setNodeVelocity.  Higher speeds are safe — the physics solver
-- prevents geometry clipping rather than requiring tiny steps.
local walkSpeed        = 0.5    -- m/s  comfortable walking pace (~1.8 km/h)
local walkChangePeriod = 6.0    -- s    seconds between gentle direction tweaks
local TURN_DIST        = 4.0    -- m    obstacle turn-trigger distance
local TURN_CONE_HALF   = 1.5    -- m    lateral half-width of forward cone
local RAGDOLL_VEL      = 5.0    -- m/s  kept for jbeam override compat; unused internally
local WALK_GRACE       = 0.8    -- s    no-ragdoll window at WALKING start
local SETUP_TIMEOUT    = 2.0    -- s    max SETUP wait before assuming direct spawn
-- Time between velocity pushes.  Physics runs freely between pushes: terrain Z
-- adjusts via contact forces, stabiliser beams restabilise, collisions are
-- handled naturally — nodes cannot clip through geometry.
local WALK_INTERVAL    = 0.1    -- s
local MAX_WALK_SPEED   = 1.5    -- m/s  hard cap (prevents runaway from jbeam overrides)

-- Displacement² of the intestine-vs-thorax relative vector that signals an impact.
-- Normal stabiliser-beam settling moves both nodes together (<2 mm delta).
-- A car hit pushes the outer thorax shell by 5+ cm while the inner intestine lags.
local IMPACT_REL_SQ = 0.02 * 0.02  -- (2 cm)²

-- Distance² threshold for traffic-script placement detection
local PLACED_JUMP_SQ = 2.0 * 2.0  -- (2 m)²

-- Obstacle-turn random kick range: ±TURN_ANGLE_RAD either side of full reversal
local TURN_ANGLE_RAD  = math.pi / 3   -- ±60° (so total spread = 120°)
-- Gentle direction drift magnitude each walkChangePeriod
local DRIFT_ANGLE_RAD = math.pi / 9   -- ±20°

-- Named nodes (fallback to auto-detect if absent in a skin)
local HEAD_NODE_NAME      = "dummy1_headtip"
local THORAX_NODE_NAME    = "dummy1_thoraxtfl"
local INTESTINE_NODE_NAME = "oi1"             -- soft inner node; no collision surface

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Returns true if an obstacle is within TURN_DIST m in the given direction.
local function obstacleAhead(fromPos, dirX, dirY)
    -- Static geometry ray (walls, terrain steps, buildings)
    local ok, rayHit = pcall(function()
        if not castRayStatic then return nil end
        return castRayStatic(fromPos, vec3(
            fromPos.x + dirX * TURN_DIST,
            fromPos.y + dirY * TURN_DIST,
            fromPos.z))
    end)
    if ok and rayHit then return true end

    -- Vehicle-cone scan (GE context only; guard for VE Lua safety)
    if be then
        local myId  = obj:getId()
        local count = be:getVehicleCount()
        for i = 0, count - 1 do
            local veh = be:getVehicle(i)
            if veh and veh:getID() ~= myId then
                local vp    = veh:getPosition()
                local ex    = vp.x - fromPos.x
                local ey    = vp.y - fromPos.y
                local dot   = ex * dirX + ey * dirY
                local cross = ex * dirY - ey * dirX
                if dot > 0 and dot < TURN_DIST and math.abs(cross) < TURN_CONE_HALF then
                    return true
                end
            end
        end
    end
    return false
end

-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────

local function init(jbeamData)
    walkSpeed        = jbeamData.walkSpeed        or walkSpeed
    walkChangePeriod = jbeamData.walkChangePeriod or walkChangePeriod
    TURN_DIST        = jbeamData.turnDist         or TURN_DIST
    RAGDOLL_VEL      = jbeamData.ragdollVel       or RAGDOLL_VEL
    WALK_INTERVAL    = jbeamData.walkInterval     or WALK_INTERVAL
    WALK_GRACE       = jbeamData.walkGrace        or WALK_GRACE

    -- Scan all nodes to find head, thorax, and intestine cids.
    -- nodeCids is built later at the SETUP→WALKING transition (world coords are
    -- not valid at init() time for traffic-script-placed vehicles).
    headCid      = nil
    thoraxCid    = nil
    intestineCid = nil
    nodeCids  = {}
    local maxZ = -math.huge

    for _, n in pairs(v.data.nodes) do
        local cid = n.cid
        if n.name == THORAX_NODE_NAME    then thoraxCid    = cid end
        if n.name == INTESTINE_NODE_NAME then intestineCid = cid end
        if n.name == HEAD_NODE_NAME then
            headCid = cid
        elseif headCid == nil then
            local p = vec3(obj:getNodePosition(cid))
            if p.z > maxZ then maxZ = p.z; headCid = cid end
        end
    end

    if not thoraxCid then thoraxCid = headCid end

    math.randomseed(obj:getId())

    walkDir             = math.random() * 2 * math.pi
    walkTimer           = 0
    walkIntervalTimer   = 0
    walkGraceTimer      = 0
    prevHeadX           = nil
    prevHeadY           = nil
    relBaseX            = nil
    relBaseY            = nil
    relBaseZ            = nil
    setupTimer          = 0.0
    state               = "setup"
end


local function reset()
    math.randomseed(obj:getId() + os.time())
    walkDir             = math.random() * 2 * math.pi
    walkTimer           = 0
    walkIntervalTimer   = 0
    walkGraceTimer      = 0
    prevHeadX           = nil
    prevHeadY           = nil
    relBaseX            = nil
    relBaseY            = nil
    relBaseZ            = nil
    nodeCids            = {}
    setupTimer          = 0.0
    state               = "setup"
end


local function updateGFX(dt)
    if dt <= 0 then return end
    if not headCid then return end

    if state == "ragdoll" then return end

    local hp = vec3(obj:getNodePosition(headCid))

    -- ── SETUP: wait for world-placement, then collect node CIDs ──────────────
    if state == "setup" then
        setupTimer = setupTimer + dt

        local doStart = false
        if prevHeadX ~= nil then
            local ddx = hp.x - prevHeadX
            local ddy = hp.y - prevHeadY
            if (ddx * ddx + ddy * ddy) >= PLACED_JUMP_SQ then doStart = true end
        end
        if setupTimer >= SETUP_TIMEOUT then doStart = true end

        if doStart then
            -- Collect all node CIDs.  No spawn positions are stored — velocity-push
            -- locomotion does not need them; position is tracked by the physics engine.
            nodeCids = {}
            for _, n in pairs(v.data.nodes) do
                table.insert(nodeCids, n.cid)
            end
            walkIntervalTimer = 0
            -- Fresh random walk direction at WALKING start
            walkDir           = math.random() * 2 * math.pi

            -- Capture initial intestine-vs-thorax relative position baseline.
            -- Refreshed at every step start — see below.
            if intestineCid and thoraxCid then
                local ip = vec3(obj:getNodePosition(intestineCid))
                local tp = vec3(obj:getNodePosition(thoraxCid))
                relBaseX = ip.x - tp.x
                relBaseY = ip.y - tp.y
                relBaseZ = ip.z - tp.z
            end

            walkGraceTimer = WALK_GRACE
            state          = "walking"
            return
        end

        prevHeadX = hp.x
        prevHeadY = hp.y
        return
    end

    -- ── WALKING ───────────────────────────────────────────────────────────────

    if walkGraceTimer > 0 then walkGraceTimer = walkGraceTimer - dt end

    -- Settling phase: physics runs freely between velocity pushes.
    -- Monitor the intestine-vs-thorax relative position for an impact signal.
    -- The velocity push is applied to ALL nodes equally, so the relative vector
    -- is nearly constant during normal walking.  A vehicle impact applies a
    -- collision impulse to the outer thorax shell (collision geometry) but NOT
    -- to the inner intestine node (no collision surface), making the vector
    -- diverge — a reliable hit signal that is immune to normal walking drift.
    walkIntervalTimer = walkIntervalTimer + dt
    if walkIntervalTimer < WALK_INTERVAL then
        if walkGraceTimer <= 0 and intestineCid and thoraxCid and relBaseX ~= nil then
            local ip  = vec3(obj:getNodePosition(intestineCid))
            local tp  = vec3(obj:getNodePosition(thoraxCid))
            local ddx = (ip.x - tp.x) - relBaseX
            local ddy = (ip.y - tp.y) - relBaseY
            local ddz = (ip.z - tp.z) - relBaseZ
            if ddx*ddx + ddy*ddy + ddz*ddz > IMPACT_REL_SQ then
                state = "ragdoll"
                return
            end
        end
        return  -- still settling; wait for next push
    end
    walkIntervalTimer = 0

    -- ── Step time: choose direction, apply velocity push ─────────────────────

    local dirX = math.sin(walkDir)
    local dirY = math.cos(walkDir)

    -- Obstacle check at each step: probe from current head position
    if obstacleAhead(hp, dirX, dirY) then
        -- Reverse with a ±TURN_ANGLE_RAD random kick so the dummy doesn't oscillate
        walkDir = walkDir + math.pi + (math.random() - 0.5) * TURN_ANGLE_RAD
        dirX    = math.sin(walkDir)
        dirY    = math.cos(walkDir)
    end

    -- Gentle direction drift every walkChangePeriod
    walkTimer = walkTimer + WALK_INTERVAL
    if walkTimer >= walkChangePeriod then
        walkTimer = 0
        walkDir   = walkDir + (math.random() - 0.5) * DRIFT_ANGLE_RAD
    end

    -- Apply walk velocity to every node.
    -- Z is set to 0 — gravity and terrain contact forces handle vertical movement
    -- automatically on all surface types (slopes, banked roads, kerbs).
    -- Walls and other geometry absorb the velocity through the physics solver;
    -- no node can be "teleported into" solid geometry.
    local speed = math.min(walkSpeed, MAX_WALK_SPEED)
    for _, cid in ipairs(nodeCids) do
        obj:setNodeVelocity(cid, dirX * speed, dirY * speed, 0)
    end

    -- Refresh relBase right after the push so the settling window measures
    -- deviation from a fresh known-good baseline.  This prevents long-run drift
    -- from accumulated beam-spring creep causing false ragdolls.
    if intestineCid and thoraxCid then
        local ip = vec3(obj:getNodePosition(intestineCid))
        local tp = vec3(obj:getNodePosition(thoraxCid))
        relBaseX = ip.x - tp.x
        relBaseY = ip.y - tp.y
        relBaseZ = ip.z - tp.z
    end
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
