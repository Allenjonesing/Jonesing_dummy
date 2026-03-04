-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingPedestrianWalker.lua
-- Pedestrian walking controller for the Jonesing agenty_dummy.
--
-- Core mechanic — TRUE interval-based step-walk:
--   All nodes are teleported once per WALK_INTERVAL (default 0.1 s).
--   Between steps the physics engine runs COMPLETELY FREELY — no teleportation
--   at all.  This means:
--     • Stabiliser beams keep the dummy upright without fighting teleportation.
--     • Terrain Z adjusts automatically via contact forces (slopes, banked roads).
--     • Vehicle and wall collisions are handled by the physics solver before we
--       move again — the dummy cannot be "fused" into a vehicle.
--     • Slow-motion mode is stable: steps occur at the same rate in GAME TIME
--       regardless of real-time frame rate, and physics settles freely between.
--
-- Impact detection (WALKING → RAGDOLL):
--   After each step we record where we placed the chest/thorax node (lastPlacedX/Y).
--   During the settling window we compare the current thorax position against that
--   recorded position.  If physics has moved it more than IMPACT_XY (default 5 cm)
--   something externally hit the dummy — we trigger ragdoll.
--   This works for ANY external impact (car, physics object) without needing `be`
--   (BeamEngine), which is only available in GE context, not VE controller Lua.
--
-- Obstacle detection (static geometry):
--   castRayStatic is used to detect walls and terrain edges ahead.  A hit reverses
--   the walk direction with a random ±60° kick.
--
-- Walk direction:
--   A random direction is chosen at WALKING start and gently drifted ±20° every
--   walkChangePeriod seconds.  On obstacle detection the direction reverses.
--
-- World-placement detection (SETUP → WALKING):
--   Waits for a >2 m head-node jump (traffic-script teleport) OR SETUP_TIMEOUT
--   seconds (direct spawn), then snapshots all node XY positions and starts.
--
-- States:  SETUP → WALKING → RAGDOLL

local M = {}

-- ── state ─────────────────────────────────────────────────────────────────────
local state = "setup"

-- key node CIDs
local headCid   = nil   -- topmost node — obstacle ray origin
local thoraxCid = nil   -- outer chest shell — impact reference node

-- per-node spawn XY (Z read live from physics at each step)
local nodeRecs  = {}    -- {cid, spawnX, spawnY}

-- accumulated XY walk offset applied to all node spawn positions
local walkOffsetX = 0.0
local walkOffsetY = 0.0

-- position where we last placed the thorax — used for impact detection
local lastPlacedX = nil
local lastPlacedY = nil

-- walk state
local walkDir           = 0.0  -- radians  (+Y = north, clockwise)
local walkTimer         = 0.0  -- seconds since last direction drift
local walkIntervalTimer = 0.0  -- seconds since last step
local walkGraceTimer    = 0.0  -- no-ragdoll window at WALKING start

-- SETUP placement detection
local prevHeadX  = nil
local prevHeadY  = nil
local setupTimer = 0.0

-- ── tuneable parameters (all overridable via jbeam slot data) ─────────────────
-- walkSpeed: metres per second — the dummy advances this far per second of game time
-- WALK_INTERVAL: seconds between steps — physics settles freely between steps
-- Per-step advance = walkSpeed × WALK_INTERVAL (e.g. 0.3 × 0.1 = 3 cm/step)
local walkSpeed        = 0.3    -- m/s
local walkChangePeriod = 6.0    -- s   — how often direction gently drifts
local TURN_DIST        = 4.0    -- m   — static-obstacle look-ahead distance
local WALK_GRACE       = 0.5    -- s   — spawn-stabilisation no-ragdoll window
local SETUP_TIMEOUT    = 2.0    -- s   — max wait in SETUP before direct-spawn fallback
local WALK_INTERVAL    = 0.1    -- s   — step period; physics settles between steps
local MAX_WALK_SPEED   = 1.0    -- m/s — safety cap for jbeam overrides

-- Impact detection: thorax XY displacement that signals an external hit.
-- Normal physics settling after a step creates < 1–2 cm of XY displacement
-- in the thorax.  A vehicle impact creates ≥ 5 cm in the settling window.
local IMPACT_XY_SQ = 0.05 * 0.05  -- (5 cm)²

-- Traffic-script placement detection: head jumps > 2 m in one frame
local PLACED_JUMP_SQ  = 2.0 * 2.0  -- (2 m)²

-- Obstacle-avoidance direction-kick magnitude
local TURN_ANGLE_RAD  = math.pi / 3   -- ±60° kick on obstacle
-- Gentle drift per walkChangePeriod
local DRIFT_ANGLE_RAD = math.pi / 9   -- ±20°

local HEAD_NODE_NAME   = "dummy1_headtip"
local THORAX_NODE_NAME = "dummy1_thoraxtfl"

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Returns true if static geometry (wall, terrain step) is within TURN_DIST m.
local function obstacleAhead(fromPos, dirX, dirY)
    if TURN_DIST <= 0 then return false end
    local ok, hit = pcall(function()
        if not castRayStatic then return nil end
        return castRayStatic(fromPos, vec3(
            fromPos.x + dirX * TURN_DIST,
            fromPos.y + dirY * TURN_DIST,
            fromPos.z))
    end)
    return ok and hit ~= nil
end

-- Teleport all nodes one step forward and record thorax placement.
local function doStep()
    for _, rec in ipairs(nodeRecs) do
        local curZ = obj:getNodePosition(rec.cid).z
        obj:setNodePosition(rec.cid, vec3(
            rec.spawnX + walkOffsetX,
            rec.spawnY + walkOffsetY,
            curZ
        ))
    end
    -- Record thorax position immediately after placement for next impact check.
    if thoraxCid then
        local tp  = obj:getNodePosition(thoraxCid)
        lastPlacedX = tp.x
        lastPlacedY = tp.y
    end
end

-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────

local function init(jbeamData)
    walkSpeed        = jbeamData.walkSpeed        or walkSpeed
    walkChangePeriod = jbeamData.walkChangePeriod or walkChangePeriod
    TURN_DIST        = jbeamData.turnDist         or TURN_DIST
    WALK_INTERVAL    = jbeamData.walkInterval     or WALK_INTERVAL
    WALK_GRACE       = jbeamData.walkGrace        or WALK_GRACE

    headCid   = nil
    thoraxCid = nil
    nodeRecs  = {}
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

    walkDir           = math.random() * 2 * math.pi
    walkOffsetX       = 0
    walkOffsetY       = 0
    walkTimer         = 0
    walkIntervalTimer = 0
    walkGraceTimer    = 0
    lastPlacedX       = nil
    lastPlacedY       = nil
    prevHeadX         = nil
    prevHeadY         = nil
    setupTimer        = 0.0
    state             = "setup"
end


local function reset()
    math.randomseed(obj:getId() + os.time())
    walkDir           = math.random() * 2 * math.pi
    walkOffsetX       = 0
    walkOffsetY       = 0
    walkTimer         = 0
    walkIntervalTimer = 0
    walkGraceTimer    = 0
    lastPlacedX       = nil
    lastPlacedY       = nil
    prevHeadX         = nil
    prevHeadY         = nil
    nodeRecs          = {}
    setupTimer        = 0.0
    state             = "setup"
end


local function updateGFX(dt)
    if dt <= 0 then return end
    if not headCid then return end
    if state == "ragdoll" then return end

    local hp = vec3(obj:getNodePosition(headCid))

    -- ── SETUP: wait for world-placement, snapshot node positions ─────────────
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
            -- Snapshot XY spawn positions.  Z is never stored — read live each step.
            nodeRecs = {}
            for _, n in pairs(v.data.nodes) do
                local p = vec3(obj:getNodePosition(n.cid))
                table.insert(nodeRecs, {cid=n.cid, spawnX=p.x, spawnY=p.y})
            end
            walkOffsetX       = 0
            walkOffsetY       = 0
            -- Fire first step immediately on next update.
            walkIntervalTimer = WALK_INTERVAL
            walkDir           = math.random() * 2 * math.pi
            walkTimer         = 0
            walkGraceTimer    = WALK_GRACE
            lastPlacedX       = nil
            lastPlacedY       = nil
            state             = "walking"
            return
        end

        prevHeadX = hp.x
        prevHeadY = hp.y
        return
    end

    -- ── WALKING ───────────────────────────────────────────────────────────────

    if walkGraceTimer > 0 then walkGraceTimer = walkGraceTimer - dt end

    walkIntervalTimer = walkIntervalTimer + dt

    -- Settling window (between steps): NO teleportation.
    -- Physics runs freely — stabilisers hold the dummy upright, gravity keeps
    -- feet on terrain, and vehicle/wall collisions are handled naturally.
    if walkIntervalTimer < WALK_INTERVAL then
        -- Impact detection: compare thorax to where we placed it this step.
        -- Normal physics settling moves the thorax < 2 cm in the settling window.
        -- A vehicle or physics-object impact moves it > 5 cm → ragdoll.
        if walkGraceTimer <= 0 and thoraxCid and lastPlacedX ~= nil then
            local tp  = obj:getNodePosition(thoraxCid)
            local ddx = tp.x - lastPlacedX
            local ddy = tp.y - lastPlacedY
            if ddx * ddx + ddy * ddy > IMPACT_XY_SQ then
                state = "ragdoll"
                return
            end
        end
        return  -- still settling — do nothing
    end

    -- ── Step time ─────────────────────────────────────────────────────────────
    walkIntervalTimer = 0

    -- Choose direction for this step.
    local dirX = math.sin(walkDir)
    local dirY = math.cos(walkDir)

    -- Static-obstacle check (walls, terrain edges).
    if obstacleAhead(hp, dirX, dirY) then
        walkDir = walkDir + math.pi + (math.random() - 0.5) * TURN_ANGLE_RAD
        dirX    = math.sin(walkDir)
        dirY    = math.cos(walkDir)
    end

    -- Gentle periodic direction drift.
    walkTimer = walkTimer + WALK_INTERVAL
    if walkChangePeriod > 0 and walkTimer >= walkChangePeriod then
        walkTimer = 0
        walkDir   = walkDir + (math.random() - 0.5) * DRIFT_ANGLE_RAD
    end

    -- Advance XY offset by one step (fixed distance, dt-independent).
    -- This is why the walker is stable in slow motion: each step advances the
    -- same distance in game time regardless of real-time frame rate.
    local step = math.min(walkSpeed, MAX_WALK_SPEED) * WALK_INTERVAL
    walkOffsetX = walkOffsetX + dirX * step
    walkOffsetY = walkOffsetY + dirY * step

    -- Teleport all nodes and record thorax placement.
    doStep()
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
