-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingPedestrianWalker.lua
-- Fresh pedestrian walking controller for the Jonesing agenty_dummy.
-- Replaces the previous jonesingGtaNpc.lua approach.
--
-- Core mechanic — "all-node locomotion":
--   Every body node is teleported each frame by the same XY walk-offset so all
--   beam lengths remain constant (no stretching / snapping).  This keeps the
--   dummy rigid and upright while walking and prevents the head-detach that
--   occurred when only the head node was moved.
--   A strong impact (car, explosion, etc.) will displace the thorax node away
--   from where we placed it; once that deviation exceeds IMPACT_THRESHOLD_SQ the
--   controller stops all overrides and the dummy enters full ragdoll forever.
--
-- Walk movement:
--   After world-placement is detected every node's spawn position is captured.
--   Each frame the walk offset advances by (walkSpeed * dt) in the current
--   direction and every node is placed at spawnPos + walkOffset.
--   Terrain following on Z: each node's Z is only allowed to rise (tracks
--   uphill), never forced down (prevents sinking / fighting gravity).
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
--   position. We wait until the head node jumps more than 2 m in one frame
--   (traffic-script teleport), or until SETUP_TIMEOUT seconds have elapsed
--   (direct spawn — no jump ever occurs), then capture all node positions and
--   begin walking.
--
-- Ragdoll detection (WALKING → RAGDOLL):
--   Because we teleport ALL nodes together, the thorax should remain exactly
--   where we placed it unless an external force acted on the body.  A deviation
--   larger than IMPACT_THRESHOLD_SQ (3 cm) signals a physical hit; we stop all
--   overrides so the dummy tumbles/flies naturally.
--
-- States:  SETUP → WALKING → RAGDOLL
--   SETUP   — waiting for the traffic-script world-placement teleport
--   WALKING — all nodes moved together; body is rigid but fully collidable
--   RAGDOLL — no overrides; full physics forever

local M = {}

-- ── state ─────────────────────────────────────────────────────────────────────
local state = "setup"   -- "setup", "walking", "ragdoll"

-- node IDs
local headCid   = nil   -- topmost node (head crown / headtip) — used as forward probe origin
local thoraxCid = nil   -- chest reference node for hit detection
-- All-node records: {cid, spawnX, spawnY, spawnZ} — populated at SETUP→WALKING transition.
-- Moving every node by the same XY offset keeps all beam lengths constant, preventing
-- the head-detach / beam-snap that occurred when only the head node was teleported.
local nodeRecs  = {}
-- Direct reference to the thorax entry in nodeRecs (avoids O(n) search every frame).
local thoraxRec = nil

-- accumulated walk offset (added to every node's spawn position each frame)
local walkOffsetX = 0.0
local walkOffsetY = 0.0

-- walk state
local walkDir        = 0.0  -- radians; direction measured from +Y axis, clockwise
local walkTimer      = 0.0  -- accumulator for periodic direction drift
local rayTimer       = 0.0  -- accumulator for obstacle checks
local walkGraceTimer = 0.0  -- brief no-ragdoll window right after WALKING begins

-- SETUP: previous head node position for jump detection + fallback timer
local prevHeadX  = nil
local prevHeadY  = nil
local setupTimer = 0.0  -- counts up in SETUP state; forces WALKING after SETUP_TIMEOUT

-- WALKING: world position of the thorax as placed last frame (for hit detection).
-- If the thorax deviates more than IMPACT_THRESHOLD_SQ from where we placed it, a
-- physical impact has occurred and we drop into ragdoll.
local lastThoraxPlacedX = nil
local lastThoraxPlacedY = nil

-- ── tuneable parameters (overridable from jbeam slot data) ────────────────────
local walkSpeed        = 1.2   -- m/s  pedestrian pace
local walkChangePeriod = 6.0   -- s    seconds between random direction tweaks
local RAY_INTERVAL     = 0.30  -- s    seconds between forward obstacle probes
local TURN_DIST        = 4.0   -- m    obstacle turn-trigger distance
local TURN_CONE_HALF   = 1.5   -- m    lateral half-width of the forward cone
local RAGDOLL_VEL      = 5.0   -- m/s  kept for jbeam override compat; unused internally
local WALK_GRACE       = 0.4   -- s    grace period after WALKING start (no ragdoll check)
-- If no traffic-script teleport jump is detected within this many seconds of
-- init(), assume the vehicle was already placed at world position (direct spawn)
-- and start walking anyway.
local SETUP_TIMEOUT    = 2.0   -- s

-- Displacement² from our last node placement that signals a physical impact.
-- Moving all nodes together means the only way the thorax deviates from where we
-- placed it is if an external force (car hit, explosion, etc.) acted on the body.
-- 3 cm covers vehicle impacts cleanly while ignoring normal physics drift.
local IMPACT_THRESHOLD_SQ = 0.03 * 0.03  -- (3 cm)²

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
    --    'be' (BeamEngine) is only available in GE context; guard for safety.
    if be then
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

    -- Scan all nodes: find the topmost (head anchor) and named thorax node.
    -- nodeRecs is populated later at the SETUP→WALKING transition (world coords
    -- are not valid at init() time for traffic-script-placed vehicles).
    headCid   = nil
    thoraxCid = nil
    nodeRecs  = {}
    thoraxRec = nil
    local maxZ = -math.huge

    for _, n in pairs(v.data.nodes) do
        local cid = n.cid

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
    prevHeadX           = nil
    prevHeadY           = nil
    lastThoraxPlacedX   = nil
    lastThoraxPlacedY   = nil
    setupTimer          = 0.0
    state               = "setup"
end


local function reset()
    -- Re-randomise direction and restart from SETUP on vehicle reset.
    -- Mix in os.time() so repeated resets produce different directions.
    math.randomseed(obj:getId() + os.time())
    walkDir             = math.random() * 2 * math.pi
    walkOffsetX         = 0
    walkOffsetY         = 0
    walkTimer           = 0
    rayTimer            = 0
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
    if not headCid  then return end

    -- ── RAGDOLL: no overrides, just let physics run ───────────────────────────
    if state == "ragdoll" then return end

    local hp = vec3(obj:getNodePosition(headCid))

    -- ── SETUP: wait for the traffic-script world-placement teleport ───────────
    -- We also accept the current position after SETUP_TIMEOUT seconds so that
    -- directly-spawned dummies (no traffic-script teleport jump) still walk.
    if state == "setup" then
        setupTimer = setupTimer + dt

        local doStart = false
        if prevHeadX ~= nil then
            local ddx = hp.x - prevHeadX
            local ddy = hp.y - prevHeadY
            if (ddx * ddx + ddy * ddy) >= PLACED_JUMP_SQ then
                -- Vehicle was just teleported to its world spawn position.
                doStart = true
            end
        end
        -- Fallback: if no teleport jump within SETUP_TIMEOUT, start walking from
        -- wherever we are.  This handles direct-spawn (no jump ever occurs).
        if setupTimer >= SETUP_TIMEOUT then
            doStart = true
        end

        if doStart then
            -- Capture current world positions for ALL nodes.
            -- Moving every node by the same XY offset keeps all beam lengths
            -- constant → no stretching, no snapping, no head detachment.
            nodeRecs  = {}
            thoraxRec = nil
            for _, n in pairs(v.data.nodes) do
                local p   = vec3(obj:getNodePosition(n.cid))
                local rec = {cid=n.cid, spawnX=p.x, spawnY=p.y, spawnZ=p.z}
                table.insert(nodeRecs, rec)
                if n.cid == thoraxCid then thoraxRec = rec end
            end
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

            -- Initialise lastThoraxPlaced so the first-frame hit check has zero
            -- displacement and doesn't spuriously trigger ragdoll.
            if thoraxRec then
                lastThoraxPlacedX = thoraxRec.spawnX
                lastThoraxPlacedY = thoraxRec.spawnY
            end

            walkGraceTimer = WALK_GRACE
            state          = "walking"
            return
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

    -- 1. Hit detection: compare thorax current position vs where we placed it last
    --    frame.  Because we teleport ALL nodes together each frame, the only way the
    --    thorax deviates from its placed position is an external physical impulse.
    if walkGraceTimer <= 0 and thoraxRec and lastThoraxPlacedX ~= nil then
        local tp  = vec3(obj:getNodePosition(thoraxRec.cid))
        local ddx = tp.x - lastThoraxPlacedX
        local ddy = tp.y - lastThoraxPlacedY
        if (ddx * ddx + ddy * ddy) > IMPACT_THRESHOLD_SQ then
            state = "ragdoll"
            return
        end
    end

    -- 2. Obstacle check: probe the path ahead; turn around if blocked.
    rayTimer = rayTimer + dt
    if rayTimer >= RAY_INTERVAL then
        rayTimer = 0
        local dirX    = math.sin(walkDir)
        local dirY    = math.cos(walkDir)
        local fromPos = vec3(obj:getNodePosition(headCid))
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

    -- 5. Move ALL nodes by the same walk offset.
    --    Constant beam lengths → no internal stretching forces → no snapping.
    --    Z tracking: allow each node to rise with uphill terrain; never force
    --    it down (prevents gravity-accumulation / sinking into the ground).
    for _, rec in ipairs(nodeRecs) do
        local curZ = obj:getNodePosition(rec.cid).z
        if curZ > rec.spawnZ then rec.spawnZ = curZ end
        obj:setNodePosition(rec.cid, vec3(
            rec.spawnX + walkOffsetX,
            rec.spawnY + walkOffsetY,
            rec.spawnZ
        ))
    end

    -- 6. Record where we placed the thorax this frame so the next frame's hit
    --    check has a valid baseline.  thoraxRec is a direct reference set once
    --    at WALKING start — no per-frame search needed.
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
