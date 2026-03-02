-- lua/vehicle/extensions/explosionSystem.lua
-- Vehicle Explosion System — Jonesing mod
--
-- Standalone extension that gives any vehicle a destructible "explosion health"
-- bar.  When health reaches zero (from collisions, beam breaks, or engine/
-- electrics damage) the vehicle explodes once: parts detach, an impulse is
-- applied, fire/smoke starts, a sound plays, and a GE event is fired so the
-- optional explosionManager can apply chain-reaction damage to nearby vehicles.
--
-- USAGE (console):
--   extensions.load("explosionSystem")       -- load on current vehicle
--   extensions.explosionSystem.detonate()    -- manual trigger
--   extensions.explosionSystem.getStatus()   -- print current health / state
--
-- CONFIG OVERRIDES (per vehicle, in jbeam or via console):
--   extensions.explosionSystem.configure({ debug = true, startHealth = 50 })

local M = {}

-- ── default configuration ────────────────────────────────────────────────────
local cfg = {
    enabled                 = true,   -- master on/off switch
    debug                   = true,  -- verbose logging
    startHealth             = 1,    -- initial explosion health (0–100)
    armDelaySeconds         = 3,      -- seconds after init before arming
    collisionDamageScale    = 1.0,    -- multiplier on collision damage
    minCollisionSpeed       = 1,      -- m/s — slower impacts are ignored
    engineDamageThreshold   = 0.1,    -- engine damage fraction that deals 20 hp
    electricsDamagePerTick  = 0.5,    -- hp lost per second when electrics fail
    explodeOnFuelLeak       = false,  -- trigger on detected fuel leak
    explosionImpulse        = 600000,  -- Newton·s applied to vehicle nodes
    explosionRadius         = 120,     -- metres — sent to explosionManager
    chainReaction           = true,   -- allow manager to chain to nearby vehicles
    fireDurationSeconds     = 10,
    soundPath               = nil,    -- optional OGG path; nil = use built-in
}

-- ── state ────────────────────────────────────────────────────────────────────
local state = {
    health          = 1,
    exploded        = false,
    armed           = true,
    armTimer        = 0,
    lastDamageEvent = "none",
    lastDamageAmt   = 0,
    engineWasDamaged = false,
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

local function warn(fmt, ...)
    log("W", TAG, string.format(fmt, ...))
end

-- Clamp a value into [lo, hi].
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Apply hp damage and log the source; returns new health.
local function applyDamage(amount, source)
    if state.exploded or not state.armed then return state.health end
    amount = math.max(0, amount)
    if amount <= 0 then return state.health end
    state.health = clamp(state.health - amount, 0, cfg.startHealth)
    state.lastDamageEvent = source or "unknown"
    state.lastDamageAmt   = amount
    dbg("Damage %.1f from [%s] → health %.1f", amount, source, state.health)
    return state.health
end

-- ── explosion effects (all wrapped in pcall so missing APIs don't crash) ─────

local function breakParts()
    -- Try to break all known breakgroups to scatter parts.
    local ok, err = pcall(function()
        if v and v.data and v.data.breakGroupLinks then
            for name, _ in pairs(v.data.breakGroupLinks) do
                if obj.breakBreakGroup then
                    obj:breakBreakGroup(name)
                end
            end
        end
    end)
    if not ok then dbg("breakParts error: %s", tostring(err)) end
end

local function applyBlastImpulse()
    -- Scatter nodes outward from vehicle centre with random impulse.
    local ok, err = pcall(function()
        if not (v and v.data and v.data.nodes) then return end
        local nodeCount = 0
        for _, _ in pairs(v.data.nodes) do nodeCount = nodeCount + 1 end
        if nodeCount == 0 then return end

        -- Compute rough centroid.
        local cx, cy, cz = 0, 0, 0
        for _, n in pairs(v.data.nodes) do
            local p = obj:getNodePosition(n.cid)
            cx = cx + p.x; cy = cy + p.y; cz = cz + p.z
        end
        cx = cx / nodeCount; cy = cy / nodeCount; cz = cz / nodeCount

        -- Apply outward impulse per node.
        local impulsePerNode = cfg.explosionImpulse / nodeCount
        for _, n in pairs(v.data.nodes) do
            local p = obj:getNodePosition(n.cid)
            local dx = p.x - cx
            local dy = p.y - cy
            local dz = p.z - cz + 0.3  -- bias upward
            local len = math.sqrt(dx*dx + dy*dy + dz*dz)
            if len < 0.01 then len = 0.01 end
            local ix = (dx / len) * impulsePerNode
            local iy = (dy / len) * impulsePerNode
            local iz = (dz / len) * impulsePerNode
            if obj.addNodeForce then
                obj:addNodeForce(n.cid, ix, iy, iz)
            end
        end
    end)
    if not ok then dbg("applyBlastImpulse error: %s", tostring(err)) end
end

local function startFire()
    -- Use built-in vehicle fire API if available; graceful no-op otherwise.
    local ok, err = pcall(function()
        if obj.ignite then
            obj:ignite()
            dbg("Vehicle ignited via obj:ignite()")
            return
        end
        -- Some builds expose a fire controller via electrics.
        if electrics and electrics.values and electrics.values.isOnFire ~= nil then
            electrics.values.isOnFire = 1
            dbg("Fire set via electrics.values.isOnFire")
        end
    end)
    if not ok then dbg("startFire error: %s", tostring(err)) end
end

local function playExplosionSound()
    -- Prefer a custom OGG if configured; fall back to built-in crash sound.
    local ok, err = pcall(function()
        if cfg.soundPath then
            if obj.playSoundOnce then
                obj:playSoundOnce(cfg.soundPath)
                dbg("Played custom sound: %s", cfg.soundPath)
                return
            end
        end
        -- Built-in: trigger the vehicle's existing damage/crash sound event.
        if sounds and sounds.playSoundOnceFollowObject then
            sounds.playSoundOnceFollowObject("event:>Vehicle>Damage>explosion", obj)
            dbg("Played built-in explosion sound via sounds API")
            return
        end
        if obj.playSound then
            obj:playSound("explosion")
            dbg("Played built-in explosion sound via obj:playSound")
        end
    end)
    if not ok then dbg("playExplosionSound error: %s", tostring(err)) end
end

-- ── GE notification ──────────────────────────────────────────────────────────

local function notifyManager()
    -- Send event to explosionManager (if loaded) so it can apply chain damage.
    local ok, err = pcall(function()
        local mgr = extensions and extensions.explosionManager
        if mgr and mgr.onVehicleExploded then
            local pos = obj:getPosition()
            mgr.onVehicleExploded(obj:getId(), {
                x      = pos.x, y = pos.y, z = pos.z,
                radius = cfg.explosionRadius,
                chain  = cfg.chainReaction,
            })
            dbg("Notified explosionManager")
        end
    end)
    if not ok then dbg("notifyManager error: %s", tostring(err)) end
end

-- ── core explode routine ─────────────────────────────────────────────────────

local function doExplode(reason)
    if state.exploded then return end  -- fire only once
    state.exploded = true

    info("EXPLODING — reason: %s (health was %.1f)", reason or "unknown", state.health)

    breakParts()
    applyBlastImpulse()
    startFire()
    playExplosionSound()
    notifyManager()
end

local function checkHealth(reason)
    if state.health <= 0 and not state.exploded then
        doExplode(reason or "health depleted")
    end
end

-- ── public API ───────────────────────────────────────────────────────────────

-- Manual detonation (console: extensions.explosionSystem.detonate())
function M.detonate()
    if state.exploded then
        info("Already exploded; ignoring detonate()")
        return
    end
    state.health = 0
    doExplode("manual detonate")
end

-- Chain-reaction damage entry point (called by explosionManager on nearby vehicles).
-- Bypasses arming delay so chain explosions propagate even on fresh vehicles.
function M._chainDamage(amount)
    if not cfg.enabled or state.exploded then return end
    state.health = clamp(state.health - (amount or 0), 0, cfg.startHealth)
    dbg("Chain damage %.1f → health %.1f", amount or 0, state.health)
    if state.health <= 0 then
        doExplode("chain_reaction")
    end
end

-- Override config at runtime (console: extensions.explosionSystem.configure({...}))
function M.configure(overrides)
    if type(overrides) ~= "table" then return end
    for k, v in pairs(overrides) do
        if cfg[k] ~= nil then
            cfg[k] = v
        end
    end
    info("Config updated")
end

-- Status dump (console: extensions.explosionSystem.getStatus())
function M.getStatus()
    info("health=%.1f exploded=%s armed=%s lastEvent=%s lastDmg=%.1f",
        state.health, tostring(state.exploded), tostring(state.armed),
        state.lastDamageEvent, state.lastDamageAmt)
end

-- ── extension lifecycle ──────────────────────────────────────────────────────

function M.init(jbeamData)
    -- Allow per-vehicle jbeam overrides.
    if type(jbeamData) == "table" then
        for k, _ in pairs(cfg) do
            if jbeamData[k] ~= nil then
                cfg[k] = jbeamData[k]
            end
        end
    end

    -- Reset state.
    state.health           = cfg.startHealth
    state.exploded         = false
    state.armed            = false
    state.armTimer         = 0
    state.lastDamageEvent  = "none"
    state.lastDamageAmt    = 0
    state.engineWasDamaged = false

    if not cfg.enabled then
        dbg("explosionSystem disabled by config")
        return
    end

    dbg("init — startHealth=%d armDelay=%.1fs debug=%s",
        cfg.startHealth, cfg.armDelaySeconds, tostring(cfg.debug))
end

function M.onReset()
    -- Vehicle reset (teleport, quick-reset): re-arm cleanly.
    state.health           = cfg.startHealth
    state.exploded         = false
    state.armed            = false
    state.armTimer         = 0
    state.lastDamageEvent  = "none"
    state.lastDamageAmt    = 0
    state.engineWasDamaged = false
    dbg("onReset — health restored")
end

-- ── per-frame update (arming timer + electrics/fuel damage) ─────────────────

function M.updateGFX(dt)
    if not cfg.enabled or state.exploded then return end

    -- Arming countdown.
    if not state.armed then
        state.armTimer = state.armTimer + dt
        if state.armTimer >= cfg.armDelaySeconds then
            state.armed = true
            dbg("Armed (%.1f s elapsed)", state.armTimer)
        end
        return  -- don't process damage until armed
    end

    -- Electrics damage: if battery/electrical energy is depleted, drain health slowly.
    local ok = pcall(function()
        local ev = electrics and electrics.values
        if ev then
            -- Use electricalEnergy or batteryVoltage as a reliable indicator of
            -- electrical system failure (works on all vehicle types).
            local energy  = ev.electricalEnergy  or ev.electricalenergy
            local voltage = ev.batteryVoltage     or ev.battery_voltage
            local failed  = false
            if energy  ~= nil and energy  <= 0 then failed = true end
            if voltage ~= nil and voltage <= 0 then failed = true end
            if failed then
                applyDamage(cfg.electricsDamagePerTick * dt, "electrics_failure")
            end
        end
    end)
    if not ok then dbg("electrics check error") end

    -- Engine damage threshold: if engine is severely damaged, take a one-time hit.
    local ok2 = pcall(function()
        if powertrain then
            local dmg = powertrain.getEngineDamage and powertrain.getEngineDamage() or 0
            if dmg >= cfg.engineDamageThreshold and not state.engineWasDamaged then
                state.engineWasDamaged = true
                applyDamage(20, "engine_critical")
                dbg("Engine critical damage registered (%.2f)", dmg)
            end
        end
    end)
    if not ok2 then dbg("powertrain check error") end

    -- Fuel leak: optional trigger.
    if cfg.explodeOnFuelLeak then
        local ok3 = pcall(function()
            local ev = electrics and electrics.values
            if ev and ev.fuel_leak and ev.fuel_leak > 0 then
                doExplode("fuel_leak")
            end
        end)
        if not ok3 then dbg("fuel_leak check error") end
    end

    checkHealth("updateGFX")
end

-- ── collision callback ────────────────────────────────────────────────────────

function M.onCollision(data)
    if not cfg.enabled or state.exploded or not state.armed then return end

    local ok, err = pcall(function()
        -- data.speed is relative collision speed in m/s.
        local speed = (data and data.speed) or 0
        if speed < cfg.minCollisionSpeed then return end

        -- Damage scales quadratically with speed (realistic energy model).
        local rawDmg  = (speed * speed) / 100.0
        local damage  = rawDmg * cfg.collisionDamageScale

        applyDamage(damage, string.format("collision_%.1fms", speed))
        checkHealth("collision")
    end)
    if not ok then dbg("onCollision error: %s", tostring(err)) end
end

-- ── beam break callback ───────────────────────────────────────────────────────

function M.onBeamBroken(id, energy)
    if not cfg.enabled or state.exploded or not state.armed then return end

    local ok, err = pcall(function()
        -- Each high-energy beam break deals 1–5 hp depending on energy.
        local dmg = clamp((energy or 0) / 5000, 1, 5)
        applyDamage(dmg, string.format("beam_break_%d", id or 0))
        checkHealth("beam_break")
    end)
    if not ok then dbg("onBeamBroken error: %s", tostring(err)) end
end

return M
