-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingGtaNpc.lua
-- GTA-style NPC controller for the Jonesing dummy.
--
-- Two states (GHOST and STANDING):
--
--   GHOST    — After a 3.5-second physics-settling grace period, the dummy is
--              locked to a fixed world position and walks slowly along the road
--              by teleporting all nodes simultaneously (constant beam lengths,
--              no internal forces).  The dummy phases through everything.
--              Walk direction is aligned to the road (perpendicular of the
--              player→dummy spawn vector, computed after physics settles).
--              Spawn position is shifted sidewalkOffset metres RIGHT of the lane
--              direction (toward the kerb) so the dummy walks on the sidewalk.
--              Z tracking: each frame the settled physics Z is read back and
--              stored so the dummy follows terrain height automatically.
--
--   STANDING — All position overrides stop.  The existing stabiliser beams hold
--              the dummy upright as a solid physics object.  A vehicle impact
--              will overwhelm the stabilisers and the dummy tumbles naturally.
--
-- GHOST → STANDING transition trigger (chest/thorax reference node):
--   XY displacement ≥ 6 cm in a single frame  → vehicle/wall physically hit it
--
-- IMPORTANT — why we wait before teleporting:
--   Traffic scripts call init() BEFORE placing the vehicle at its spawn world
--   position.  getNodePosition() at init() time returns jbeam-local coordinates
--   (near the world origin), not the final world location.  Teleporting to those
--   wrong coordinates creates enormous beam-spring forces that send the dummy
--   flying and exploding.  The grace period lets BeamNG move and settle the
--   vehicle at its real world position; we snapshot AFTER settling.
--
-- Reference node: "dummy1_thoraxtfl" (top-left chest node, ~1.45 m above ground).
--   Using a high chest node as reference avoids false triggers from foot/ground
--   contact and is far enough from the ground that a ≥8 cm XY displacement is
--   only caused by a vehicle or wall impact (not terrain).
--
-- Controller params (set in the jbeam slot entry):
--   walkSpeed        (default 0.008 m/s) — very slow pedestrian shuffle in ghost mode
--   maxWalkSpeed     (default 2.235 m/s / 5 mph) — absolute cap, prevents runaway
--   walkChangePeriod (default 5.0 s)  — seconds between gentle road-parallel tweaks
--   sidewalkOffset   (default 5.0 m)  — lateral shift RIGHT of lane direction at spawn

local M = {}

-- ── internal state ────────────────────────────────────────────────────────────
local state              = "grace"   -- "grace", "ghost", or "standing"
local allNodes           = {}        -- {cid, spawnX, spawnY, spawnZ} — set after baseline
local refCid             = nil       -- cid of "dummy1_thoraxtfl" (chest reference node)
local lastRefX           = 0.0      -- where we LAST teleported the reference node (X)
local lastRefY           = 0.0      -- where we LAST teleported the reference node (Y)
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

-- Impact detection — checked on the named chest node "dummy1_thoraxtfl"
-- (~1.45 m above ground) to avoid false positives from foot/terrain contact.
--
-- XY threshold: 6 cm.  A car hit displaces the chest node ≥ 5-8 cm per frame;
-- normal walking residual drift ≈ 1 mm.  Z is excluded — terrain height changes
-- only produce vertical displacement; XY-only check avoids false triggers.
local IMPACT_THRESHOLD_SQ  = 0.06 * 0.06   -- metres²  (6 cm in XY)

-- Grace period after spawn before the impact check is enabled.
-- Traffic-script spawning runs physics-settling for ~2 s after init();
-- 3.5 s provides comfortable margin for all map/PC speeds.
local STARTUP_GRACE        = 3.5             -- seconds

-- Name of the reference body node (chest, ~1.45 m above ground).
-- Using a high thorax node avoids false-positive falls from foot/ground contact.
local REF_NODE_NAME        = "dummy1_thoraxtfl"


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
    refCid     = nil
    for _, n in pairs(v.data.nodes) do
        table.insert(rawNodeIds, n.cid)
        -- Find the named chest reference node for impact/fall detection
        if n.name == REF_NODE_NAME then
            refCid = n.cid
        end
    end
    -- Fallback: if named node not found, use the first node (same as before)
    if not refCid and #rawNodeIds > 0 then
        refCid = rawNodeIds[1]
    end

    -- Per-instance random seed (unique per vehicle object)
    local seed = rawNodeIds[1] or 0
    math.randomseed(os.time() + seed)

    -- Reset accumulators and startup grace timer.
    -- walkDir, walkOffsetX, walkOffsetY are computed at grace END (world coords).
    walkOffsetX  = 0
    walkOffsetY  = 0
    walkDir      = 0
    walkTimer    = 0
    startupTimer = 0

    state = "grace"
end


local function reset()
    allNodes     = {}
    walkOffsetX  = 0
    walkOffsetY  = 0
    walkTimer    = 0
    startupTimer = 0
    lastRefX     = 0
    lastRefY     = 0
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
            -- Snapshot settled positions — these are correct world coords now.
            -- Also compute walk direction and sidewalk offset using REAL world
            -- positions (not the jbeam-local coords available at init() time).
            allNodes = {}
            local p0 = vec3(obj:getNodePosition(rawNodeIds[1]))

            -- Road direction: player→dummy vector is road-perpendicular;
            -- rotate 90° to get road-parallel walk direction.
            local pp = getPlayerPos()
            if pp and (math.abs(pp.x - p0.x) > 1.0 or math.abs(pp.y - p0.y) > 1.0) then
                local dx = pp.x - p0.x
                local dy = pp.y - p0.y
                local perpDist = math.sqrt(dx*dx + dy*dy)
                if perpDist > 1.0 then
                    local nx = -dy / perpDist
                    local ny =  dx / perpDist
                    walkDir = math.atan2(nx, ny)
                    local flip = (math.random() > 0.5) and math.pi or 0.0
                    walkDir = walkDir + flip

                    -- Sidewalk offset: shift the dummy AWAY from the player.
                    -- The player is typically near the road centreline, so
                    -- p0→pp (dummy-to-player direction) = toward road centre.
                    -- Negate to get "away from road" = toward the kerb/sidewalk.
                    walkOffsetX = (-dx / perpDist) * sidewalkOffset
                    walkOffsetY = (-dy / perpDist) * sidewalkOffset
                end
            else
                -- Fallback: player is too close to the dummy to compute road direction.
                -- Pick a random walk direction and apply the sidewalk offset perpendicular to it.
                walkDir = math.random() * 2 * math.pi
                local sideSign = (math.random() > 0.5) and 1.0 or -1.0
                walkOffsetX = math.cos(walkDir) * sidewalkOffset * sideSign
                walkOffsetY = -math.sin(walkDir) * sidewalkOffset * sideSign
            end

            for _, cid in ipairs(rawNodeIds) do
                local p = vec3(obj:getNodePosition(cid))
                table.insert(allNodes, {
                    cid    = cid,
                    spawnX = p.x,   -- baseline at lane centre; walkOffsetX adds sidewalk shift
                    spawnY = p.y,
                    spawnZ = p.z,   -- true settled Z
                })
            end
            -- Initialize lastRefX/Y to CURRENT position (before any sidewalk
            -- teleport) so the first-frame impact check has zero displacement.
            if refCid then
                local rp = vec3(obj:getNodePosition(refCid))
                lastRefX  = rp.x
                lastRefY  = rp.y
            end
            state = "ghost"
        end
        return  -- no teleportation until baseline is captured
    end

    -- ── 2. Impact detection (post-grace, chest reference node) ──────────────────
    -- Uses "dummy1_thoraxtfl" (top-left chest, ~1.45 m above ground) as reference.
    --
    -- The check compares the current node position against WHERE WE PLACED IT last
    -- frame (lastRefX/Y), NOT against the mathematical expected position.  This
    -- prevents false triggers on the first ghost frame (when walkOffsetX already
    -- holds the 5 m sidewalk shift but the nodes haven't been teleported yet —
    -- that would look like a 5 m displacement and immediately trigger "standing").
    --
    --   • XY displacement ≥ 4 cm since last teleport  → something hit the dummy
    --
    if refCid and #allNodes > 0 then
        local cur = vec3(obj:getNodePosition(refCid))
        local ddx = cur.x - lastRefX
        local ddy = cur.y - lastRefY
        -- XY position displacement check (slow/medium speed vehicle contact)
        if (ddx*ddx + ddy*ddy) > IMPACT_THRESHOLD_SQ then
            state = "standing"
            -- ── Trigger impact particle effects ─────────────────────────────
            -- Estimate impact speed from the XY displacement magnitude.
            -- displacement is in metres/frame; divide by dt to get approx m/s.
            local dispMag   = math.sqrt(ddx*ddx + ddy*ddy)
            local impactMs  = dispMag / math.max(dt, 0.001)
            -- Map 0-20 m/s to intensity 0.2-2.0 (clamped).
            local intensity = math.max(0.2, math.min(impactMs / 10.0, 2.0))
            -- Use the current chest-node position as the spawn point.
            local cx = cur.x
            local cy = cur.y
            local cz = cur.z
            -- Queue into the Game Engine Lua context where the GE extension lives.
            obj:queueGameEngineLua(string.format(
                'if extensions.jonesing_impactParticles then ' ..
                '  extensions.jonesing_impactParticles.spawnImpactParticles(' ..
                '    %f,%f,%f, 0,0,1, %f,"impact_blood_spray",nil);' ..
                '  extensions.jonesing_impactParticles.spawnImpactParticles(' ..
                '    %f,%f,%f, 0,0,1, %f,"impact_dust_puff",nil);' ..
                'end',
                cx, cy, cz, intensity,
                cx, cy, cz, intensity * 0.7
            ))
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
    --  → no spurious internal forces or vibration.
    --  Z tracking: read current physics Z before teleporting — this follows terrain
    --  height so feet never clip into slopes at the sidewalk offset location.
    for _, rec in ipairs(allNodes) do
        local curZ = obj:getNodePosition(rec.cid)
        rec.spawnZ = curZ.z  -- track settled physics terrain height
        obj:setNodePosition(rec.cid, vec3(
            rec.spawnX + walkOffsetX,
            rec.spawnY + walkOffsetY,
            rec.spawnZ
        ))
    end

    -- Update the reference position for next frame's impact check.
    -- This is where we ACTUALLY placed the ref node this frame.
    if refCid then
        for _, rec in ipairs(allNodes) do
            if rec.cid == refCid then
                lastRefX = rec.spawnX + walkOffsetX
                lastRefY = rec.spawnY + walkOffsetY
                break
            end
        end
    end
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
