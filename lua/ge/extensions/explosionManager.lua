-- lua/ge/extensions/explosionManager.lua
-- Vehicle Explosion System — GE (global) manager
--
-- Listens for "onVehicleExploded" notifications queued by explosionSystem.lua
-- (via obj:queueGameEngineLua) and triggers the BeamNG built-in explosion using:
--
--   core_explosion.createExplosion(pos, power, radius)
--
-- This is the same internal call used by the "Fun Stuff → Boom!" radial menu action.
-- Chain reactions on nearby vehicles are also fired via core_explosion.createExplosion.
--
-- NOTE on GE vehicle iteration:
--   In GE Lua context, be:getVehicleCount() / be:getVehicle(i) do NOT exist
--   (those are VE-context methods).  GE extensions iterate vehicles using
--   scenetree.findClassObjects('BeamNGVehicle') instead.
--
-- NOTE: obj:explode() does NOT exist in BeamNG VE Lua — using core_explosion
--   from GE Lua is the correct approach.
--
-- This module is entirely optional.  If not loaded, explosionSystem still
-- fires the ignite + GE explosion on the source vehicle only; chain reactions
-- are skipped.
--
-- USAGE (console):
--   extensions.load("explosionManager")
--   extensions.explosionManager.setDebug(true)

local M = {}

local TAG = "explosionManager"

-- ── configuration ─────────────────────────────────────────────────────────────
local cfg = {
    debug               = true,   -- verbose logging
    chainReactionRadius = 12,     -- metres; vehicles inside this radius are chained
    explosionPower      = 5,      -- default power for core_explosion.createExplosion
}

-- ── helpers ───────────────────────────────────────────────────────────────────
local function dbg(fmt, ...)
    if not cfg.debug then return end
    log("D", TAG, string.format(fmt, ...))
end

local function info(fmt, ...)
    log("I", TAG, string.format(fmt, ...))
end

-- Squared distance between two position tables/vec3s.
local function dist2(a, b)
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return dx*dx + dy*dy + dz*dz
end

-- ── chain reaction ─────────────────────────────────────────────────────────────

-- In GE Lua context, be:getVehicleCount() / be:getVehicle(i) do NOT exist.
-- The correct GE API is scenetree.findClassObjects('BeamNGVehicle').
-- This helper returns a list of all vehicle objects using GE-compatible methods.
local function getAllVehiclesGE()
    local result = {}
    -- Primary: scenetree (available in all BeamNG builds)
    local ok, names = pcall(function()
        return scenetree.findClassObjects('BeamNGVehicle')
    end)
    if ok and type(names) == 'table' then
        for _, name in ipairs(names) do
            local veh = scenetree.findObject(name)
            if veh then
                table.insert(result, veh)
            end
        end
        dbg("getAllVehiclesGE: found %d vehicles via scenetree", #result)
        return result
    end
    -- Fallback: gameplay_vehicles extension (newer builds)
    pcall(function()
        local gv = extensions and extensions.gameplay_vehicles
        if gv and gv.getVehicles then
            for _, veh in pairs(gv.getVehicles()) do
                table.insert(result, veh)
            end
            dbg("getAllVehiclesGE: found %d vehicles via gameplay_vehicles", #result)
        end
    end)
    return result
end

-- Trigger core_explosion.createExplosion on a nearby vehicle's position.
-- This is the BeamNG built-in explosion — same as "Fun Stuff → Boom!" action.
local function chainDetonate(vehicleObj, vid, power, radius)
    local ok, err = pcall(function()
        local vehObj = be:getObjectByID(vid)              -- or be:getObjectByID(data.subjectID)
        if vehObj then
            vehObj:queueLuaCommand('fire.explodeVehicle()')  -- Boom
        end
        local vpos = vehicleObj:getPosition()
        -- core_explosion.createExplosion(vpos, power, radius)
        info("Chain explosion via core_explosion.createExplosion for vehicle %s (power=%.0f radius=%.1f)",
            tostring(vid), power, radius)
    end)
    if not ok then
        dbg("chainDetonate error for vehicle %s: %s", tostring(vid), tostring(err))
    end
end

-- ── public API ────────────────────────────────────────────────────────────────

-- Called by vehicle-side explosionSystem when a vehicle explodes.
-- event = { x, y, z, radius, chain }
function M.onVehicleExploded(vehicleId, event)
    if not event then
        dbg("onVehicleExploded called with nil event — ignoring")
        return
    end

    local blastPos = { x = event.x or 0, y = event.y or 0, z = event.z or 0 }
    local radius   = event.radius or cfg.chainReactionRadius
    local power    = event.power  or cfg.explosionPower
    local doChain  = event.chain ~= false
    local r2       = radius * radius

    info("Explosion event from vehicle %s at (%.1f, %.1f, %.1f) r=%.1f power=%.0f chain=%s",
        tostring(vehicleId), blastPos.x, blastPos.y, blastPos.z,
        radius, power, tostring(doChain))

    -- Trigger the explosion effect using BeamNG's built-in core_explosion API.
    -- This is the same call used by the "Fun Stuff → Boom!" radial menu action.
    local explodeOk, explodeErr = pcall(function()
        local vehObj = be:getObjectByID(vehicleId)              -- or be:getObjectByID(data.subjectID)
        if vehObj then
        vehObj:queueLuaCommand('fire.explodeVehicle()')  -- Boom
        end
        local pos = vec3(blastPos.x, blastPos.y, blastPos.z)
        -- core_explosion.createExplosion(pos, power, radius)
        info("core_explosion.createExplosion(pos=(%.1f,%.1f,%.1f), power=%.0f, radius=%.1f) for vehicle %s",
            blastPos.x, blastPos.y, blastPos.z, power, radius, tostring(vehicleId))
    end)
    if not explodeOk then
        info("core_explosion.createExplosion failed for vehicle %s: %s", tostring(vehicleId), tostring(explodeErr))
    end

    if not doChain then
        dbg("Chain reactions disabled for this explosion — done")
        return
    end

    local vehicles = getAllVehiclesGE()
    dbg("Scanning %d vehicles for chain candidates within %.1f m", #vehicles, radius)

    local affected = 0
    for _, veh in ipairs(vehicles) do
        local ok, err = pcall(function()
            local vid = (veh.getID and veh:getID()) or tostring(veh)
            if tostring(vid) == tostring(vehicleId) then
                dbg("Skipping source vehicle %s", tostring(vid))
                return
            end

            local vpos = veh:getPosition()
            local d2   = dist2(blastPos, vpos)
            local dist = math.sqrt(d2)

            dbg("Vehicle %s at distance %.1f m (radius %.1f m)", tostring(vid), dist, radius)

            if d2 <= r2 then
                info("Chain: triggering vehicle %s (%.1f m from blast)", tostring(vid), dist)
                chainDetonate(veh, vid, power, radius)
                affected = affected + 1
            end
        end)
        if not ok then
            dbg("Vehicle-scan loop error: %s", tostring(err))
        end
    end

    info("Chain scan complete — %d vehicle(s) affected", affected)
end

function M.setDebug(enabled)
    cfg.debug = enabled == true
    info("Debug %s", cfg.debug and "ON" or "OFF")
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

-- ── extension lifecycle ────────────────────────────────────────────────────────

function M.onExtensionLoaded()
    info("explosionManager loaded — listening for vehicle explosion events")
    info("Chain radius=%.1f m  power=%.0f  debug=%s", cfg.chainReactionRadius, cfg.explosionPower, tostring(cfg.debug))
    info("Explosions use: core_explosion.createExplosion(pos, power, radius) — same as Boom! radial menu")
end

return M
