-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingGtaNpc.lua
-- GTA-style NPC controller for the Jonesing dummy.
--
-- Two states (GHOST and RAGDOLL):
--   GHOST   — The dummy floats at spawn height and drifts slowly forward,
--             phasing through everything.  Implemented via setNodePosition.
--             Every frame, the reference node's current position is compared
--             to where we set it last frame.  Normal walking drift is ~1 mm;
--             any collision (wall, car, pole) pushes it ≥ IMPACT_THRESHOLD
--             → immediately switches to RAGDOLL.
--             Also switches to RAGDOLL when the player vehicle comes within
--             effectiveProxRadius (= spawnDist × 0.25).
--
--   RAGDOLL — All position overrides stop.  Full BeamNG physics take over.
--             The existing stabiliser beams provide a gentle upright tendency
--             but will be overwhelmed by a real vehicle impact so the dummy
--             tumbles and falls naturally.
--
-- Controller params (set in the jbeam controller entry):
--   walkSpeed        (default 0.03 m/s) — slow pedestrian pace in ghost mode
--   maxWalkSpeed     (default 2.235 m/s / 5 mph) — absolute cap, prevents runaway
--   walkChangePeriod (default 5.0 s)  — seconds between gentle direction tweaks
--   proximityRadius  (default 20 m)   — fallback radius if spawn distance can't
--                                       be measured; actual radius = spawnDist×0.25

local M = {}

-- ── internal state ────────────────────────────────────────────────────────────
local state              = "ghost"
local allNodes           = {}        -- {cid, spawnX, spawnY, spawnZ}
local walkOffsetX        = 0.0
local walkOffsetY        = 0.0
local walkDir            = 0.0
local walkTimer          = 0.0
local effectiveProxRadius = 20.0    -- computed at init from spawnDist × 0.25

-- configurable params
local walkSpeed          = 0.03     -- m/s  (slow GTA pedestrian pace)
-- Hard speed cap: teleport delta per frame is clamped so physics velocity
-- never accumulates beyond this regardless of frame rate or walk speed setting.
-- 5 mph = 2.235 m/s
local maxWalkSpeed        = 2.235    -- m/s  (~5 mph)
local walkChangePeriod   = 5.0      -- s    (how often direction gently drifts)
local proximityRadius    = 20.0     -- m    (fallback if spawn dist unavailable)

-- Direction change magnitude — small so each dummy walks in a consistent line
-- and doesn't zigzag across the road.
local DIRECTION_CHANGE_MAX = math.pi / 18   -- ±10°
-- Minimum effective proximity radius regardless of spawn distance
local MIN_PROXIMITY_RADIUS = 6.0            -- metres
-- Impact detection threshold: normal walking drift ≈ 1 mm; anything larger
-- than IMPACT_THRESHOLD (3 cm) means a wall or vehicle physically displaced a node.
local IMPACT_THRESHOLD_SQ  = 0.03 * 0.03   -- metres²  (3 cm)


-- ── helpers ───────────────────────────────────────────────────────────────────

-- Safely get the player vehicle's world position (returns vec3 or nil).
local function getPlayerPos()
    local ok, result = pcall(function()
        local pv = be:getPlayerVehicle(0)
        if not pv then return nil end
        local p = pv:getPosition()
        return vec3(p.x, p.y, p.z)
    end)
    return (ok and result) or nil
end

-- World position of the dummy's walk origin (spawn centre + accumulated offset).
local function getDummyWorldPos()
    if #allNodes == 0 then return nil end
    local r = allNodes[1]
    return vec3(r.spawnX + walkOffsetX, r.spawnY + walkOffsetY, r.spawnZ)
end


-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────

local function init(jbeamData)
    walkSpeed        = jbeamData.walkSpeed        or walkSpeed
    maxWalkSpeed     = jbeamData.maxWalkSpeed      or maxWalkSpeed
    walkChangePeriod = jbeamData.walkChangePeriod or walkChangePeriod
    proximityRadius  = jbeamData.proximityRadius  or proximityRadius

    -- Record spawn position for every node
    allNodes = {}
    for _, n in pairs(v.data.nodes) do
        local p = vec3(obj:getNodePosition(n.cid))
        table.insert(allNodes, {
            cid    = n.cid,
            spawnX = p.x,
            spawnY = p.y,
            spawnZ = p.z,
        })
    end

    -- Per-instance random seed (unique per vehicle object)
    local seed = 0
    if allNodes[1] then seed = allNodes[1].cid end
    math.randomseed(os.time() + seed)

    -- Walk direction: fully random start, but small perturbations keep it
    -- consistent so the dummy doesn't zigzag sideways across the road.
    walkDir = math.random() * 2 * math.pi

    walkOffsetX = 0
    walkOffsetY = 0
    walkTimer   = 0

    -- Compute effective proximity radius = 1/4 of the distance to the player
    -- at spawn time.  Fall back to jbeam proximityRadius if player is unavailable.
    local pp = getPlayerPos()
    if pp and #allNodes > 0 then
        local r = allNodes[1]
        local dx = pp.x - r.spawnX
        local dy = pp.y - r.spawnY
        local dz = pp.z - r.spawnZ
        local spawnDist = math.sqrt(dx*dx + dy*dy + dz*dz)
        effectiveProxRadius = math.max(spawnDist * 0.25, MIN_PROXIMITY_RADIUS)
    else
        effectiveProxRadius = proximityRadius
    end

    state = "ghost"
end


local function reset()
    for _, rec in ipairs(allNodes) do
        local p = vec3(obj:getNodePosition(rec.cid))
        rec.spawnX = p.x
        rec.spawnY = p.y
        rec.spawnZ = p.z
    end
    walkOffsetX = 0
    walkOffsetY = 0
    walkTimer   = 0
    local seed = 0
    if allNodes[1] then seed = allNodes[1].cid end
    math.randomseed(os.time() + seed)
    walkDir = math.random() * 2 * math.pi

    -- Recalculate effective proximity radius from new spawn positions
    local pp = getPlayerPos()
    if pp and allNodes[1] then
        local r = allNodes[1]
        local dx = pp.x - r.spawnX
        local dy = pp.y - r.spawnY
        local dz = pp.z - r.spawnZ
        local spawnDist = math.sqrt(dx*dx + dy*dy + dz*dz)
        effectiveProxRadius = math.max(spawnDist * 0.25, MIN_PROXIMITY_RADIUS)
    end

    state = "ghost"
end


local function updateGFX(dt)
    if dt <= 0 then return end

    -- RAGDOLL state: all position overrides are OFF.
    -- Full BeamNG physics (stabilisers + collision) handles everything.
    if state == "ragdoll" then return end

    -- ── 1. Impact detection ───────────────────────────────────────────────────
    -- Compare where physics currently has the reference node vs. where we put it
    -- last frame (spawnXY + accumulated walk offset, same Z we always set).
    -- Normal walking residual drift ≈ 1 mm.  A wall or vehicle contact pushes the
    -- node far more (≥ 3 cm) → trigger ragdoll immediately so the dummy reacts to
    -- the collision instead of teleporting through it.
    if #allNodes > 0 then
        local ref = allNodes[1]
        local cur = vec3(obj:getNodePosition(ref.cid))
        local expX = ref.spawnX + walkOffsetX
        local expY = ref.spawnY + walkOffsetY
        local expZ = ref.spawnZ
        local ddx = cur.x - expX
        local ddy = cur.y - expY
        local ddz = cur.z - expZ
        if (ddx*ddx + ddy*ddy + ddz*ddz) > IMPACT_THRESHOLD_SQ then
            state = "ragdoll"
            return
        end
    end

    -- ── 2. Player proximity check ─────────────────────────────────────────────
    -- When the player drives close, stop ghost mode so the dummy can be hit
    -- naturally.
    local myPos = getDummyWorldPos()
    if myPos then
        local pp = getPlayerPos()
        if pp then
            local dx = pp.x - myPos.x
            local dy = pp.y - myPos.y
            local dz = pp.z - myPos.z
            if (dx*dx + dy*dy + dz*dz) < (effectiveProxRadius * effectiveProxRadius) then
                state = "ragdoll"
                return
            end
        end
    end

    -- ── 3. Periodically tweak walk direction (gentle, ±10°) ──────────────────
    walkTimer = walkTimer + dt
    if walkTimer >= walkChangePeriod then
        walkTimer = 0
        walkDir = walkDir + (math.random() - 0.5) * 2 * DIRECTION_CHANGE_MAX
    end

    -- ── 4. Accumulate horizontal walk displacement ────────────────────────────
    local effectiveSpeed = math.min(walkSpeed, maxWalkSpeed)
    local stepX = math.sin(walkDir) * effectiveSpeed * dt
    local stepY = math.cos(walkDir) * effectiveSpeed * dt
    walkOffsetX = walkOffsetX + stepX
    walkOffsetY = walkOffsetY + stepY

    -- ── 5. Teleport every node to its desired ghost position ─────────────────
    --  Moving ALL nodes by the same XY offset keeps every beam length constant
    --  → no spurious internal forces or vibration.  Z is fixed (anti-gravity).
    for _, rec in ipairs(allNodes) do
        obj:setNodePosition(rec.cid, vec3(
            rec.spawnX + walkOffsetX,
            rec.spawnY + walkOffsetY,
            rec.spawnZ
        ))
    end
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
