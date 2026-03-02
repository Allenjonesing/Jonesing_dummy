-- lua/ge/extensions/explosionManager.lua
-- Vehicle Explosion System — GE (global) manager
--
-- Listens for "onVehicleExploded" notifications queued by explosionSystem.lua
-- (via obj:queueGameEngineLua) and triggers chain explosions on nearby vehicles
-- using the SAME path as the radial-menu "Fun Stuff → Boom!" action:
--
--   be:getVehicle(id):queueLuaCommand("obj:explode()")
--
-- BOOM! IMPLEMENTATION NOTES:
--   The freeroam radial menu "Boom!" button triggers vehicle explosion by
--   queuing  obj:explode()  in the target vehicle's VE Lua context.
--   In GE Lua the call is:  be:getVehicle(id):queueLuaCommand("obj:explode()")
--   This manager uses that exact path so chain-reaction explosions are
--   identical to a player clicking Boom! on each nearby vehicle.
--
-- This module is entirely optional.  If not loaded, explosionSystem still
-- explodes the source vehicle; only chain reactions are skipped.
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

-- Queue obj:explode() on a nearby vehicle — same path as Boom! radial menu.
-- This is the SAME call the "Fun Stuff → Boom!" button ultimately issues.
local function chainDetonate(vehicleObj, vid)
    local ok, err = pcall(function()
        if not (vehicleObj and vehicleObj.queueLuaCommand) then
            dbg("chain: vehicle %s has no queueLuaCommand — skipping", tostring(vid))
            return
        end
        -- Trigger the built-in Boom! explosion in the target vehicle's VE context.
        -- obj:explode() is what the radial menu "Fun Stuff → Boom!" ultimately calls.
        vehicleObj:queueLuaCommand("obj:explode()")
        info("Chain Boom! queued for vehicle %s via queueLuaCommand('obj:explode()')", tostring(vid))
    end)
    if not ok then
        dbg("chainDetonate pcall error for vehicle %s: %s", tostring(vid), tostring(err))
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
    local doChain  = event.chain ~= false
    local r2       = radius * radius

    info("Explosion event from vehicle %s at (%.1f, %.1f, %.1f) r=%.1f chain=%s",
        tostring(vehicleId), blastPos.x, blastPos.y, blastPos.z,
        radius, tostring(doChain))

    if not doChain then
        dbg("Chain reactions disabled for this explosion — done")
        return
    end

    local count = be and be:getVehicleCount() or 0
    dbg("Scanning %d vehicles for chain candidates within %.1f m", count, radius)

    local affected = 0
    for i = 0, count - 1 do
        local ok, err = pcall(function()
            local veh = be:getVehicle(i)
            if not veh then return end

            local vid = (veh.getID and veh:getID()) or tostring(i)
            if vid == vehicleId then
                dbg("Skipping source vehicle %s", tostring(vid))
                return
            end

            local vpos = veh:getPosition()
            local d2   = dist2(blastPos, vpos)
            local dist = math.sqrt(d2)

            dbg("Vehicle %s at distance %.1f m (radius %.1f m)", tostring(vid), dist, radius)

            if d2 <= r2 then
                info("Chain: triggering vehicle %s (%.1f m from blast)", tostring(vid), dist)
                chainDetonate(veh, vid)
                affected = affected + 1
            end
        end)
        if not ok then
            dbg("Vehicle-scan loop error at index %d: %s", i, tostring(err))
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
    info("Chain radius=%.1f m  debug=%s", cfg.chainReactionRadius, tostring(cfg.debug))
    info("Chain explosions use: be:getVehicle(id):queueLuaCommand('obj:explode()') — same as Boom! radial menu")
end

return M
