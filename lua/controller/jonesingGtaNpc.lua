-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingGtaNpc.lua
-- GTA-style NPC controller for the Jonesing dummy.
--
-- Two states (GHOST and STANDING):
--
--   GHOST    — After a 2-second physics-settling grace period, the dummy is
--              locked to a fixed world position and walks slowly along the road
--              by teleporting all nodes simultaneously (constant beam lengths,
--              no internal forces).  The dummy phases through everything.
--              Walk direction is aligned to the road (perpendicular of the
--              player→dummy spawn vector).
--              Spawn position is shifted sidewalkOffset metres RIGHT of the lane
--              direction (toward the kerb) so the dummy walks on the sidewalk.
--
--   STANDING — All position overrides stop.  The existing stabiliser beams hold
--              the dummy upright as a solid physics object.  A vehicle impact
--              will overwhelm the stabilisers and the dummy tumbles naturally.
--
-- GHOST → STANDING transition:
--   • After STARTUP_GRACE seconds the node baseline is snapshotted from the
--     fully-settled physics positions.  From that point, if the reference node
--     is displaced ≥ 3 cm in XY (horizontal) from the expected ghost position,
--     a vehicle has physically contacted the dummy → switch to STANDING.
--
-- IMPORTANT — why we wait before teleporting:
--   Traffic scripts call init() BEFORE placing the vehicle at its spawn world
--   position.  getNodePosition() at init() time returns jbeam-local coordinates
--   (near the world origin), not the final world location.  Teleporting to those
--   wrong coordinates creates enormous beam-spring forces that send the dummy
--   flying and exploding.  The grace period lets BeamNG move and settle the
--   vehicle at its real world position; we snapshot AFTER settling.
--
-- Controller params (set in the jbeam slot entry):
--   walkSpeed        (default 0.008 m/s) — very slow pedestrian shuffle in ghost mode
--   maxWalkSpeed     (default 2.235 m/s / 5 mph) — absolute cap, prevents runaway
--   walkChangePeriod (default 5.0 s)  — seconds between gentle road-parallel tweaks
--   sidewalkOffset   (default 5.0 m)  — lateral shift RIGHT of lane direction at spawn
--                                        (half-road-width offset; ~5 m puts dummy on kerb
--                                         for a typical 2×10 m lane layout)

local M = {}

-- ── internal state ────────────────────────────────────────────────────────────
local state              = "grace"   -- "grace", "ghost", or "standing"
local allNodes           = {}        -- {cid, spawnX, spawnY, spawnZ} — set after baseline
local walkOffsetX        = 0.0
local walkOffsetY        = 0.0
local walkDir            = 0.0
local walkTimer          = 0.0
local startupTimer       = 0.0
-- rawNodeIds: cid list stored during init() before baseline is captured.
-- (getNodePosition at init() returns wrong positions; we snapshot later.)
local rawNodeIds         = {}        -- list of cids for all nodes

-- configurable params
local walkSpeed          = 0.008    -- m/s  (very slow GTA pedestrian shuffle)
-- Hard speed cap: teleport delta per frame is clamped so physics velocity
-- never accumulates beyond this regardless of frame rate or walk speed setting.
-- 5 mph = 2.235 m/s
local maxWalkSpeed        = 2.235    -- m/s  (~5 mph)
local walkChangePeriod   = 5.0      -- s    (how often direction gently drifts)
local sidewalkOffset     = 5.0      -- m    (5 m RIGHT of lane direction = on kerb)

-- Direction change magnitude — tight so dummy stays road-parallel with only a
-- gentle drift over time.
local DIRECTION_CHANGE_MAX = math.pi / 36   -- ±5°
-- Impact detection threshold: only check XY (horizontal) displacement.
-- Terrain height changes push nodes vertically (Z) — checking Z causes false
-- triggers on any slope or bump.  Real vehicle/wall impacts displace nodes
-- laterally (XY) by ≥ 3 cm; terrain slope only affects Z.
-- Normal ghost-walking XY residual drift ≈ 1 mm (30× safety margin).
local IMPACT_THRESHOLD_SQ  = 0.03 * 0.03   -- metres²  (3 cm in XY only)
-- Grace period after spawn before the impact check is enabled.
-- Traffic-script spawning runs physics-settling for ~1 s after init();
-- during this time nodes can move > 3 cm in XY purely from spring/damper
-- settling, which would otherwise false-trigger the STANDING transition.
local STARTUP_GRACE        = 2.0             -- seconds


-- ── helpers ───────────────────────────────────────────────────────────────────

-- Safely get the player vehicle's world position (returns vec3 or nil).
-- Used during init() to compute road direction and sidewalk offset.
local function getPlayerPos()
    local ok, result = pcall(function()
        local pv = be:getPlayerVehicle(0)
        if not pv then return nil end
        local p = pv:getPosition()
        return vec3(p.x, p.y, p.z)
    end)
    return (ok and result) or nil
end


-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────

local function init(jbeamData)
    walkSpeed        = jbeamData.walkSpeed        or walkSpeed
    maxWalkSpeed     = jbeamData.maxWalkSpeed      or maxWalkSpeed
    walkChangePeriod = jbeamData.walkChangePeriod or walkChangePeriod
    sidewalkOffset   = jbeamData.sidewalkOffset   or sidewalkOffset

    -- Collect all node cids — we do NOT snapshot positions here.
    -- Traffic scripts call init() before placing the vehicle at its world
    -- position, so getNodePosition() returns jbeam-local coords (near origin)
    -- which are completely wrong.  We snapshot after STARTUP_GRACE seconds.
    rawNodeIds = {}
    allNodes   = {}
    for _, n in pairs(v.data.nodes) do
        table.insert(rawNodeIds, n.cid)
    end

    -- Per-instance random seed (unique per vehicle object)
    local seed = rawNodeIds[1] or 0
    math.randomseed(os.time() + seed)

    -- Reset accumulators and startup grace timer
    walkOffsetX  = 0
    walkOffsetY  = 0
    walkTimer    = 0
    startupTimer = 0

    -- Compute walk direction from player→dummy heuristic.
    -- We still use getNodePosition here to get a rough spawn position for the
    -- road-direction heuristic; the inaccuracy at init() only affects walk
    -- direction (not the baseline Z used for teleportation, which is snapshotted
    -- after physics settles).
    local pp = getPlayerPos()
    if pp and rawNodeIds[1] then
        local p0 = vec3(obj:getNodePosition(rawNodeIds[1]))
        local dx = pp.x - p0.x
        local dy = pp.y - p0.y
        local perpDist = math.sqrt(dx*dx + dy*dy)

        if perpDist > 1.0 then
            -- Road-parallel direction = 90° rotation of (dx, dy)
            local nx = -dy / perpDist
            local ny =  dx / perpDist
            walkDir = math.atan2(nx, ny)
            -- 50/50 chance of walking toward or away from player's heading
            local flip = (math.random() > 0.5) and math.pi or 0.0
            walkDir = walkDir + flip

            -- Sidewalk offset: always shift RIGHT of the walk direction.
            -- Forward vector = (sin(walkDir), cos(walkDir))
            -- Right perpendicular (90° clockwise) = (cos(walkDir), -sin(walkDir))
            local rightX = math.cos(walkDir)
            local rightY = -math.sin(walkDir)
            walkOffsetX = rightX * sidewalkOffset
            walkOffsetY = rightY * sidewalkOffset
        else
            walkDir = math.random() * 2 * math.pi
        end
    else
        walkDir = math.random() * 2 * math.pi
    end

    state = "grace"
end


local function reset()
    allNodes     = {}
    walkOffsetX  = 0
    walkOffsetY  = 0
    walkTimer    = 0
    startupTimer = 0
    local seed = rawNodeIds[1] or 0
    math.randomseed(os.time() + seed)
    walkDir = math.random() * 2 * math.pi
    state = "grace"
end


local function updateGFX(dt)
    if dt <= 0 then return end

    -- STANDING state: all position overrides are OFF.
    if state == "standing" then return end

    -- ── 1. Grace period: physics settles, we do NOTHING ──────────────────────
    -- Traffic scripts place the vehicle AFTER init().  getNodePosition() at
    -- init() time returns jbeam-local coords that are wrong for world space.
    -- If we teleport during this window we create enormous beam spring forces
    -- (nodes snapped to pre-placement positions) → dummy flies up → explodes.
    -- Solution: do absolutely nothing for STARTUP_GRACE seconds, then snapshot
    -- the real world positions as our baseline.
    if state == "grace" then
        startupTimer = startupTimer + dt
        if startupTimer >= STARTUP_GRACE then
            -- Snapshot settled positions — these are correct world coords now
            allNodes = {}
            for _, cid in ipairs(rawNodeIds) do
                local p = vec3(obj:getNodePosition(cid))
                table.insert(allNodes, {
                    cid    = cid,
                    spawnX = p.x - walkOffsetX,   -- bake sidewalk offset in
                    spawnY = p.y - walkOffsetY,
                    spawnZ = p.z,
                })
            end
            state = "ghost"
        end
        return  -- no teleportation until baseline is captured
    end

    -- ── 2. Impact detection (XY only, post-grace) ────────────────────────────
    if #allNodes > 0 then
        local ref = allNodes[1]
        local cur = vec3(obj:getNodePosition(ref.cid))
        local expX = ref.spawnX + walkOffsetX
        local expY = ref.spawnY + walkOffsetY
        local ddx = cur.x - expX
        local ddy = cur.y - expY
        if (ddx*ddx + ddy*ddy) > IMPACT_THRESHOLD_SQ then
            state = "standing"
            return
        end
    end

    -- ── 3. Periodically tweak walk direction (gentle, ±5°, road-parallel) ─────
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
