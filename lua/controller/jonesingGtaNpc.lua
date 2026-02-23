-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingGtaNpc.lua
-- GTA-style NPC controller for the Jonesing dummy.
--
-- GHOST phase  — The dummy floats at spawn height and drifts forward in a
--                random walk, like a GTA pedestrian.  Implemented via
--                obj:setNodePosition so it works on any BeamNG version.
--
-- RAGDOLL phase — When an external force displaces any node more than
--                impactThreshold metres from its expected ghost position,
--                the controller stops overriding positions and lets BeamNG
--                physics run freely.
--
-- Controller params (set in the jbeam controller entry):
--   impactThreshold  (default 0.25 m) — node displacement (metres) that triggers ragdoll
--   walkSpeed        (default 0.6 m/s)— forward drift speed in ghost mode
--   walkChangePeriod (default 4.0 s)  — seconds between random direction changes
-- Note: ghost height is maintained automatically at spawn Z (constant anti-gravity).

local M = {}

-- ── internal state ────────────────────────────────────────────────────────────
local state            = "ghost"
local allNodes         = {}        -- {n, spawnX, spawnY, spawnZ}
local walkOffsetX      = 0.0
local walkOffsetY      = 0.0
local walkDir          = 0.0
local walkTimer        = 0.0

-- configurable params
local impactThreshold  = 0.25   -- metres
local walkSpeed        = 0.6    -- m/s
local walkChangePeriod = 4.0    -- seconds


-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────
local function init(jbeamData)
    impactThreshold  = jbeamData.impactThreshold  or impactThreshold
    walkSpeed        = jbeamData.walkSpeed        or walkSpeed
    walkChangePeriod = jbeamData.walkChangePeriod or walkChangePeriod

    -- Record spawn positions for every node
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

    -- Per-instance random seed so multiple dummies walk differently
    -- Seed using sum of first node cid (unique per vehicle instance)
    local seed = 0
    if allNodes[1] then seed = allNodes[1].cid end
    math.randomseed(os.time() + seed)
    walkDir = math.random() * 2 * math.pi

    walkOffsetX = 0
    walkOffsetY = 0
    walkTimer   = 0
    state       = "ghost"
end


local function reset()
    -- Re-read spawn positions after physics reset
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
    state   = "ghost"
end


local function updateGFX(dt)
    if dt <= 0 then return end
    if state == "ragdoll" then return end

    -- ── 1. Periodically nudge the walk direction ──────────────────────────────
    walkTimer = walkTimer + dt
    if walkTimer >= walkChangePeriod then
        walkTimer = 0
        -- ±45° random perturbation
        walkDir = walkDir + (math.random() - 0.5) * math.pi * 0.5
    end

    -- ── 2. Accumulate horizontal walk displacement ────────────────────────────
    local stepX = math.sin(walkDir) * walkSpeed * dt
    local stepY = math.cos(walkDir) * walkSpeed * dt
    walkOffsetX = walkOffsetX + stepX
    walkOffsetY = walkOffsetY + stepY

    -- ── 3. Check each node for external impact BEFORE moving ─────────────────
    --  If any node has drifted far from its ghost trajectory, switch to ragdoll.
    local impactThresholdSquared = impactThreshold * impactThreshold
    for _, rec in ipairs(allNodes) do
        local p = vec3(obj:getNodePosition(rec.cid))
        local dx = p.x - (rec.spawnX + walkOffsetX)
        local dy = p.y - (rec.spawnY + walkOffsetY)
        local dz = p.z - rec.spawnZ
        if (dx*dx + dy*dy + dz*dz) > impactThresholdSquared then
            state = "ragdoll"
            return
        end
    end

    -- ── 4. Ghost: teleport every node to its desired position ─────────────────
    --  Moving ALL nodes by the same offset keeps relative distances (beam
    --  lengths) constant → no spurious internal forces.
    for _, rec in ipairs(allNodes) do
        obj:setNodePosition(rec.cid, vec3(
            rec.spawnX + walkOffsetX,
            rec.spawnY + walkOffsetY,
            rec.spawnZ   -- constant Z = anti-gravity
        ))
    end
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
