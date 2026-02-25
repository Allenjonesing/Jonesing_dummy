-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- lua/ge/extensions/jonesing/impactParticles.lua
--
-- Impact particle spawn library for the Jonesing dummy mod.
--
-- Public entry point:
--   extensions.jonesing_impactParticles.spawnImpactParticles(
--       posX, posY, posZ,        -- world position of the impact
--       normalX, normalY, normalZ, -- surface normal (used to orient emitter)
--       intensity,               -- 0-1+ scale: affects lifetime multiplier
--       presetName,              -- one of the PRESET keys below
--       colourVariant            -- optional: "red" | "blue" | nil (default)
--   )
--
-- ── Preset list ──────────────────────────────────────────────────────────────
--   "impact_sparks"       yellow-white sparks (vehicle hit / metal scrape)
--   "impact_dust_puff"    brownish dust cloud (ground hit / landing)
--   "impact_blood_spray"  dark-red droplets   (dummy hit / run-over)
--   "impact_gibs_light"   reddish fleck debris (heavy dummy impact)
--
-- ── Recolouring ──────────────────────────────────────────────────────────────
--   Pass colourVariant = "red" or "blue" to use the named colour-variant emitter
--   defined in jonesing_impact_particles.cs.  Works because the colour is owned
--   by the ParticleData colorOverLife keyframes — NOT by material diffuseColor.
--
-- ── Intensity scaling ────────────────────────────────────────────────────────
--   intensity drives the active-duration of the emitter:
--     duration = preset.baseDurationMS * clamp(intensity, 0.1, 3.0)
--   Higher intensity = emitter runs longer = more particles emitted.
--
-- ── Emitter pool ─────────────────────────────────────────────────────────────
--   Each preset × colour-variant has a pool of POOL_SIZE ParticleEmitterNode
--   objects pre-created when the extension loads.  spawnImpactParticles grabs a
--   free node, moves it to the impact position, activates it, and schedules
--   deactivation so the node returns to the free pool.
--
-- ── Test harness ─────────────────────────────────────────────────────────────
--   From the in-game console (~ key):
--     extensions.jonesing_impactParticles.testSpawn("impact_sparks")
--     extensions.jonesing_impactParticles.testSpawn("impact_blood_spray","red")
--     extensions.jonesing_impactParticles.testSpawn("impact_gibs_light","blue")
--   These spawn the chosen preset at the player camera's aim point.

local M = {}

-- ── constants ─────────────────────────────────────────────────────────────────

-- Number of pooled emitter nodes per (preset × variant) combination.
local POOL_SIZE = 3

-- When no pool node is free, wait this many ms before trying again (skips burst).
local COOLDOWN_SKIP_MS = 50

-- ── preset definitions ────────────────────────────────────────────────────────
--
-- Each entry declares the emitter datablock names (one per colour variant) that
-- were authored in jonesing_impact_particles.cs, plus the base active-duration.
-- baseDurationMS is how long (ms) the emitter stays active at intensity = 1.0.

local PRESETS = {
    impact_sparks = {
        emitters = {
            default = "jonesing_ImpactSparks_Emitter",
            red     = "jonesing_ImpactSparks_Red_Emitter",
            blue    = "jonesing_ImpactSparks_Blue_Emitter",
        },
        baseDurationMS = 400,
    },
    impact_dust_puff = {
        emitters = {
            default = "jonesing_ImpactDust_Emitter",
            red     = "jonesing_ImpactDust_Red_Emitter",
            blue    = "jonesing_ImpactDust_Blue_Emitter",
        },
        baseDurationMS = 600,
    },
    impact_blood_spray = {
        emitters = {
            default = "jonesing_ImpactBlood_Emitter",
            red     = "jonesing_ImpactBlood_Red_Emitter",
            blue    = "jonesing_ImpactBlood_Blue_Emitter",
        },
        baseDurationMS = 350,
    },
    impact_gibs_light = {
        emitters = {
            default = "jonesing_ImpactGibs_Emitter",
            red     = "jonesing_ImpactGibs_Red_Emitter",
            blue    = "jonesing_ImpactGibs_Blue_Emitter",
        },
        baseDurationMS = 500,
    },
}

-- ── pool state ────────────────────────────────────────────────────────────────
-- pool[poolKey] = { {node=<ParticleEmitterNode>, free=true}, ... }
-- poolKey = "<presetName>_<variantOrDefault>"
local pool = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

local function poolKey(presetName, variant)
    return presetName .. "_" .. (variant or "default")
end

-- Build a unique scene-object name for a pool slot.
local function nodeName(presetName, variant, idx)
    return "jonesing_ip_" .. presetName .. "_" .. (variant or "def") .. "_" .. idx
end

-- Attempt to create a ParticleEmitterNode using TorqueScript eval.
-- Returns the scenetree object, or nil on failure.
local function createEmitterNode(emitterDataName, objectName)
    local ok, err = pcall(function()
        -- Place far below the map so it doesn't render before first use.
        Engine.eval(string.format(
            'new ParticleEmitterNode(%s) { emitter = "%s"; active = false; ' ..
            'position = "0 0 -2000"; rotation = "1 0 0 0"; scale = "1 1 1"; };',
            objectName, emitterDataName
        ))
    end)
    if not ok then
        log("W", "jonesing_impactParticles",
            "createEmitterNode failed for " .. objectName .. ": " .. tostring(err))
        return nil
    end
    return scenetree.findObject(objectName)
end

-- ── initialisation ────────────────────────────────────────────────────────────

local function buildPool()
    pool = {}
    for presetName, preset in pairs(PRESETS) do
        for variant, emitterDataName in pairs(preset.emitters) do
            local key   = poolKey(presetName, variant)
            pool[key]   = {}
            for i = 1, POOL_SIZE do
                local name = nodeName(presetName, variant, i)
                -- Remove any stale node from a previous session.
                local stale = scenetree.findObject(name)
                if stale then stale:delete() end

                local node = createEmitterNode(emitterDataName, name)
                if node then
                    table.insert(pool[key], { node = node, free = true })
                end
            end
        end
    end
    log("I", "jonesing_impactParticles", "Emitter pool built.")
end

-- ── spawn ──────────────────────────────────────────────────────────────────────

--- Spawn an impact particle effect.
-- @param posX, posY, posZ      World position of the impact.
-- @param normalX, normalY, normalZ  Surface normal at impact (used for orientation).
-- @param intensity             0-1+ strength: scales emitter active-duration.
-- @param presetName            Preset key (see module header).
-- @param colourVariant         Optional "red"|"blue"|nil for default colours.
local function spawnImpactParticles(posX, posY, posZ,
                                    normalX, normalY, normalZ,
                                    intensity, presetName, colourVariant)

    local preset = PRESETS[presetName]
    if not preset then
        log("W", "jonesing_impactParticles",
            "Unknown preset: " .. tostring(presetName))
        return
    end

    -- Resolve colour variant (fall back to default if the variant is missing).
    local variant = (colourVariant and preset.emitters[colourVariant])
                    and colourVariant or "default"
    local key     = poolKey(presetName, variant)
    local slots   = pool[key]
    if not slots or #slots == 0 then
        log("W", "jonesing_impactParticles",
            "No pool for key: " .. key)
        return
    end

    -- Find a free slot.
    local slot = nil
    for _, s in ipairs(slots) do
        if s.free then slot = s; break end
    end
    if not slot then return end  -- all busy; skip this burst

    -- Intensity: clamp and scale duration.
    local clampedIntensity = math.max(0.1, math.min(intensity or 1.0, 3.0))
    local durationMS = math.floor(preset.baseDurationMS * clampedIntensity)

    -- Move and activate.
    slot.free = false
    local node = slot.node
    node:setPosition(vec3(posX, posY, posZ))
    node:setField("active", 0, "false")  -- reset first in case it was mid-burst
    node:setField("active", 0, "true")

    -- Schedule deactivation and free the slot after durationMS.
    -- We use a closure-based timer via Engine.postFrameCallback or a simple
    -- per-frame countdown stored in a pending list.
    local finishAt = Engine.getSimTime() + durationMS / 1000.0
    slot._finishAt = finishAt
end

-- ── per-frame tick: deactivate finished emitters ──────────────────────────────

local function onPreRender(dt)
    local now = Engine.getSimTime()
    for _, slots in pairs(pool) do
        for _, slot in ipairs(slots) do
            if not slot.free and slot._finishAt and now >= slot._finishAt then
                slot.node:setField("active", 0, "false")
                slot.free     = true
                slot._finishAt = nil
            end
        end
    end
end

-- ── test harness ──────────────────────────────────────────────────────────────

--- Spawn a preset at the player camera aim-point (console test helper).
-- Usage from in-game console:
--   extensions.jonesing_impactParticles.testSpawn("impact_sparks")
--   extensions.jonesing_impactParticles.testSpawn("impact_blood_spray","red")
--   extensions.jonesing_impactParticles.testSpawn("impact_gibs_light","blue")
local function testSpawn(presetName, colourVariant)
    -- Try to get the camera look-at position via a ray cast.
    local pos  = nil
    local norm = {0, 0, 1}

    local ok = pcall(function()
        local cam  = getCameraTransform()
        if cam then
            local ox, oy, oz = cam.pos.x, cam.pos.y, cam.pos.z
            local dx, dy, dz = cam.fwd.x, cam.fwd.y, cam.fwd.z
            -- Cast a 50 m ray from the camera.
            local hit = castRay(ox, oy, oz, dx * 50, dy * 50, dz * 50)
            if hit then
                pos  = {hit.x, hit.y, hit.z}
                if hit.normal then
                    norm = {hit.normal.x, hit.normal.y, hit.normal.z}
                end
            else
                -- No hit — spawn 10 m ahead of the camera.
                pos = {ox + dx * 10, oy + dy * 10, oz + dz * 10}
            end
        end
    end)

    if not ok or not pos then
        -- Fallback: spawn just above origin.
        pos = {0, 0, 2}
    end

    log("I", "jonesing_impactParticles",
        string.format("testSpawn preset=%s variant=%s at (%.2f, %.2f, %.2f)",
            tostring(presetName), tostring(colourVariant),
            pos[1], pos[2], pos[3]))

    spawnImpactParticles(
        pos[1], pos[2], pos[3],
        norm[1], norm[2], norm[3],
        1.0, presetName, colourVariant
    )
end

-- ── extension lifecycle ───────────────────────────────────────────────────────

local function onExtensionLoaded()
    buildPool()
end

local function onExtensionUnloaded()
    -- Clean up pooled nodes.
    for _, slots in pairs(pool) do
        for _, slot in ipairs(slots) do
            if slot.node then
                pcall(function() slot.node:delete() end)
            end
        end
    end
    pool = {}
end

-- ── public interface ──────────────────────────────────────────────────────────

M.onExtensionLoaded   = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onPreRender         = onPreRender

M.spawnImpactParticles = spawnImpactParticles
M.testSpawn            = testSpawn

-- Expose PRESETS table so callers can enumerate available presets at runtime.
M.presets = PRESETS

return M
