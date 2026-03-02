-- lua/ge/extensions/explosionManager.lua
-- Vehicle Explosion System — GE (global) manager
--
-- Listens for "vehicle exploded" notifications sent by explosionSystem.lua
-- and applies radial impulse + optional chain-reaction damage to nearby vehicles.
--
-- This module is entirely optional.  If it is not loaded, explosionSystem.lua
-- still explodes the source vehicle locally.
--
-- USAGE (console):
--   extensions.load("explosionManager")
--   extensions.explosionManager.setDebug(true)

local M = {}

local TAG = "explosionManager"

-- ── configuration ─────────────────────────────────────────────────────────────
local cfg = {
    debug               = false,
    chainReactionDamage = 40,    -- hp deducted from nearby vehicles' explosionHealth
    radialImpulseForce  = 80000, -- Newton·s applied to nearby vehicle nodes
    minProximityRadius  = 1.0,   -- vehicles closer than this (m) always affected
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

-- ── radial impulse ─────────────────────────────────────────────────────────────
local function applyRadialImpulse(vehicleObj, blastPos, radius)
    local ok, err = pcall(function()
        if not (vehicleObj and vehicleObj.queueLuaCommand) then return end

        -- Queue a Lua command on the target vehicle that reads its own node
        -- data and applies an outward impulse.  We pass the blast position
        -- as literal numbers so the closure is self-contained.
        local bx, by, bz = blastPos.x, blastPos.y, blastPos.z
        local force = cfg.radialImpulseForce
        local r2    = radius * radius

        local cmd = string.format([[
local bx, by, bz = %f, %f, %f
local force, r2 = %f, %f
if not (v and v.data and v.data.nodes) then return end
local nodeCount = 0
for _, _ in pairs(v.data.nodes) do nodeCount = nodeCount + 1 end
if nodeCount == 0 then return end
local impulse = force / nodeCount
for _, n in pairs(v.data.nodes) do
    local p  = obj:getNodePosition(n.cid)
    local dx = p.x - bx
    local dy = p.y - by
    local dz = p.z - bz + 0.3
    local d2 = dx*dx + dy*dy + dz*dz
    if d2 <= r2 then
        local falloff = 1.0 - math.sqrt(d2) / math.sqrt(r2)
        local len = math.sqrt(dx*dx + dy*dy + dz*dz)
        if len < 0.01 then len = 0.01 end
        local ix = (dx / len) * impulse * falloff
        local iy = (dy / len) * impulse * falloff
        local iz = (dz / len) * impulse * falloff
        if obj.addNodeForce then
            obj:addNodeForce(n.cid, ix, iy, iz)
        end
    end
end
        ]], bx, by, bz, force, r2)

        vehicleObj:queueLuaCommand(cmd)
    end)
    if not ok then dbg("applyRadialImpulse error: %s", tostring(err)) end
end

-- ── chain reaction damage ──────────────────────────────────────────────────────
local function applyChainDamage(vehicleObj, damage)
    -- Tell the target vehicle's explosionSystem extension to take damage.
    local ok, err = pcall(function()
        if not (vehicleObj and vehicleObj.queueLuaCommand) then return end
        local cmd = string.format([[
local ext = extensions and extensions.explosionSystem
if ext and ext._chainDamage then
    pcall(ext._chainDamage, %f)
end
        ]], damage)
        vehicleObj:queueLuaCommand(cmd)
    end)
    if not ok then dbg("applyChainDamage error: %s", tostring(err)) end
end

-- ── public API ────────────────────────────────────────────────────────────────

-- Called by vehicle-side explosionSystem when a vehicle explodes.
-- event = { x, y, z, radius, chain }
function M.onVehicleExploded(vehicleId, event)
    if not event then return end

    local blastPos = { x = event.x or 0, y = event.y or 0, z = event.z or 0 }
    local radius   = event.radius or 12
    local doChain  = event.chain ~= false

    info("Blast from vehicle %s at (%.1f, %.1f, %.1f) r=%.1f chain=%s",
        tostring(vehicleId), blastPos.x, blastPos.y, blastPos.z,
        radius, tostring(doChain))

    local r2      = radius * radius
    local count   = be and be:getVehicleCount() or 0

    for i = 0, count - 1 do
        local ok, err = pcall(function()
            local veh = be:getVehicle(i)
            if not veh then return end

            local vid = (veh.getID and veh:getID()) or nil
            if vid == vehicleId then return end  -- skip the exploding vehicle itself

            local vpos = veh:getPosition()
            local d2   = dist2(blastPos, vpos)
            if d2 <= r2 then
                dbg("Affecting nearby vehicle %s (d=%.1f m)", tostring(vid),
                    math.sqrt(d2))
                applyRadialImpulse(veh, blastPos, radius)
                if doChain then
                    applyChainDamage(veh, cfg.chainReactionDamage)
                end
            end
        end)
        if not ok then dbg("Vehicle loop error: %s", tostring(err)) end
    end
end

function M.setDebug(enabled)
    cfg.debug = enabled == true
    info("Debug %s", cfg.debug and "ON" or "OFF")
end

function M.configure(overrides)
    if type(overrides) ~= "table" then return end
    for k, v in pairs(overrides) do
        if cfg[k] ~= nil then cfg[k] = v end
    end
    info("Config updated")
end

-- ── extension lifecycle ────────────────────────────────────────────────────────

function M.onExtensionLoaded()
    info("Loaded — waiting for vehicle explosion events.")
    info("Console: extensions.explosionManager.setDebug(true)")
end

return M
