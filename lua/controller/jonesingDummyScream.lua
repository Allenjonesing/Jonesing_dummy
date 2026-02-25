-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- jonesingDummyScream.lua
-- Plays a randomised scream/yell when the dummy receives a significant impact.
--
-- Impact detection: monitors the chest reference node ("dummy1_thoraxtfl").
-- Each frame the position displacement is divided by dt to estimate instantaneous
-- impact speed.  When that speed exceeds the threshold and the cooldown has
-- expired, a random sound is selected from the pool and played via
-- Engine.Audio.playOnce at the dummy's world position (3-D spatialized).
--
-- ── Configuration ─────────────────────────────────────────────────────────────
-- All tuneable values live in the `cfg` table below.
-- Individual fields can also be overridden from the JBeam slot entry:
--   screams_cooldown   → cfg.cooldown
--   screams_speed      → cfg.impactSpeed
--   screams_maxDist    → cfg.maxDistance
--   screams_volume     → cfg.volume
--
-- ── Sound assets ──────────────────────────────────────────────────────────────
-- Place 10 .ogg files at:
--   art/sound/dummy_screams/scream_01.ogg … scream_10.ogg
-- (relative to the BeamNG user content / mod root).
-- The controller calls Engine.Audio.playOnce inside a pcall so a missing file
-- is silently ignored and does not crash the vehicle simulation.

local M = {}

-- ── configuration (single place to tweak all sound behaviour) ─────────────────
local cfg = {
    -- Pool of scream sound files — 10 variations for randomisation.
    sounds = {
        "art/sound/dummy_screams/scream_01.ogg",
        "art/sound/dummy_screams/scream_02.ogg",
        "art/sound/dummy_screams/scream_03.ogg",
        "art/sound/dummy_screams/scream_04.ogg",
        "art/sound/dummy_screams/scream_05.ogg",
        "art/sound/dummy_screams/scream_06.ogg",
        "art/sound/dummy_screams/scream_07.ogg",
        "art/sound/dummy_screams/scream_08.ogg",
        "art/sound/dummy_screams/scream_09.ogg",
        "art/sound/dummy_screams/scream_10.ogg",
    },
    -- Minimum seconds between consecutive screams on the same dummy (anti-spam).
    cooldown        = 2.0,
    -- Minimum estimated impact speed (m/s) to trigger a scream.
    -- ~3 m/s ≈ 11 km/h — slow brush contacts are ignored; proper impacts fire.
    impactSpeed     = 3.0,
    -- Maximum camera distance (metres) beyond which the sound is skipped.
    maxDistance     = 60.0,
    -- Base playback volume [0..1].
    volume          = 0.85,
    -- Pitch variation: random pitch in [1-pitchRange, 1+pitchRange].
    pitchRange      = 0.15,
    -- BeamNG audio channel used for playback.
    channel         = "AudioGui",
    -- Grace period (seconds) after init() before detection is active.
    -- Mirrors the GTA-NPC grace period so spawn physics don't false-trigger.
    startupGrace    = 3.5,
}

-- ── internal state ─────────────────────────────────────────────────────────────
local refCid       = nil    -- cid of the chest reference node
local lastX        = 0.0
local lastY        = 0.0
local lastZ        = 0.0
local cooldownLeft = 0.0    -- seconds remaining before next scream allowed
local graceTimer   = 0.0    -- seconds elapsed during startup grace period
local active       = false  -- true once grace period has ended
local numSounds    = 0      -- cached length of cfg.sounds

-- Name of the reference body node — same as jonesingGtaNpc for consistency.
local REF_NODE_NAME = "dummy1_thoraxtfl"


-- ── helpers ────────────────────────────────────────────────────────────────────

-- Returns the current camera world position as a vec3, or nil on any error.
local function getCamPos()
    local ok, result = pcall(function()
        local cam = scenetree.MainCamera
        if cam then
            local p = cam:getPosition()
            return vec3(p.x, p.y, p.z)
        end
    end)
    return (ok and result) or nil
end


-- Plays one randomly chosen scream at the given world-space position.
local function playScream(x, y, z)
    if numSounds < 1 then return end
    local path  = cfg.sounds[math.random(1, numSounds)]
    local pitch = 1.0 + (math.random() * 2.0 - 1.0) * cfg.pitchRange
    -- Wrapped in pcall so a missing/corrupt audio file never crashes the sim.
    pcall(function()
        Engine.Audio.playOnce(cfg.channel, path, {
            volume   = cfg.volume,
            pitch    = pitch,
            -- Point3F is the BeamNG world-position type accepted by playOnce.
            pos      = Point3F(x, y, z),
        })
    end)
end


-- ── JBeam lifecycle callbacks ──────────────────────────────────────────────────

local function init(jbeamData)
    -- Allow per-slot JBeam overrides for key thresholds.
    if jbeamData.screams_cooldown then cfg.cooldown     = jbeamData.screams_cooldown end
    if jbeamData.screams_speed    then cfg.impactSpeed  = jbeamData.screams_speed    end
    if jbeamData.screams_maxDist  then cfg.maxDistance  = jbeamData.screams_maxDist  end
    if jbeamData.screams_volume   then cfg.volume       = jbeamData.screams_volume   end

    -- Locate the chest reference node by name; fall back to the first node.
    refCid = nil
    local firstCid = nil
    for _, n in pairs(v.data.nodes) do
        if firstCid == nil then firstCid = n.cid end
        if n.name == REF_NODE_NAME then
            refCid = n.cid
            break
        end
    end
    if not refCid then refCid = firstCid end

    numSounds    = #cfg.sounds
    cooldownLeft = 0.0
    graceTimer   = 0.0
    active       = false

    -- Unique RNG seed per dummy instance so they don't play the same variation.
    math.randomseed(os.time() + (refCid or 0))
end


local function reset()
    cooldownLeft = 0.0
    graceTimer   = 0.0
    active       = false
    if refCid then
        local p = vec3(obj:getNodePosition(refCid))
        lastX, lastY, lastZ = p.x, p.y, p.z
    end
end


local function updateGFX(dt)
    if dt <= 0 or not refCid then return end

    -- ── 1. Startup grace: wait for physics to settle ─────────────────────────
    if not active then
        graceTimer = graceTimer + dt
        if graceTimer >= cfg.startupGrace then
            -- Snapshot current position as the no-impact baseline.
            local p = vec3(obj:getNodePosition(refCid))
            lastX, lastY, lastZ = p.x, p.y, p.z
            active = true
        end
        return
    end

    -- ── 2. Cooldown countdown ─────────────────────────────────────────────────
    if cooldownLeft > 0 then
        cooldownLeft = cooldownLeft - dt
    end

    -- ── 3. Estimate impact speed from per-frame displacement ──────────────────
    local cur = vec3(obj:getNodePosition(refCid))
    local dx  = cur.x - lastX
    local dy  = cur.y - lastY
    local dz  = cur.z - lastZ
    -- displacement / dt  →  approximate instantaneous velocity magnitude
    local impactSpeed = math.sqrt(dx*dx + dy*dy + dz*dz) / dt

    -- Always update the last-known position for the next frame.
    lastX, lastY, lastZ = cur.x, cur.y, cur.z

    -- ── 4. Threshold + cooldown gate ─────────────────────────────────────────
    if impactSpeed < cfg.impactSpeed or cooldownLeft > 0 then return end

    -- ── 5. Distance cull ─────────────────────────────────────────────────────
    local camPos = getCamPos()
    if camPos then
        local cx = cur.x - camPos.x
        local cy = cur.y - camPos.y
        local cz = cur.z - camPos.z
        if (cx*cx + cy*cy + cz*cz) > cfg.maxDistance * cfg.maxDistance then return end
    end

    -- ── 6. Play scream and start cooldown ────────────────────────────────────
    playScream(cur.x, cur.y, cur.z)
    cooldownLeft = cfg.cooldown
end


-- ── public interface ───────────────────────────────────────────────────────────
M.init      = init
M.reset     = reset
M.updateGFX = updateGFX

return M
