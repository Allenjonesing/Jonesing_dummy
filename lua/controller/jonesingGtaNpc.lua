-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingGtaNpc.lua
-- GTA-style NPC controller for the Jonesing dummy.
--
-- Two phases:
--   GHOST  — Anti-gravity levitation + slow random walk. The dummy floats
--             just above the road and drifts forward like a GTA pedestrian
--             until a vehicle gets close or impacts it.
--   RAGDOLL — Full BeamNG physics. Triggered by a sudden external impact
--             (velocity spike) or when the vehicle comes within the proximity
--             radius set by "triggerRadius".
--
-- Controller params (set in the jbeam controller entry):
--   triggerRadius   (default 6 m)    — proximity radius that triggers ragdoll
--   impactThreshold (default 3 m/s)  — per-frame velocity delta that triggers ragdoll
--   walkSpeed       (default 0.8 m/s)— forward drift speed in ghost mode
--   ghostHeight     (default 0.05 m) — hover height above ground in ghost mode

local M = {}

-- ── internal state ────────────────────────────────────────────────────────────
local state           = "ghost"   -- "ghost" | "ragdoll"
local bodyNodes       = {}        -- central body nodes we apply forces to
local footNodes       = {}        -- lowest nodes, used to estimate ground height
local allNodes        = {}        -- every node, for proximity/velocity checks
local prevNodeVel     = {}        -- previous frame velocity per cid

-- configurable params (overridden by jbeam init data)
local triggerRadius   = 6.0
local impactThreshold = 3.0
local walkSpeed       = 0.8
local ghostHeight     = 0.05

-- walking state
local walkDir         = 0.0       -- radians, world-space heading
local walkTimer       = 0.0       -- time since last direction change
local walkChangePeriod = 4.0      -- seconds between direction tweaks
local ghostLiftForce  = 0.0       -- computed per-node anti-gravity force (N)

-- tuning constants
local WALK_FORCE_MULTIPLIER   = 8   -- empirical: translates m/s walk speed to Newtons
local VERTICAL_DAMPING_FACTOR = 20  -- how strongly to damp upward drift (N per m/s)

-- approx. BeamNG world gravity
local GRAVITY         = 9.81


-- ── helpers ───────────────────────────────────────────────────────────────────
local function nodeWorldPos(cid)
    return vec3(obj:getNodePosition(cid))
end

local function nodeWorldVel(cid)
    -- obj:getNodeVelocity returns world-space velocity vec3
    local ok, v = pcall(function() return vec3(obj:getNodeVelocity(cid)) end)
    if ok then return v end
    return vec3(0, 0, 0)
end

local function switchToRagdoll()
    if state == "ragdoll" then return end
    state = "ragdoll"
    -- Zero out any stored velocities to avoid false re-triggers
    prevNodeVel = {}
end


-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────
local function init(jbeamData)
    -- Read optional params from the jbeam controller entry
    triggerRadius   = jbeamData.triggerRadius   or triggerRadius
    impactThreshold = jbeamData.impactThreshold or impactThreshold
    walkSpeed       = jbeamData.walkSpeed       or walkSpeed
    ghostHeight     = jbeamData.ghostHeight     or ghostHeight

    -- Categorise nodes
    for _, n in pairs(v.data.nodes) do
        if n.name ~= nil then
            table.insert(allNodes, n)
            -- torso + abdomen + pelvis nodes carry the anti-gravity load
            if string.match(n.name, "dummy1_thorax")
                or string.match(n.name, "dummy1_abdomen")
                or string.match(n.name, "dummy1_pelvis") then
                table.insert(bodyNodes, n)
                -- Per-node lift force: F = m * g  (cancel gravity exactly)
                ghostLiftForce = ghostLiftForce + (n.nodeWeight or 0.5) * GRAVITY
            end
            -- foot nodes used to probe ground height
            if string.match(n.name, "dummy1_L_foot") or string.match(n.name, "dummy1_R_foot") then
                table.insert(footNodes, n)
            end
        end
    end

    -- Randomise initial walk direction so multiple NPCs don't all walk the same way.
    -- Seed with object ID + time so each dummy instance gets a different sequence.
    math.randomseed(os.time() + (obj:getID and obj:getID() or 0))
    walkDir = math.random() * 2 * math.pi

    state = "ghost"
end


local function reset()
    state = "ghost"
    prevNodeVel = {}
    walkTimer   = 0
    math.randomseed(os.time() + (obj:getID and obj:getID() or 0))
    walkDir     = math.random() * 2 * math.pi
end


local function updateGFX(dt)
    if dt <= 0 then return end

    -- ── Check for impact (large per-frame velocity delta) ─────────────────────
    -- Only sample a subset of body nodes for performance
    if state ~= "ragdoll" then
        for _, n in pairs(bodyNodes) do
            local cid = n.cid
            local vel = nodeWorldVel(cid)
            local prev = prevNodeVel[cid]
            if prev ~= nil then
                local delta = (vel - prev):length()
                if delta > impactThreshold then
                    switchToRagdoll()
                    return
                end
            end
            prevNodeVel[cid] = vel
        end
    end

    -- ── RAGDOLL — nothing to do, let physics run ──────────────────────────────
    if state == "ragdoll" then return end

    -- ── GHOST — anti-gravity + drift ─────────────────────────────────────────

    -- 1. Anti-gravity: distribute lift evenly across body nodes so the dummy
    --    floats without collapsing under its own weight.
    --    liftPerNode = total_lift / count so we don't over-apply.
    local liftPerNode = ghostLiftForce / math.max(#bodyNodes, 1)
    for _, n in pairs(bodyNodes) do
        -- apply upward impulse (BeamNG force is in Newtons, applied per GFX frame)
        obj:applyNodeForce(n.cid, 0, 0, liftPerNode)
    end

    -- 2. Random walk: gentle horizontal push in the current heading.
    --    Change direction every walkChangePeriod seconds.
    walkTimer = walkTimer + dt
    if walkTimer >= walkChangePeriod then
        walkTimer = 0
        -- Small random heading perturbation  (±45°)
        walkDir = walkDir + (math.random() - 0.5) * math.pi * 0.5
    end

    -- Forward force proportional to walkSpeed (empirical: ~10× for stability)
    local fx = math.sin(walkDir) * walkSpeed * WALK_FORCE_MULTIPLIER
    local fy = math.cos(walkDir) * walkSpeed * WALK_FORCE_MULTIPLIER
    for _, n in pairs(bodyNodes) do
        obj:applyNodeForce(n.cid, fx, fy, 0)
    end

    -- 3. Damping: bleed off any excess vertical velocity so the dummy doesn't
    --    bounce. Apply a gentle downward counter-force when rising fast.
    for _, n in pairs(footNodes) do
        local vel = nodeWorldVel(n.cid)
        if vel.z > 0.3 then
            -- Rising — damp it back
            obj:applyNodeForce(n.cid, 0, 0, -vel.z * VERTICAL_DAMPING_FACTOR)
        end
    end
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init       = init
M.reset      = reset
M.updateGFX  = updateGFX

return M
