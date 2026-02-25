-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingGtaNpc.lua
-- GTA-style NPC controller for the Jonesing dummy.
--
-- Two states (GHOST and STANDING):
--
--   GHOST    — Immediately upon traffic-script vehicle placement (detected as a
--              sudden > 2 m jump in one frame), all nodes are snapped to their
--              jbeam-local upright pose at the correct world position and locked
--              there.  The dummy walks slowly along the road by teleporting all
--              nodes simultaneously (constant beam lengths, no internal forces),
--              phasing through everything.
--              Walk direction is aligned to the road (perpendicular of the
--              player→dummy spawn vector, computed after physics settles).
--              Z tracking: each frame Z is allowed to INCREASE (uphill terrain)
--              but never decrease, preventing gravity-induced sinking.
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
--   flying and exploding.  The controller detects the traffic-script placement
--   teleport (a sudden > 2 m position jump in one frame) and immediately locks
--   the dummy in place so it never visibly falls.  A fixed STARTUP_GRACE timeout
--   acts as a fallback for edge cases where the jump is not detected.
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
--   sidewalkOffset   (default 0.0 m)  — lateral shift RIGHT of lane direction at spawn (0 = walk from spawn position)

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
-- localOffsets: XY relative to rawNodeIds[1], Z relative to the LOWEST jbeam node
-- (foot level), captured in jbeam-local space at init() time.  dz is always >= 0
-- (feet dz≈0, head dz≈1.8 m).  This ensures reconstruction never places any node
-- below the terrain surface regardless of which node is rawNodeIds[1].
local localOffsets       = {}        -- {cid, dx, dy, dz}
-- lowestCid: the node with the minimum jbeam Z (foot/sole node).  Used as terrain
-- Z reference at ghost-mode entry so reconstruction always starts from road level.
local lowestCid          = nil
-- Track node position each grace frame to detect when the traffic script
-- teleports the vehicle to its world position (sudden large jump).
local gracePrevX         = nil
local gracePrevY         = nil

-- configurable params
local walkSpeed          = 0.008    -- m/s  (very slow GTA pedestrian shuffle)
-- Hard speed cap: teleport delta per frame is clamped so physics velocity
-- never accumulates beyond this regardless of frame rate or walk speed setting.
-- 5 mph = 2.235 m/s
local maxWalkSpeed        = 2.235    -- m/s  (~5 mph)
local walkChangePeriod   = 5.0      -- s    (how often direction gently drifts)
local sidewalkOffset     = 0.0      -- m    (0 = walk from spawn position, no sidewalk shift)

-- Threshold for detecting that the traffic script has teleported the vehicle to
-- its real world position: if a node jumps more than this distance in one frame
-- during the grace period we treat the vehicle as placed and snapshot immediately.
local PLACED_DETECTION_SQ  = 2.0 * 2.0  -- metres²  (2 m jump)

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

    -- Record jbeam-local relative positions for upright pose reconstruction.
    -- XY offsets are relative to rawNodeIds[1] (arbitrary anchor).
    -- Z offsets are relative to the LOWEST node's Z (foot/sole level) so that
    -- dz is always >= 0.  This prevents feet from being placed below terrain when
    -- rawNodeIds[1] is a mid-body node whose jbeam Z > 0.
    localOffsets = {}
    lowestCid    = nil
    if #rawNodeIds > 0 then
        -- Pass 1: find minimum jbeam Z (foot level) and XY anchor.
        local p0      = vec3(obj:getNodePosition(rawNodeIds[1]))
        local minZ    = math.huge
        for _, cid in ipairs(rawNodeIds) do
            local p = vec3(obj:getNodePosition(cid))
            if p.z < minZ then
                minZ      = p.z
                lowestCid = cid
            end
        end
        -- Pass 2: record offsets (dz = height above foot level, always >= 0).
        for _, cid in ipairs(rawNodeIds) do
            local p = vec3(obj:getNodePosition(cid))
            table.insert(localOffsets, {
                cid = cid,
                dx  = p.x - p0.x,
                dy  = p.y - p0.y,
                dz  = p.z - minZ,   -- height above foot sole (>= 0)
            })
        end
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
    gracePrevX   = nil
    gracePrevY   = nil

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
    gracePrevX   = nil
    gracePrevY   = nil
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
    -- Solution: wait until the traffic script teleports the vehicle to its world
    -- position (detected as a sudden > 2 m jump in one frame), then snapshot
    -- the real world positions immediately.  If no teleport is detected within
    -- STARTUP_GRACE seconds, fall back to the original snapshot-at-timeout path.
    if state == "grace" then
        startupTimer = startupTimer + dt

        -- Detect traffic-script vehicle placement: the script teleports the vehicle
        -- to its real world position in one frame, causing a sudden large position
        -- jump.  As soon as we see that, skip remaining grace time and snapshot now
        -- so the dummy locks in place immediately and never visibly falls over.
        if rawNodeIds[1] then
            local cp = vec3(obj:getNodePosition(rawNodeIds[1]))
            if gracePrevX ~= nil then
                local ddx = cp.x - gracePrevX
                local ddy = cp.y - gracePrevY
                if (ddx*ddx + ddy*ddy) > PLACED_DETECTION_SQ then
                    -- Vehicle just teleported to world position — force transition now.
                    startupTimer = STARTUP_GRACE
                end
            end
            gracePrevX = cp.x
            gracePrevY = cp.y
        end

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

            -- Reconstruct the upright body pose.
            -- XY: use rawNodeIds[1] world XY as the horizontal anchor.
            -- Z:  use the lowest (foot) node's current world Z as terrain reference,
            --     then add each node's jbeam height-above-feet (off.dz >= 0).
            --     This ensures NO node is placed below the road surface regardless
            --     of which node rawNodeIds[1] is or how the dummy has fallen.
            local terrainZ = lowestCid and obj:getNodePosition(lowestCid).z or p0.z
            for _, off in ipairs(localOffsets) do
                local nx = p0.x + off.dx
                local ny = p0.y + off.dy
                local nz = terrainZ + off.dz
                table.insert(allNodes, {
                    cid    = off.cid,
                    spawnX = nx,
                    spawnY = ny,
                    spawnZ = nz,
                })
                obj:setNodePosition(off.cid, vec3(nx, ny, nz))
            end
            -- Initialize lastRefX/Y from the RECONSTRUCTED position so the first-
            -- frame impact check has zero displacement and doesn't immediately
            -- trigger a spurious "standing" transition.
            if refCid then
                for _, off in ipairs(localOffsets) do
                    if off.cid == refCid then
                        lastRefX = p0.x + off.dx
                        lastRefY = p0.y + off.dy
                        break
                    end
                end
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
    --  Z tracking: read current physics Z.  We only allow Z to INCREASE so the
    --  dummy follows uphill terrain.  We never decrease spawnZ, because gravity
    --  pulls nodes ~1 mm downward between each setNodePosition call; updating
    --  downward would accumulate into the "sinking / sliding on ground" behaviour.
    for _, rec in ipairs(allNodes) do
        local curZ = obj:getNodePosition(rec.cid).z
        -- Uphill terrain following: allow Z to rise, never sink.
        if curZ > rec.spawnZ then
            rec.spawnZ = curZ
        end
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
