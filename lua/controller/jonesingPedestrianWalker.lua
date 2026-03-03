-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingPedestrianWalker.lua
-- Pedestrian walking controller for the Jonesing agenty_dummy.
--
-- Core mechanic — "step-walk with physics settling":
--   Every WALK_INTERVAL seconds all body nodes are teleported one step forward
--   (XY advances by walkSpeed × WALK_INTERVAL; Z is always read live from
--   physics at step time).  Between steps the physics engine runs freely: the
--   feet settle to terrain height (automatic slope / banked-road following),
--   stabiliser beams keep the dummy upright, and vehicle collisions are handled
--   by the physics engine before we move the dummy further — preventing the
--   "teleport into wall → explosion" problem.
--
-- Walk direction:
--   A random direction is chosen at WALKING start and updated with gentle ±20°
--   drifts every walkChangePeriod seconds.  On detecting an obstacle the
--   direction is reversed with a ±30° random kick.
--
-- Terrain Z following:
--   Z is NOT stored in nodeRecs.  At each step the current physics Z of every
--   node is read directly and used for the teleport.  This means uphill, downhill,
--   and banked-road surfaces are all followed automatically without any manual
--   Z tracking.
--
-- Ragdoll detection (WALKING → RAGDOLL):
--   During each settling window (between steps) the thorax XY is compared with
--   its last-placed position.  A deviation > IMPACT_THRESHOLD_SQ (15 cm) signals
--   a physical hit; all overrides are released and physics takes over forever.
--
-- World-placement detection (SETUP → WALKING):
--   Waits for a >2 m head-node jump (traffic-script teleport) or SETUP_TIMEOUT
--   seconds (direct spawn), then captures all node XY positions and starts.
--
-- States:  SETUP → WALKING → RAGDOLL
--   SETUP   — waiting for world-placement
--   WALKING — step-walk active; physics settles between steps
--   RAGDOLL — no overrides; full physics forever

local M = {}

-- ── state ─────────────────────────────────────────────────────────────────────
local state = "setup"

-- node IDs
local headCid   = nil   -- topmost node (head crown / headtip) — obstacle ray origin
local thoraxCid = nil   -- chest reference node for impact detection
-- Per-node spawn XY.  Z is NOT stored — always read live from physics at step
-- time so the dummy automatically follows terrain slopes and banked roads.
local nodeRecs  = {}    -- {cid, spawnX, spawnY}
local thoraxRec = nil   -- direct reference into nodeRecs for O(1) access

-- accumulated XY walk offset
local walkOffsetX = 0.0
local walkOffsetY = 0.0

-- walk state
local walkDir           = 0.0  -- radians; +Y axis = north, clockwise
local walkTimer         = 0.0  -- time since last direction drift (in step-units)
local walkIntervalTimer = 0.0  -- time since last teleport step
local walkGraceTimer    = 0.0  -- no-ragdoll window at WALKING start

-- SETUP detection
local prevHeadX  = nil
local prevHeadY  = nil
local setupTimer = 0.0

-- last-placed thorax XY for impact detection during settling window
local lastThoraxPlacedX = nil
local lastThoraxPlacedY = nil

-- ── tuneable parameters (overridable from jbeam slot data) ────────────────────
local walkSpeed        = 0.02   -- m/s  comfortable pedestrian pace
local walkChangePeriod = 6.0   -- s    seconds between gentle direction tweaks
local TURN_DIST        = 4.0   -- m    obstacle turn-trigger distance
local TURN_CONE_HALF   = 1.5   -- m    lateral half-width of forward cone
local RAGDOLL_VEL      = 5.0   -- m/s  kept for jbeam override compat; unused internally
local WALK_GRACE       = 0.8   -- s    no-ragdoll window at WALKING start
local SETUP_TIMEOUT    = 2.0   -- s    max SETUP wait before assuming direct spawn
-- Time between teleport steps.  Physics runs freely between steps: terrain Z
-- adjusts, stabiliser beams restabilise, collisions are handled by physics.
local WALK_INTERVAL    = 0.05  -- s
local MAX_WALK_SPEED   = 0.1   -- m/s  hard cap on effective speed (prevents runaway)

-- Displacement² from our last node placement that signals a physical impact.
-- Stabiliser beams hold the body to within ~5 cm of its placed position;
-- a vehicle impact displaces it 15+ cm.
local IMPACT_THRESHOLD_SQ = 0.15 * 0.15  -- (15 cm)²

-- Distance² threshold for traffic-script placement detection
local PLACED_JUMP_SQ = 2.0 * 2.0  -- (2 m)²

-- Obstacle-turn random kick range: ±TURN_ANGLE_RAD either side of full reversal
local TURN_ANGLE_RAD  = math.pi / 3   -- ±60° (so total spread = 120°)
-- Gentle direction drift magnitude each walkChangePeriod
local DRIFT_ANGLE_RAD = math.pi / 9   -- ±20°

-- Named nodes (fallback to auto-detect if absent in a skin)
local HEAD_NODE_NAME   = "dummy1_headtip"
local THORAX_NODE_NAME = "dummy1_thoraxtfl"

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

    -- Scan all nodes to find head and thorax cids.
    -- nodeRecs is built later at the SETUP→WALKING transition (world coords are
    -- not valid at init() time for traffic-script-placed vehicles).
    headCid   = nil
    thoraxCid = nil
    nodeRecs  = {}
    thoraxRec = nil
    local maxZ = -math.huge

    for _, n in pairs(v.data.nodes) do
        local cid = n.cid
        if n.name == THORAX_NODE_NAME then thoraxCid = cid end
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
    walkOffsetX         = 0
    walkOffsetY         = 0
    walkTimer           = 0
    walkIntervalTimer   = 0
    walkGraceTimer      = 0
    prevHeadX           = nil
    prevHeadY           = nil
    lastThoraxPlacedX   = nil
    lastThoraxPlacedY   = nil
    setupTimer          = 0.0
    state               = "setup"
end


local function reset()
    math.randomseed(obj:getId() + os.time())
    walkDir             = math.random() * 2 * math.pi
    walkOffsetX         = 0
    walkOffsetY         = 0
    walkTimer           = 0
    walkIntervalTimer   = 0
    walkGraceTimer      = 0
    prevHeadX           = nil
    prevHeadY           = nil
    lastThoraxPlacedX   = nil
    lastThoraxPlacedY   = nil
    nodeRecs            = {}
    thoraxRec           = nil
    setupTimer          = 0.0
    state               = "setup"
end


local function updateGFX(dt)
    if dt <= 0 then return end
    if not headCid then return end

    if state == "ragdoll" then return end

    local hp = vec3(obj:getNodePosition(headCid))

    -- ── SETUP: wait for world-placement, then capture spawn XY ───────────────
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
            -- Capture XY spawn positions for every node.
            -- Z is intentionally NOT stored — it is always read live from
            -- physics at step time so the dummy follows terrain automatically.
            nodeRecs  = {}
            thoraxRec = nil
            for _, n in pairs(v.data.nodes) do
                local p   = vec3(obj:getNodePosition(n.cid))
                local rec = {cid=n.cid, spawnX=p.x, spawnY=p.y}
                table.insert(nodeRecs, rec)
                if n.cid == thoraxCid then thoraxRec = rec end
            end
            walkOffsetX       = 0
            walkOffsetY       = 0
            walkIntervalTimer = 0
            -- Fresh random walk direction at WALKING start
            walkDir           = math.random() * 2 * math.pi

            if thoraxRec then
                local tp = vec3(obj:getNodePosition(thoraxRec.cid))
                lastThoraxPlacedX = tp.x
                lastThoraxPlacedY = tp.y
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

    -- Settling phase: physics runs freely between steps.
    -- Monitor thorax for impact but do NOT teleport anything.
    -- This window lets feet settle to terrain Z, handles wall push-back, and
    -- allows vehicle impacts to be detected before the next step overrides them.
    walkIntervalTimer = walkIntervalTimer + dt
    if walkIntervalTimer < WALK_INTERVAL then
        if walkGraceTimer <= 0 and thoraxRec and lastThoraxPlacedX ~= nil then
            local tp  = vec3(obj:getNodePosition(thoraxRec.cid))
            local ddx = tp.x - lastThoraxPlacedX
            local ddy = tp.y - lastThoraxPlacedY
            if (ddx * ddx + ddy * ddy) > IMPACT_THRESHOLD_SQ then
                state = "ragdoll"
                return
            end
        end
        return  -- still settling; wait for next step
    end
    walkIntervalTimer = 0

    -- ── Step time: advance XY, check obstacles, teleport ─────────────────────

    local dirX = math.sin(walkDir)
    local dirY = math.cos(walkDir)

    -- Obstacle check at each step: probe from current head position
    if obstacleAhead(vec3(obj:getNodePosition(headCid)), dirX, dirY) then
        -- Reverse with a ±TURN_ANGLE_RAD random kick so the dummy doesn't just oscillate
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

    -- Advance XY walk offset by one step
    local step = math.min(walkSpeed, MAX_WALK_SPEED) * WALK_INTERVAL
    walkOffsetX = walkOffsetX + dirX * step
    walkOffsetY = walkOffsetY + dirY * step

    -- Teleport all nodes: XY = spawnXY + walkOffset, Z = current physics Z.
    -- Reading Z from physics at step time gives free terrain-following on slopes
    -- and banked roads — no manual Z tracking required.
    for _, rec in ipairs(nodeRecs) do
        local curZ = obj:getNodePosition(rec.cid).z
        obj:setNodePosition(rec.cid, vec3(
            rec.spawnX + walkOffsetX,
            rec.spawnY + walkOffsetY,
            curZ
        ))
    end

    -- Record thorax placed position for next settling window's impact check
    if thoraxRec then
        lastThoraxPlacedX = thoraxRec.spawnX + walkOffsetX
        lastThoraxPlacedY = thoraxRec.spawnY + walkOffsetY
    end
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
