-- lua/vehicle/extensions/explosionSystem.lua
-- Vehicle Explosion System — Jonesing mod
--
-- Monitors the ENGINE for REAL failure signals instead of invented damage values:
--   Primary:  powertrain device thermals flags
--               headGasketBlown / pistonRingsDamaged / connectingRodBearingsDamaged
--   Secondary: electrics stall fallback — engine was running (rpm > threshold)
--               and suddenly stops (engineRunning == 0 or rpm drops to 0)
--
-- When any failure signal fires the sequence is:
--   1. obj:ignite()           — start engine fire visually (VE context)
--   2. Wait explodeDelaySeconds (default 5 s, configurable)
--   3. Notify GE explosionManager via obj:queueGameEngineLua — GE then calls
--        core_explosion.createExplosion(pos, power, radius)
--      which is the BeamNG built-in explosion used by the "Fun Stuff → Boom!" menu.
--
-- USAGE (console while in-game):
--   extensions.load("explosionSystem")              -- load on current vehicle
--   extensions.explosionSystem.detonate()           -- manual immediate trigger
--   extensions.explosionSystem.getStatus()          -- dump full state to log
--   extensions.explosionSystem.configure({ debug = true })

local M = {}

-- ── default configuration ────────────────────────────────────────────────────
local cfg = {
    enabled                = true,   -- master on/off switch
    debug                  = true,   -- verbose every-frame logging
    armDelaySeconds        = 3.0,    -- seconds after init before monitoring starts
    explodeDelaySeconds    = 0.0,    -- seconds between ignition and explosion
    engineDeviceName       = "mainEngine", -- powertrain device name to inspect
    stallRpmThreshold      = 400,    -- RPM below which engine is considered stalled
    stallWasRunningRpm     = 600,    -- RPM above which we mark engine as "was running"
    explosionPower         = 5,      -- power passed to core_explosion.createExplosion
    explosionRadius        = 12,     -- metres passed to explosionManager for chains
    chainReaction          = true,   -- allow GE manager to chain to nearby vehicles
    statusLogInterval      = 2.0,    -- seconds between periodic status log lines
}

-- ── state ────────────────────────────────────────────────────────────────────
local state = {
    exploded         = false,   -- detonation already fired — single-shot guard
    armed            = false,   -- arming delay elapsed
    armTimer         = 0,       -- accumulates up to cfg.armDelaySeconds
    engineFire       = false,   -- ignition phase entered
    explodeTimer     = 0,       -- accumulates up to cfg.explodeDelaySeconds
    statusTimer      = 0,       -- throttles periodic debug lines
    triggerReason    = "",      -- which signal fired the trigger
    engineWasRunning = false,   -- stall-fallback: was engine running above threshold?
    -- last sampled values (for logging)
    lastRpm          = 0,
    lastThrottle     = 0,
    lastEngineRunning = -1,
    lastHgb          = false,
    lastPrd          = false,
    lastCrbd         = false,
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

-- ── engine fire + explosion sequence ─────────────────────────────────────────

local function startFire()
    local ok, err = pcall(function()
        if obj and obj.ignite then
            obj:ignite()
            info("obj:ignite() called — engine fire started")
        else
            info("obj.ignite not available — skipping visual fire")
        end
    end)
    if not ok then info("startFire error: %s", tostring(err)) end
end

local function notifyGE()
    -- Queue a call to explosionManager in GE context.
    -- GE will call core_explosion.createExplosion(pos, power, radius) — the
    -- BeamNG built-in explosion used by the "Fun Stuff → Boom!" radial menu.
    local ok, err = pcall(function()
        local pid = obj:getId()
        local pos = obj:getPosition()
        local cmd = string.format(
            "local m = extensions and extensions.explosionManager;" ..
            "if m and m.onVehicleExploded then" ..
            "  m.onVehicleExploded(%d,{x=%f,y=%f,z=%f,power=%f,radius=%d,chain=%s})" ..
            "end",
            pid, pos.x, pos.y, pos.z,
            cfg.explosionPower, cfg.explosionRadius, tostring(cfg.chainReaction)
        )
        obj:queueGameEngineLua(cmd)
        info("Queued GE core_explosion.createExplosion notification (vehicle %d power=%.0f radius=%d)",
            pid, cfg.explosionPower, cfg.explosionRadius)
    end)
    if not ok then info("notifyGE error: %s", tostring(err)) end
end

local function doExplode(reason)
    if state.exploded then
        dbg("doExplode(%s) ignored — already exploded", reason or "?")
        return
    end
    state.exploded    = true
    state.triggerReason = reason or "unknown"

    info("*** BOOM *** reason='%s'  rpm=%.0f throttle=%.2f engineRunning=%s",
        reason, state.lastRpm, state.lastThrottle, tostring(state.lastEngineRunning))
    info("  thermals at trigger: headGasketBlown=%s pistonRingsDamaged=%s connectingRodBearingsDamaged=%s",
        tostring(state.lastHgb), tostring(state.lastPrd), tostring(state.lastCrbd))

    -- obj:ignite() starts the visual engine fire.
    -- The actual explosion effect is handled by explosionManager.lua in GE context
    -- via notifyGE() → core_explosion.createExplosion(pos, power, radius).
    -- Note: obj:explode() does NOT exist in BeamNG VE Lua.
    pcall(function() obj:ignite() end)

    notifyGE()
end

-- ── public API ───────────────────────────────────────────────────────────────

function M.detonate()
    if state.exploded then
        info("detonate() called but already exploded — ignoring")
        return
    end
    info("Manual detonate() called")
    doExplode("manual_detonate")
end

function M._chainDamage(amount)
    if not cfg.enabled or state.exploded then return end
    info("_chainDamage(%.1f) received — triggering chain explosion", amount or 0)
    doExplode("chain_reaction")
end

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

function M.getStatus()
    info("=== explosionSystem status ===")
    info("  enabled=%s  debug=%s  armed=%s  engineFire=%s  exploded=%s",
        tostring(cfg.enabled), tostring(cfg.debug),
        tostring(state.armed), tostring(state.engineFire), tostring(state.exploded))
    info("  armTimer=%.2f / %.2f s  explodeTimer=%.2f / %.2f s",
        state.armTimer, cfg.armDelaySeconds,
        state.explodeTimer, cfg.explodeDelaySeconds)
    info("  triggerReason='%s'  engineWasRunning=%s",
        state.triggerReason, tostring(state.engineWasRunning))
    info("  last rpm=%.0f  throttle=%.2f  engineRunning=%s",
        state.lastRpm, state.lastThrottle, tostring(state.lastEngineRunning))
    info("  last thermals: headGasketBlown=%s  pistonRingsDamaged=%s  connectingRodBearingsDamaged=%s",
        tostring(state.lastHgb), tostring(state.lastPrd), tostring(state.lastCrbd))
    info("=================================")
end

-- ── extension lifecycle ──────────────────────────────────────────────────────

function M.init(jbeamData)
    if type(jbeamData) == "table" then
        for k in pairs(cfg) do
            if jbeamData[k] ~= nil then
                cfg[k] = jbeamData[k]
                dbg("init jbeam override: %s = %s", k, tostring(jbeamData[k]))
            end
        end
    end

    state.exploded          = false
    state.armed             = false
    state.armTimer          = 0
    state.engineFire        = false
    state.explodeTimer      = 0
    state.statusTimer       = 0
    state.triggerReason     = ""
    state.engineWasRunning  = false
    state.lastRpm           = 0
    state.lastThrottle      = 0
    state.lastEngineRunning = -1
    state.lastHgb           = false
    state.lastPrd           = false
    state.lastCrbd          = false

    info("explosionSystem init — enabled=%s debug=%s armDelay=%.1fs explodeDelay=%.1fs device='%s'",
        tostring(cfg.enabled), tostring(cfg.debug),
        cfg.armDelaySeconds, cfg.explodeDelaySeconds, cfg.engineDeviceName)
    if not cfg.enabled then
        info("explosionSystem disabled by config — monitoring will NOT run")
    end
end

function M.onReset()
    state.exploded          = false
    state.armed             = false
    state.armTimer          = 0
    state.engineFire        = false
    state.explodeTimer      = 0
    state.statusTimer       = 0
    state.triggerReason     = ""
    state.engineWasRunning  = false
    state.lastRpm           = 0
    state.lastThrottle      = 0
    state.lastEngineRunning = -1
    state.lastHgb           = false
    state.lastPrd           = false
    state.lastCrbd          = false
    info("onReset — state cleared, arming restarted")
end

-- ── per-frame update ─────────────────────────────────────────────────────────

function M.updateGFX(dt)
    if not cfg.enabled or state.exploded then return end

    -- ── 1. Arming delay ────────────────────────────────────────────────────────
    if not state.armed then
        state.armTimer = state.armTimer + dt
        state.statusTimer = state.statusTimer + dt
        if state.armTimer >= cfg.armDelaySeconds then
            state.armed = true
            state.statusTimer = 0
            info("Armed after %.2f s — now monitoring engine thermals", state.armTimer)
        else
            if cfg.debug and state.statusTimer >= 1.0 then
                state.statusTimer = 0
                dbg("Arming %.1f / %.1f s", state.armTimer, cfg.armDelaySeconds)
            end
        end
        return
    end

    -- ── 2. Fire countdown: wait then notify GE to call core_explosion ─────────────
    if state.engineFire then
        state.explodeTimer = state.explodeTimer + dt
        state.statusTimer  = state.statusTimer  + dt
        if cfg.debug and state.statusTimer >= 1.0 then
            state.statusTimer = 0
            dbg("Engine fire — BOOM in %.1f s (elapsed %.1f / %.1f s)",
                cfg.explodeDelaySeconds - state.explodeTimer,
                state.explodeTimer, cfg.explodeDelaySeconds)
        end
        if state.explodeTimer >= cfg.explodeDelaySeconds then
            doExplode("engine_fire_countdown")
        end
        return
    end

    -- ── 3. Sample electrics values (used by both primary and fallback) ─────────
    local rpm          = 0
    local throttle     = 0
    local engineRunning = -1
    pcall(function()
        local ev = electrics and electrics.values
        if ev then
            rpm          = ev.rpmTacho or ev.rpm or 0
            throttle     = ev.throttle or ev.engineThrottle or 0
            engineRunning = ev.engineRunning or -1
        end
    end)
    state.lastRpm           = rpm
    state.lastThrottle      = throttle
    state.lastEngineRunning = engineRunning

    -- Track whether engine was running (for stall fallback).
    if rpm >= cfg.stallWasRunningRpm then
        state.engineWasRunning = true
    end

    -- ── 4. PRIMARY: powertrain thermals flags ───────────────────────────────────
    local triggered = false
    local trigReason = ""
    pcall(function()
        local eng = powertrain.getDevice("mainEngine")
        triggered = eng and eng.isBroken == true

        -- Try the configured device name first.
        local dev = powertrain and powertrain.getDevice and
                    powertrain.getDevice(cfg.engineDeviceName)

        -- Fallback: iterate all devices and pick the first one with thermals.
        if not (dev and dev.thermals) and powertrain and powertrain.getDeviceNames then
            local names = powertrain.getDeviceNames()
            if names then
                for _, name in ipairs(names) do
                    local d = powertrain.getDevice(name)
                    if d and d.thermals then
                        dev = d
                        dbg("Using powertrain device '%s' (configured name '%s' had no thermals)",
                            name, cfg.engineDeviceName)
                        break
                    end
                end
            end
        end

        if dev and dev.thermals then
            local t = dev.thermals
            -- Store latest values for logging.
            state.lastHgb  = t.headGasketBlown             or false
            state.lastPrd  = t.pistonRingsDamaged           or false
            state.lastCrbd = t.connectingRodBearingsDamaged or false

            local reasons = {}
            if state.lastHgb  then table.insert(reasons, "headGasketBlown") end
            if state.lastPrd  then table.insert(reasons, "pistonRingsDamaged") end
            if state.lastCrbd then table.insert(reasons, "connectingRodBearingsDamaged") end
            if #reasons > 0 then
                triggered  = true
                trigReason = table.concat(reasons, "+")
            end
        else
            dbg("powertrain device '%s' not found or has no thermals table",
                cfg.engineDeviceName)
        end
    end)

    -- ── 5. SECONDARY FALLBACK: engine stall detection via electrics ────────────
    -- If thermals flags are not available (device missing / older vehicle jbeam),
    -- detect a catastrophic stall: engine was running above threshold and RPM
    -- has now dropped to zero while the engine is flagged as not running.
    if not triggered and state.engineWasRunning then
        local stallDetected = false
        if engineRunning == 0 and rpm < cfg.stallRpmThreshold then
            stallDetected = true
        elseif engineRunning == -1 and rpm < cfg.stallRpmThreshold then
            -- engineRunning field absent; use RPM alone.
            stallDetected = true
        end
        if stallDetected then
            triggered  = true
            trigReason = string.format("stall_fallback(rpm=%.0f engineRunning=%s)", rpm, tostring(engineRunning))
        end
    end

    -- ── 6. Periodic status log ─────────────────────────────────────────────────
    state.statusTimer = state.statusTimer + dt
    if cfg.debug and state.statusTimer >= cfg.statusLogInterval then
        state.statusTimer = 0
        dbg("Status | rpm=%.0f throttle=%.2f engineRunning=%s | hgb=%s prd=%s crbd=%s | wasRunning=%s triggered=%s",
            rpm, throttle, tostring(engineRunning),
            tostring(state.lastHgb), tostring(state.lastPrd), tostring(state.lastCrbd),
            tostring(state.engineWasRunning), tostring(triggered))
    end

    -- ── 7. Enter fire phase if triggered ───────────────────────────────────────
    if triggered then
        state.engineFire   = true
        state.explodeTimer = 0
        state.statusTimer  = 0
        info("ENGINE FAILURE DETECTED — reason: %s", trigReason)
        info("  rpm=%.0f throttle=%.2f engineRunning=%s", rpm, throttle, tostring(engineRunning))
        info("  thermals: headGasketBlown=%s pistonRingsDamaged=%s connectingRodBearingsDamaged=%s",
            tostring(state.lastHgb), tostring(state.lastPrd), tostring(state.lastCrbd))
        info("  Will ignite now, explode in %.1f s", cfg.explodeDelaySeconds)
        startFire()
    end
end

return M
