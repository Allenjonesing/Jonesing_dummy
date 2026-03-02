-- lua/vehicle/extensions/explosionSystem.lua
-- Vehicle Explosion System — Jonesing mod
--
-- Monitors engine damage.  When the engine is severely damaged and begins
-- emitting fire, the vehicle is ignited immediately and then detonated after
-- a short countdown using BeamNG's built-in obj:explode() — the same API
-- used by the radial-menu "Explode" action.
--
-- USAGE (console):
--   extensions.load("explosionSystem")       -- load on current vehicle
--   extensions.explosionSystem.detonate()    -- manual immediate detonation
--   extensions.explosionSystem.getStatus()   -- log current state
--
-- CONFIG OVERRIDES (per vehicle or via console):
--   extensions.explosionSystem.configure({ debug = true, engineFireThreshold = 0.8 })

local M = {}

-- ── default configuration ────────────────────────────────────────────────────
local cfg = {
    enabled              = true,   -- master on/off switch
    debug                = true,   -- verbose logging (flip to false to quiet logs)
    armDelaySeconds      = 3.0,    -- seconds after init before monitoring starts
    engineFireThreshold  = 0.9,    -- powertrain damage ratio (0–1) that triggers fire
    explodeDelaySeconds  = 5.0,    -- seconds between ignition and detonation
    explosionRadius      = 12,     -- metres passed to explosionManager for chain reactions (12 m = city-block scale)
    chainReaction        = true,   -- allow manager to chain to nearby vehicles
    statusLogInterval    = 2.0,    -- seconds between periodic status logs (debug mode)
}

-- ── state ────────────────────────────────────────────────────────────────────
local state = {
    exploded          = false,   -- detonation already fired
    armed             = false,   -- arming delay elapsed
    armTimer          = 0,       -- counts up to cfg.armDelaySeconds
    engineFire        = false,   -- engine fire phase entered
    explodeTimer      = 0,       -- counts down from cfg.explodeDelaySeconds
    lastEngineDamage  = 0,       -- most recent powertrain damage reading
    statusTimer       = 0,       -- throttle for periodic debug logs
}

-- ── helpers ──────────────────────────────────────────────────────────────────
local TAG = "explosionSystem"

local function dbg(fmt, ...)
    if not cfg.debug then return end
    log("D", TAG, string.format(fmt, ...))
end

local function info(fmt, ...)
    log("I", TAG, string.format(fmt, ...))
end

-- ── fire + explode sequence ──────────────────────────────────────────────────

local function startEngineFire()
    -- Ignite the vehicle visually using BeamNG's built-in ignite API.
    local ok, err = pcall(function()
        if obj and obj.ignite then
            obj:ignite()
            dbg("obj:ignite() called — engine fire started")
        else
            dbg("obj.ignite not available on this build")
        end
    end)
    if not ok then
        dbg("startEngineFire pcall error: %s", tostring(err))
    end
end

local function notifyManager(pos)
    -- Queue a call to the GE-side explosionManager (if loaded).
    local ok, err = pcall(function()
        local cmd = string.format(
            "local m = extensions and extensions.explosionManager;" ..
            "if m and m.onVehicleExploded then" ..
            "  m.onVehicleExploded(%d, {x=%f,y=%f,z=%f,radius=%d,chain=%s})" ..
            "end",
            obj:getId(), pos.x, pos.y, pos.z,
            cfg.explosionRadius, tostring(cfg.chainReaction)
        )
        obj:queueGameEngineLua(cmd)
        dbg("Queued explosionManager notification to GE")
    end)
    if not ok then
        dbg("notifyManager pcall error: %s", tostring(err))
    end
end

local function doExplode(reason)
    if state.exploded then
        dbg("doExplode called but already exploded — ignoring")
        return
    end
    state.exploded = true

    info("*** EXPLODING *** reason='%s' engineDamage=%.3f", reason or "unknown", state.lastEngineDamage)

    -- Use BeamNG's built-in vehicle explosion (same as radial-menu "Explode").
    local ok, err = pcall(function()
        if obj and obj.explode then
            obj:explode()
            info("obj:explode() called — built-in explosion triggered")
        else
            info("obj.explode not available; falling back to obj:ignite()")
            if obj and obj.ignite then obj:ignite() end
        end
    end)
    if not ok then
        info("doExplode pcall error: %s", tostring(err))
    end

    -- Notify GE manager for chain reactions.
    local pos = obj:getPosition()
    notifyManager(pos)
end

-- ── public API ───────────────────────────────────────────────────────────────

-- Manual detonation (console: extensions.explosionSystem.detonate())
function M.detonate()
    if state.exploded then
        info("Already exploded; detonate() ignored")
        return
    end
    info("Manual detonate() called")
    doExplode("manual")
end

-- Chain-reaction entry point (called by explosionManager on nearby vehicles).
function M._chainDamage(amount)
    if not cfg.enabled or state.exploded then return end
    dbg("_chainDamage called amount=%.1f — triggering chain explosion", amount or 0)
    doExplode("chain_reaction")
end

-- Override config at runtime.
function M.configure(overrides)
    if type(overrides) ~= "table" then return end
    for k, v in pairs(overrides) do
        if cfg[k] ~= nil then
            cfg[k] = v
            dbg("configure: %s = %s", tostring(k), tostring(v))
        end
    end
    info("Config updated")
end

-- Status dump (console: extensions.explosionSystem.getStatus())
function M.getStatus()
    info("enabled=%s armed=%s engineFire=%s exploded=%s engineDamage=%.3f armTimer=%.1f explodeTimer=%.1f threshold=%.2f",
        tostring(cfg.enabled),
        tostring(state.armed),
        tostring(state.engineFire),
        tostring(state.exploded),
        state.lastEngineDamage,
        state.armTimer,
        state.explodeTimer,
        cfg.engineFireThreshold)
end

-- ── extension lifecycle ──────────────────────────────────────────────────────

function M.init(jbeamData)
    -- Accept per-vehicle jbeam config overrides: iterate cfg keys and copy
    -- matching values from jbeamData so the vehicle's jbeam can tune thresholds.
    if type(jbeamData) == "table" then
        for k in pairs(cfg) do
            if jbeamData[k] ~= nil then
                cfg[k] = jbeamData[k]
                dbg("init jbeam override: %s = %s", k, tostring(jbeamData[k]))
            end
        end
    end

    -- Reset state.
    state.exploded         = false
    state.armed            = false
    state.armTimer         = 0
    state.engineFire       = false
    state.explodeTimer     = 0
    state.lastEngineDamage = 0
    state.statusTimer      = 0

    info("explosionSystem init — enabled=%s debug=%s armDelay=%.1fs fireThreshold=%.2f explodeDelay=%.1fs",
        tostring(cfg.enabled), tostring(cfg.debug),
        cfg.armDelaySeconds, cfg.engineFireThreshold, cfg.explodeDelaySeconds)

    if not cfg.enabled then
        info("explosionSystem disabled by config — no monitoring will occur")
    end
end

function M.onReset()
    state.exploded         = false
    state.armed            = false
    state.armTimer         = 0
    state.engineFire       = false
    state.explodeTimer     = 0
    state.lastEngineDamage = 0
    state.statusTimer      = 0
    info("onReset — state cleared, arming delay restarted")
end

-- ── per-frame update ─────────────────────────────────────────────────────────

function M.updateGFX(dt)
    if not cfg.enabled or state.exploded then return end

    -- ── 1. Arming delay ────────────────────────────────────────────────────
    if not state.armed then
        state.armTimer = state.armTimer + dt
        if state.armTimer >= cfg.armDelaySeconds then
            state.armed = true
            info("Armed after %.2f s — now monitoring engine damage", state.armTimer)
        else
            -- Log arming progress once per second during debug.
            state.statusTimer = state.statusTimer + dt
            if cfg.debug and state.statusTimer >= 1.0 then
                state.statusTimer = 0
                dbg("Arming… %.1f / %.1f s", state.armTimer, cfg.armDelaySeconds)
            end
        end
        return
    end

    -- ── 2. Engine-fire countdown (post-ignition) ───────────────────────────
    if state.engineFire then
        state.explodeTimer = state.explodeTimer + dt

        -- Periodic countdown log so user can see it ticking.
        state.statusTimer = state.statusTimer + dt
        if cfg.debug and state.statusTimer >= 1.0 then
            state.statusTimer = 0
            dbg("Engine fire — exploding in %.1f s (elapsed %.1f / %.1f s)",
                cfg.explodeDelaySeconds - state.explodeTimer,
                state.explodeTimer, cfg.explodeDelaySeconds)
        end

        if state.explodeTimer >= cfg.explodeDelaySeconds then
            doExplode("engine_fire_countdown")
        end
        return
    end

    -- ── 3. Monitor engine damage ───────────────────────────────────────────
    local ok, err = pcall(function()
        local dmg = 0
        if powertrain and powertrain.getEngineDamage then
            dmg = powertrain.getEngineDamage() or 0
        end
        state.lastEngineDamage = dmg

        -- Periodic status log so user can confirm the extension is running.
        state.statusTimer = state.statusTimer + dt
        if cfg.debug and state.statusTimer >= cfg.statusLogInterval then
            state.statusTimer = 0
            dbg("Status — engineDamage=%.3f threshold=%.2f engineFire=%s exploded=%s",
                dmg, cfg.engineFireThreshold,
                tostring(state.engineFire), tostring(state.exploded))
        end

        if dmg >= cfg.engineFireThreshold then
            state.engineFire  = true
            state.explodeTimer = 0
            state.statusTimer  = 0
            info("Engine damage %.3f >= threshold %.2f — IGNITING, will explode in %.1f s",
                dmg, cfg.engineFireThreshold, cfg.explodeDelaySeconds)
            startEngineFire()
        end
    end)
    if not ok then
        dbg("updateGFX engine-check pcall error: %s", tostring(err))
    end
end

return M
