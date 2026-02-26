-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingGtaNpc.lua
-- Enhanced GTA-style NPC controller with FSM (WANDER/IDLE/FLEE/PURSUE) and
-- steering/obstacle avoidance via fan raycasts.
--
-- PHYSICS STATES:
--   "grace"    — hold dummy upright during traffic-script world placement.
--   "active"   — ghost-mode: nodes teleported every frame; AI FSM drives movement.
--   "standing" — position overrides OFF; physics body after vehicle impact.
--
-- AI STATES (within "active"):
--   "wander"  — semi-random walk biased toward open space via fan raycasts.
--   "idle"    — stand still for a short random duration, then return to wander.
--   "flee"    — run away from threatPos at fleeSpeed.
--   "pursue"  — walk/run toward targetPos, stop on arrival.
--
-- Steering layer (run at aiTickHz, default 15 Hz):
--   Fan of 3 raycasts: forward, ±rayFanAngle.
--   desiredHeading is updated each AI tick; currentHeading is smoothly rotated
--   toward desiredHeading every frame at turnRateMax rad/s.
--   Stuck detection: if speed intent > 0 but XY movement < stuckSpeedMin for
--   stuckTime seconds, reseed heading randomly.
--
-- External API:
--   M.setState(newState, params)   params: {targetPos, threatPos, duration}
--   M.setDebug(enabled)
--   M.getState()  →  "grace" | "active-wander" | "active-idle" | … | "standing"
--
-- All tunables live in the config table below and can be overridden via jbeam
-- slot params (same key names).

local M = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Config / Tunables (all overridable from jbeam slot params)
-- ─────────────────────────────────────────────────────────────────────────────
local config = {
    -- Speeds (m/s)
    walkSpeed        = 0.9,          -- default wander/pursue speed
    runSpeed         = 4.0,          -- flee/panic speed
    maxWalkSpeed     = 2.235,        -- absolute per-frame cap (~5 mph)

    -- Obstacle-avoidance raycasting
    rayLenWalk       = 3.0,          -- m, ray length while walking
    rayLenRun        = 6.0,          -- m, ray length while running/fleeing
    rayFanAngle      = math.pi / 9,  -- ±20° side rays (radians)

    -- Steering / turn-rate
    turnRateMax      = math.pi,      -- rad/s max smooth turn rate (180°/s)
    avoidanceWeight  = 1.5,          -- multiplier for avoidance steering

    -- WANDER behaviour
    wanderInterval   = 4.0,          -- s between random heading samples
    wanderAngleMax   = math.pi / 4,  -- ±45° per random heading change
    dirChangeMag     = math.pi / 36, -- ±5° gentle road-parallel drift per step

    -- IDLE behaviour
    idleChance       = 0.15,         -- probability to idle each wander interval
    idleDurationMin  = 2.0,          -- s
    idleDurationMax  = 5.0,          -- s

    -- FLEE behaviour
    fleeSpeed        = 4.0,          -- m/s
    fleeSafeRadius   = 20.0,         -- m, return to wander when threat is this far
    fleeDurationMax  = 10.0,         -- s, hard timeout on flee state

    -- PURSUE behaviour
    pursueSpeed      = 2.0,          -- m/s
    pursueArrivalR   = 1.5,          -- m, "arrived" threshold
    pursueDuration   = 20.0,         -- s, timeout

    -- Stuck detection
    stuckTime        = 2.5,          -- s below stuckSpeedMin triggers reseed
    stuckSpeedMin    = 0.05,         -- m/s, below this = stuck

    -- AI tick rate
    aiTickHz         = 15,           -- Hz (raycasts + state decisions run here)

    -- Legacy / spawn alignment
    sidewalkOffset   = 0.0,          -- m, lateral shift at spawn

    -- Debug logging (set debugMode=true in jbeam slot to enable)
    debugMode        = false,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Internal state variables
-- ─────────────────────────────────────────────────────────────────────────────
local physState      = "grace"   -- "grace" | "active" | "standing"
local aiState        = "wander"  -- "wander" | "idle" | "flee" | "pursue"

-- Node tables (same mechanism as original implementation)
local allNodes       = {}        -- {cid, spawnX, spawnY, spawnZ, lastX, lastY}
local refCid         = nil       -- cid of chest reference node
local rawNodeIds     = {}        -- all node cids (collected at init)
local localOffsets   = {}        -- {cid, dx, dy, dz} jbeam-local offsets from anchor
local lowestCid      = nil       -- node with minimum jbeam Z (foot level)
local gracePrevX     = nil       -- previous frame grace-period X (jump detection)
local gracePrevY     = nil

-- Body rotation tracking (for facing the walk direction)
local bodyAnchorX    = 0.0       -- world X of anchor node (rawNodeIds[1]) at placement
local bodyAnchorY    = 0.0       -- world Y of anchor node at placement
local spawnHeading   = 0.0       -- heading at placement; rotation is (currentHeading − spawnHeading)

-- Timing
local aiTickAccum    = 0.0       -- accumulates dt; AI tick fires at 1/aiTickHz
local stateTimer     = 0.0       -- time spent in current AI state
local walkTimer      = 0.0       -- time since last wander direction change
local idleTimer      = 0.0       -- remaining idle duration (s)
local stuckTimer     = 0.0       -- time below stuckSpeedMin

-- Movement
local walkOffsetX    = 0.0       -- accumulated XY displacement from spawn (X)
local walkOffsetY    = 0.0
local currentHeading = 0.0       -- actual smoothed heading (radians)
local desiredHeading = 0.0       -- target heading set by AI/steering
local currentSpeed   = 0.0       -- desired movement speed this frame (m/s)

-- State targets
local threatPos      = nil       -- vec3, flee source
local targetPos      = nil       -- vec3, pursue destination

-- Stuck detection — XY sampled each AI tick
local stuckPrevX     = 0.0
local stuckPrevY     = 0.0

-- Derived constant updated at init from config
local aiTickInterval = 1.0 / 15  -- seconds between AI ticks

-- Immutable physics/safety constants
local PLACED_DETECTION_SQ  = 2.0  * 2.0    -- m²  (2 m jump → world placement)
local IMPACT_THRESHOLD_SQ  = 0.06 * 0.06   -- m²  (6 cm XY → vehicle impact)
local TWO_PI               = 2 * math.pi
local REF_NODE_NAME        = "dummy1_thoraxtfl"

-- ─────────────────────────────────────────────────────────────────────────────
-- Internal helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function dbg(fmt, ...)
    if config.debugMode then
        local ok, msg = pcall(string.format, fmt, ...)
        if ok then
            log("D", "jonesingNpc", msg)
        end
    end
end

-- Wrap angle into [-π, π]
local function normalizeAngle(a)
    a = a % TWO_PI
    if a > math.pi then a = a - TWO_PI end
    return a
end

-- Safely get player vehicle world position (returns vec3 or nil)
local function getPlayerPos()
    local ok, result = pcall(function()
        local pv = be:getPlayerVehicle(0)
        if not pv then return nil end
        local p = pv:getPosition()
        return vec3(p.x, p.y, p.z)
    end)
    return (ok and result) or nil
end

-- Return the dummy's current world XY (reference/chest node via walk offset)
local function getDummyXY()
    if #allNodes > 0 then
        for _, rec in ipairs(allNodes) do
            if rec.cid == refCid then
                return rec.spawnX + walkOffsetX, rec.spawnY + walkOffsetY
            end
        end
        local rec = allNodes[1]
        return rec.spawnX + walkOffsetX, rec.spawnY + walkOffsetY
    end
    return 0, 0
end

-- Return the dummy's chest world Z
local function getDummyZ()
    for _, rec in ipairs(allNodes) do
        if rec.cid == refCid then return rec.spawnZ end
    end
    if #allNodes > 0 then return allNodes[1].spawnZ end
    return 0
end

-- Cast a single obstacle-detection ray against static world geometry.
-- Returns hit distance in (0, maxDist], or maxDist if clear / API unavailable.
-- The entire body (including Point3F construction) is wrapped in a closure so
-- that pcall catches any "attempt to call nil" if the API is unavailable.
local function castObstacleRay(ox, oy, oz, dx, dy, maxDist)
    local ok, result = pcall(function()
        return castRayStatic(
            Point3F(ox, oy, oz),
            Point3F(dx, dy, 0),
            maxDist
        )
    end)
    if ok and type(result) == "number" and result > 0 then
        return math.min(result, maxDist)
    end
    return maxDist
end

-- Cast a fan of 3 rays (forward, forward-left, forward-right) from the dummy's
-- chest position along the given heading.  Returns:
--   bestHeading (radians) — steered away from the nearest obstacle
--   clearDist   (m)       — clear distance along the best heading
-- Also logs per-ray distances when debugMode is on.
local function steerAroundObstacles(heading, rayLen)
    local cx, cy = getDummyXY()
    local cz     = getDummyZ() + 0.5   -- chest height offset above spawnZ

    local fAngle = heading
    local lAngle = heading + config.rayFanAngle
    local rAngle = heading - config.rayFanAngle

    local fDist = castObstacleRay(cx, cy, cz, math.sin(fAngle), math.cos(fAngle), rayLen)
    local lDist = castObstacleRay(cx, cy, cz, math.sin(lAngle), math.cos(lAngle), rayLen)
    local rDist = castObstacleRay(cx, cy, cz, math.sin(rAngle), math.cos(rAngle), rayLen)

    dbg("rays fwd=%.2f left=%.2f right=%.2f heading=%.1f°", fDist, lDist, rDist, math.deg(heading))

    -- If the forward ray is significantly blocked, steer toward the clearer side.
    local bestHeading = heading
    local clearDist   = fDist
    if fDist < rayLen * 0.7 then
        local avoidAngle = config.rayFanAngle * config.avoidanceWeight
        if lDist >= rDist then
            bestHeading = heading + avoidAngle
            clearDist   = lDist
        else
            bestHeading = heading - avoidAngle
            clearDist   = rDist
        end
        -- Both sides blocked: turn ~90° toward a random side
        if lDist < rayLen * 0.3 and rDist < rayLen * 0.3 then
            local flip = (math.random() > 0.5) and 1 or -1
            bestHeading = heading + flip * math.pi * 0.5
            clearDist   = 0.5
        end
    end

    return bestHeading, clearDist, lDist, fDist, rDist
end

-- ─────────────────────────────────────────────────────────────────────────────
-- AI state transitions
-- ─────────────────────────────────────────────────────────────────────────────

-- Internal transition: sets aiState + resets state-local timers.
-- params table is optional: { targetPos=vec3, threatPos=vec3, duration=number }
local function setAiStateInternal(newState, params)
    params     = params or {}
    aiState    = newState
    stateTimer = 0.0

    if newState == "wander" then
        dbg("→ WANDER")
    elseif newState == "idle" then
        local lo, hi = config.idleDurationMin, config.idleDurationMax
        idleTimer = params.duration or (lo + math.random() * (hi - lo))
        dbg("→ IDLE %.1fs", idleTimer)
    elseif newState == "flee" then
        if params.threatPos then threatPos = params.threatPos end
        dbg("→ FLEE threatPos=%s", tostring(threatPos ~= nil))
    elseif newState == "pursue" then
        if params.targetPos then targetPos = params.targetPos end
        dbg("→ PURSUE targetPos=%s", tostring(targetPos ~= nil))
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-state AI tick functions (called at aiTickHz, ~15 Hz)
-- ─────────────────────────────────────────────────────────────────────────────

local function tickWander(dt)
    currentSpeed = math.min(config.walkSpeed, config.maxWalkSpeed)

    walkTimer = walkTimer + dt
    if walkTimer >= config.wanderInterval then
        walkTimer = 0.0

        -- Random idle break
        if math.random() < config.idleChance then
            setAiStateInternal("idle")
            return
        end

        -- Sample candidate headings and pick the one with the farthest clear ray.
        local rayLen  = config.rayLenWalk
        local bestH   = desiredHeading
        local bestD   = -1
        local delta   = config.wanderAngleMax
        local candidates = {
            desiredHeading,
            desiredHeading + delta * (math.random() * 2 - 1),
            desiredHeading + delta * (math.random() * 2 - 1),
        }
        for _, h in ipairs(candidates) do
            local _, d = steerAroundObstacles(h, rayLen)
            if d > bestD then bestD = d; bestH = h end
        end
        desiredHeading = bestH + (math.random() * 2 - 1) * config.dirChangeMag
        dbg("WANDER new heading=%.1f° clearDist=%.2f", math.deg(desiredHeading), bestD)
    end

    -- Continuous mid-cycle avoidance: redirect if something ahead is close
    local steerH, clearD = steerAroundObstacles(currentHeading, config.rayLenWalk)
    if clearD < config.rayLenWalk * 0.5 then
        desiredHeading = steerH
    end
end

local function tickIdle(dt)
    currentSpeed = 0.0
    idleTimer    = idleTimer - dt
    if idleTimer <= 0 then
        setAiStateInternal("wander")
    end
end

local function tickFlee(dt)
    currentSpeed = math.min(config.fleeSpeed, config.maxWalkSpeed)
    stateTimer   = stateTimer + dt

    local cx, cy = getDummyXY()

    if threatPos then
        local dx   = cx - threatPos.x
        local dy   = cy - threatPos.y
        local dist = math.sqrt(dx * dx + dy * dy)

        -- Return to wander once safe or timed out
        if dist >= config.fleeSafeRadius or stateTimer >= config.fleeDurationMax then
            setAiStateInternal("wander")
            return
        end

        if dist > 0.5 then
            local fleeH         = math.atan2(dx, dy)
            local steerH, _     = steerAroundObstacles(fleeH, config.rayLenRun)
            desiredHeading      = steerH
        end
        dbg("FLEE dist=%.1f t=%.1f", dist, stateTimer)
    else
        -- No threat set: flee in current direction until timeout
        if stateTimer >= config.fleeDurationMax then
            setAiStateInternal("wander")
            return
        end
        local steerH, _ = steerAroundObstacles(currentHeading, config.rayLenRun)
        desiredHeading  = steerH
    end
end

local function tickPursue(dt)
    currentSpeed = math.min(config.pursueSpeed, config.maxWalkSpeed)
    stateTimer   = stateTimer + dt

    if not targetPos or stateTimer >= config.pursueDuration then
        setAiStateInternal("wander")
        return
    end

    local cx, cy = getDummyXY()
    local dx     = targetPos.x - cx
    local dy     = targetPos.y - cy
    local dist   = math.sqrt(dx * dx + dy * dy)

    if dist <= config.pursueArrivalR then
        dbg("PURSUE arrived")
        setAiStateInternal("wander")
        return
    end

    local pursueH       = math.atan2(dx, dy)
    local steerH, _     = steerAroundObstacles(pursueH, config.rayLenWalk)
    desiredHeading      = steerH
    dbg("PURSUE dist=%.2f heading=%.1f°", dist, math.deg(desiredHeading))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Stuck detection (runs each AI tick)
-- ─────────────────────────────────────────────────────────────────────────────
local function checkStuck(tickDt)
    if currentSpeed <= 0 then stuckTimer = 0.0; return end

    local cx, cy      = getDummyXY()
    local moved       = math.sqrt((cx - stuckPrevX)^2 + (cy - stuckPrevY)^2)
    local movedPerSec = moved / math.max(tickDt, 0.001)

    if movedPerSec < config.stuckSpeedMin then
        stuckTimer = stuckTimer + tickDt
        if stuckTimer >= config.stuckTime then
            desiredHeading = math.random() * TWO_PI
            stuckTimer     = 0.0
            dbg("STUCK → reseed heading=%.1f°", math.deg(desiredHeading))
        end
    else
        stuckTimer = 0.0
    end

    stuckPrevX = cx
    stuckPrevY = cy
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Combined AI tick dispatcher
-- ─────────────────────────────────────────────────────────────────────────────
local function runAiTick(tickDt)
    if     aiState == "wander"  then tickWander(tickDt)
    elseif aiState == "idle"    then tickIdle(tickDt)
    elseif aiState == "flee"    then tickFlee(tickDt)
    elseif aiState == "pursue"  then tickPursue(tickDt)
    end
    checkStuck(tickDt)
    dbg("state=%s heading=%.1f° speed=%.2f stuck=%.1f",
        aiState, math.deg(currentHeading), currentSpeed, stuckTimer)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- jbeam lifecycle callbacks
-- ─────────────────────────────────────────────────────────────────────────────

local function init(jbeamData)
    -- Apply jbeam-slot overrides to config (legacy param names mapped here)
    config.walkSpeed      = jbeamData.walkSpeed        or config.walkSpeed
    config.maxWalkSpeed   = jbeamData.maxWalkSpeed     or config.maxWalkSpeed
    config.runSpeed       = jbeamData.runSpeed         or config.runSpeed
    config.wanderInterval = jbeamData.walkChangePeriod or config.wanderInterval
    config.wanderInterval = jbeamData.wanderInterval   or config.wanderInterval
    config.sidewalkOffset = jbeamData.sidewalkOffset   or config.sidewalkOffset
    config.debugMode      = jbeamData.debugMode        or config.debugMode
    config.fleeSpeed      = jbeamData.fleeSpeed        or config.fleeSpeed
    config.pursueSpeed    = jbeamData.pursueSpeed      or config.pursueSpeed
    config.fleeSafeRadius = jbeamData.fleeSafeRadius   or config.fleeSafeRadius
    config.rayLenWalk     = jbeamData.rayLenWalk       or config.rayLenWalk
    config.rayLenRun      = jbeamData.rayLenRun        or config.rayLenRun
    config.rayFanAngle    = jbeamData.rayFanAngle      or config.rayFanAngle
    config.turnRateMax    = jbeamData.turnRateMax      or config.turnRateMax
    config.aiTickHz       = jbeamData.aiTickHz         or config.aiTickHz
    config.stuckTime      = jbeamData.stuckTime        or config.stuckTime
    config.idleChance     = jbeamData.idleChance       or config.idleChance

    aiTickInterval = 1.0 / config.aiTickHz

    -- Collect node cids — positions are NOT valid here (jbeam-local, near origin).
    rawNodeIds = {}
    allNodes   = {}
    refCid     = nil
    for _, n in pairs(v.data.nodes) do
        table.insert(rawNodeIds, n.cid)
        if n.name == REF_NODE_NAME then refCid = n.cid end
    end
    if not refCid and #rawNodeIds > 0 then refCid = rawNodeIds[1] end

    -- Capture jbeam-local relative offsets for upright-pose reconstruction.
    -- XY relative to rawNodeIds[1]; Z relative to LOWEST node (foot sole, dz >= 0).
    localOffsets = {}
    lowestCid    = nil
    if #rawNodeIds > 0 then
        local p0   = vec3(obj:getNodePosition(rawNodeIds[1]))
        local minZ = math.huge
        for _, cid in ipairs(rawNodeIds) do
            local p = vec3(obj:getNodePosition(cid))
            if p.z < minZ then minZ = p.z; lowestCid = cid end
        end
        for _, cid in ipairs(rawNodeIds) do
            local p = vec3(obj:getNodePosition(cid))
            table.insert(localOffsets, {
                cid = cid,
                dx  = p.x - p0.x,
                dy  = p.y - p0.y,
                dz  = p.z - minZ,
            })
        end
    end

    local seed = rawNodeIds[1] or 0
    math.randomseed(os.time() * 1000 + seed * 7919)

    -- Reset all mutable state
    walkOffsetX    = 0.0
    walkOffsetY    = 0.0
    currentHeading = math.random() * TWO_PI
    desiredHeading = currentHeading
    currentSpeed   = 0.0
    walkTimer      = 0.0
    aiTickAccum    = 0.0
    stateTimer     = 0.0
    stuckTimer     = 0.0
    idleTimer      = 0.0
    bodyAnchorX    = 0.0
    bodyAnchorY    = 0.0
    spawnHeading   = 0.0
    gracePrevX     = nil
    gracePrevY     = nil
    threatPos      = nil
    targetPos      = nil
    physState      = "grace"
    aiState        = "wander"
end


local function reset()
    allNodes    = {}
    walkOffsetX = 0.0
    walkOffsetY = 0.0
    walkTimer   = 0.0
    aiTickAccum = 0.0
    stateTimer  = 0.0
    stuckTimer  = 0.0
    bodyAnchorX = 0.0
    bodyAnchorY = 0.0
    spawnHeading = 0.0
    gracePrevX  = nil
    gracePrevY  = nil
    threatPos   = nil
    targetPos   = nil
    local seed = rawNodeIds[1] or 0
    math.randomseed(os.time() * 1000 + seed * 7919)
    currentHeading = math.random() * TWO_PI
    desiredHeading = currentHeading
    currentSpeed   = 0.0
    aiState        = "wander"
    physState      = "grace"
end


local function updateGFX(dt)
    if dt <= 0 then return end

    -- STANDING: all position overrides are OFF.
    if physState == "standing" then return end

    -- ── 1. Grace period: hold upright until traffic-script world placement ───────
    -- No timer.  The dummy stays upright indefinitely (by teleporting all nodes
    -- every frame) until the traffic script teleports the vehicle to its world
    -- position — detected as a sudden >2 m XY jump in one frame.  On detection
    -- we snapshot the settled positions and immediately start the AI walk.
    -- The ONLY other state transition from active→standing is a physical impact.
    if physState == "grace" then
        -- Detect sudden large XY jump → traffic-script placed vehicle at world pos.
        -- Snapshot and transition to active immediately (no countdown timer).
        if rawNodeIds[1] then
            local cp = vec3(obj:getNodePosition(rawNodeIds[1]))
            if gracePrevX ~= nil then
                local ddx = cp.x - gracePrevX
                local ddy = cp.y - gracePrevY
                if (ddx*ddx + ddy*ddy) > PLACED_DETECTION_SQ then
                    -- Vehicle placed — snapshot now and start walking.
                    allNodes = {}
                    local p0 = vec3(obj:getNodePosition(rawNodeIds[1]))

                    -- Road direction: player→dummy perpendicular → rotate 90° for walk direction.
                    -- Add ±90° random spread so dummies near the same spawn go different ways.
                    local pp = getPlayerPos()
                    if pp and (math.abs(pp.x - p0.x) > 1.0 or math.abs(pp.y - p0.y) > 1.0) then
                        local dx   = pp.x - p0.x
                        local dy   = pp.y - p0.y
                        local dist = math.sqrt(dx*dx + dy*dy)
                        if dist > 1.0 then
                            local nx = -dy / dist
                            local ny =  dx / dist
                            local baseH = math.atan2(nx, ny) + ((math.random() > 0.5) and math.pi or 0.0)
                            currentHeading = baseH + (math.random() - 0.5) * math.pi
                            desiredHeading = currentHeading
                            walkOffsetX    = (-dx / dist) * config.sidewalkOffset
                            walkOffsetY    = (-dy / dist) * config.sidewalkOffset
                        end
                    else
                        currentHeading = math.random() * TWO_PI
                        desiredHeading = currentHeading
                        local sideSign = (math.random() > 0.5) and 1.0 or -1.0
                        walkOffsetX    = math.cos(currentHeading) * config.sidewalkOffset * sideSign
                        walkOffsetY    = -math.sin(currentHeading) * config.sidewalkOffset * sideSign
                    end

                    -- Build allNodes from jbeam-local offsets + world anchor.
                    -- Store the anchor position and initial heading so the
                    -- rotation logic can rotate the body to face currentHeading.
                    bodyAnchorX  = p0.x
                    bodyAnchorY  = p0.y
                    spawnHeading = currentHeading
                    local terrainZ = lowestCid and obj:getNodePosition(lowestCid).z or p0.z
                    for _, off in ipairs(localOffsets) do
                        local nx = p0.x + off.dx
                        local ny = p0.y + off.dy
                        local nz = terrainZ + off.dz
                        table.insert(allNodes, { cid=off.cid, spawnX=nx, spawnY=ny, spawnZ=nz,
                                                 lastX=nx, lastY=ny })
                        obj:setNodePosition(off.cid, vec3(nx, ny, nz))
                    end

                    -- Initialise stuck-detection baseline.
                    stuckPrevX, stuckPrevY = getDummyXY()

                    physState = "active"
                    aiState   = "wander"
                    dbg("Placement detected → ACTIVE/WANDER")
                    return
                end
            end
            gracePrevX = cp.x
            gracePrevY = cp.y
        end

        -- No placement yet — hold every node in the upright pose this frame.
        if #localOffsets > 0 and rawNodeIds[1] then
            local p0g = vec3(obj:getNodePosition(rawNodeIds[1]))
            local tzg = lowestCid and obj:getNodePosition(lowestCid).z or p0g.z
            for _, off in ipairs(localOffsets) do
                obj:setNodePosition(off.cid, vec3(
                    p0g.x + off.dx,
                    p0g.y + off.dy,
                    tzg   + off.dz
                ))
            end
        end
        return
    end

    -- ── 2. Impact detection (all nodes, any XY displacement > threshold) ────────
    -- Compares each node's physics position against the position we teleported it
    -- to last frame (rec.lastX/lastY, which already includes body rotation).
    -- Any node displaced > 6 cm means something physical pushed it.
    -- On impact: read the player vehicle's velocity and apply it to every node
    -- with a height-based scale (upper body gets more velocity than the feet),
    -- creating a forward tumble. Then release to full physics ("standing").
    if #allNodes > 0 then
        local impactCid = nil
        for _, rec in ipairs(allNodes) do
            local cur = vec3(obj:getNodePosition(rec.cid))
            local ddx = cur.x - (rec.lastX or rec.spawnX)
            local ddy = cur.y - (rec.lastY or rec.spawnY)
            if (ddx*ddx + ddy*ddy) > IMPACT_THRESHOLD_SQ then
                impactCid = rec.cid
                break
            end
        end
        if impactCid then
            -- Derive impact velocity from the player vehicle (reliably non-zero
            -- and reflects the actual speed/direction of the collision).
            local ragdollOk = pcall(function()
                local pv = be:getPlayerVehicle(0)
                if not pv then return end
                local vel = pv:getVelocity()
                if not vel then return end
                local vx, vy, vz = vel.x, vel.y, vel.z
                -- Find body Z range for height-based scaling (upper body gets
                -- more velocity than the feet → creates a forward tumble).
                -- Scale range: 0.4× at feet → 1.6× at head; plus 2 m/s upward at head.
                local minZ, maxZ = math.huge, -math.huge
                for _, rec in ipairs(allNodes) do
                    if rec.spawnZ < minZ then minZ = rec.spawnZ end
                    if rec.spawnZ > maxZ then maxZ = rec.spawnZ end
                end
                local bodyH = math.max(maxZ - minZ, 0.1)
                for _, rec in ipairs(allNodes) do
                    local hf    = (rec.spawnZ - minZ) / bodyH  -- 0 = feet, 1 = head
                    local scale = 0.4 + hf * 1.2               -- 0.4× at feet, 1.6× at head
                    obj:setNodeVelocity(rec.cid, vec3(vx * scale, vy * scale, vz + hf * 2.0))
                end
            end)
            if not ragdollOk then
                dbg("ragdoll pcall failed — releasing to physics without velocity set")
            end
            physState = "standing"
            dbg("Impact → STANDING (ragdoll)")
            return
        end
    end

    -- ── 3. AI tick (rate-limited to aiTickHz) ─────────────────────────────────
    aiTickAccum = aiTickAccum + dt
    if aiTickAccum >= aiTickInterval then
        local tickDt = aiTickAccum
        aiTickAccum  = 0.0
        runAiTick(tickDt)
    end

    -- ── 4. Smooth heading rotation toward desiredHeading (every frame) ────────
    local headingErr = normalizeAngle(desiredHeading - currentHeading)
    local maxTurn    = config.turnRateMax * dt
    if math.abs(headingErr) <= maxTurn then
        currentHeading = desiredHeading
    else
        currentHeading = currentHeading + (headingErr > 0 and maxTurn or -maxTurn)
    end

    -- ── 5. Accumulate walk displacement ───────────────────────────────────────
    local speed = math.min(currentSpeed, config.maxWalkSpeed)
    walkOffsetX = walkOffsetX + math.sin(currentHeading) * speed * dt
    walkOffsetY = walkOffsetY + math.cos(currentHeading) * speed * dt

    -- ── 6. Teleport all nodes — rotate body to face currentHeading ──────────────
    -- Each node's body-local XY offset (relative to bodyAnchor at placement) is
    -- rotated by (currentHeading − spawnHeading) so the mesh turns as the dummy
    -- walks. The rotated position is stored in rec.lastX/lastY so impact detection
    -- knows exactly where each node was placed this frame.
    local angle = currentHeading - spawnHeading
    local cosA  = math.cos(angle)
    local sinA  = math.sin(angle)
    for _, rec in ipairs(allNodes) do
        -- Body-local offset at placement time
        local ldx = rec.spawnX - bodyAnchorX
        local ldy = rec.spawnY - bodyAnchorY
        -- Rotate offset by heading delta, then add anchor + walk translation
        local ex = bodyAnchorX + walkOffsetX + ldx * cosA - ldy * sinA
        local ey = bodyAnchorY + walkOffsetY + ldx * sinA + ldy * cosA
        local curZ = obj:getNodePosition(rec.cid).z
        if curZ > rec.spawnZ then rec.spawnZ = curZ end
        rec.lastX = ex
        rec.lastY = ey
        obj:setNodePosition(rec.cid, vec3(ex, ey, rec.spawnZ))
    end
end


-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

-- Set AI state externally.
-- newState: "wander" | "idle" | "flee" | "pursue"
-- params (optional): { targetPos=vec3, threatPos=vec3, duration=number }
M.setState = function(newState, params)
    if physState ~= "active" then return end
    setAiStateInternal(newState, params or {})
end

-- Enable or disable debug logging.
M.setDebug = function(enabled)
    config.debugMode = enabled
end

-- Return a descriptive state string:
--   "grace" | "active-wander" | "active-idle" | "active-flee" | "active-pursue" | "standing"
M.getState = function()
    if physState == "active" then
        return "active-" .. aiState
    end
    return physState
end

-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
