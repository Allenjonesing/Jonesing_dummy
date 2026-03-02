-- lua/ge/extensions/jonesingPoliceEvents.lua
-- Optional event-normalizer adapter for jonesingPoliceManager.
-- Detects which BeamNG hook names are available at runtime and provides a
-- consistent interface so the manager never has to hard-code version-specific
-- event names.  All functions fail gracefully when systems are absent.

local M = {}
local TAG = "jonesingPoliceEvents"

local function logD(msg, ...)
    log("D", TAG, string.format(msg, ...))
end
local function logW(msg, ...)
    log("W", TAG, string.format(msg, ...))
end

local function lerp(a, b, t) return a + (b - a) * t end

-- ---------------------------------------------------------------------------
-- Runtime capability flags (populated in M.detect())
-- ---------------------------------------------------------------------------
M.caps = {
    hasTraffic          = false, -- global `traffic` table exists
    hasTrafficUtils     = false, -- gameplay_traffic_trafficUtils accessible
    hasPolicePursuit    = false, -- traffic.requestPursuit or equivalent
    hasVehicleDamageEvt = false, -- onVehicleTakenDamage GE hook is wired
    hasAiSetMode        = false, -- vehicle.ai.setMode exists
}

-- ---------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------
function M.detect()
    M.caps.hasTraffic = (traffic ~= nil)

    M.caps.hasTrafficUtils =
        (gameplay_traffic_trafficUtils ~= nil) and
        (type(gameplay_traffic_trafficUtils.findSafeSpawnPoint) == "function")

    -- Pursuit API: try several known names
    M.caps.hasPolicePursuit =
        M.caps.hasTraffic and (
            type(traffic.requestPursuit)      == "function" or
            type(traffic.setPursuitTarget)    == "function" or
            type(traffic.startPursuit)        == "function"
        )

    -- Damage event: we cannot reliably pre-check without registering, so we
    -- mark it as "unknown" and let the manager discover it on first fire.
    -- The manager uses a polling fallback so this is safe.
    M.caps.hasVehicleDamageEvt = false  -- updated lazily if hook fires

    -- AI mode: test against a dummy nil vehicle (won't crash)
    M.caps.hasAiSetMode = false -- populated when we first touch a vehicle ai

    logD("Detection complete: traffic=%s trafficUtils=%s pursuit=%s",
        tostring(M.caps.hasTraffic),
        tostring(M.caps.hasTrafficUtils),
        tostring(M.caps.hasPolicePursuit))

    return M.caps
end

-- ---------------------------------------------------------------------------
-- Safe wrappers around traffic spawning helpers
-- ---------------------------------------------------------------------------

-- Returns {pos=vec3, rot=quat} near the player, or nil.
function M.findSpawnPose(playerPos, playerDir, minDist, maxDist)
    if not M.caps.hasTrafficUtils then return nil end

    local ok, result = pcall(function()
        local targetDist = math.min(minDist * 2, lerp(minDist, maxDist, 0.5))
        local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(
            playerPos, playerDir, minDist, maxDist, targetDist, {})
        if not spawnData then return nil end

        local vecUp = vec3(0, 0, 1)
        local vecY  = vec3(0, 1, 0)
        local newPos, newDir =
            gameplay_traffic_trafficUtils.finalizeSpawnPoint(
                spawnData.pos, spawnData.dir,
                spawnData.n1,  spawnData.n2,
                { legalDirection = true })
        if not newPos or not newDir then return nil end

        local normal = map.surfaceNormal(newPos, 1) or vecUp
        local rot = quatFromDir(vecY:rotated(quatFromDir(newDir, normal)), normal)
        return { pos = newPos, rot = rot }
    end)
    if ok then return result end
    logW("findSpawnPose error: %s", tostring(result))
    return nil
end

-- ---------------------------------------------------------------------------
-- Safe AI pursuit helpers
-- ---------------------------------------------------------------------------

-- Build the in-vehicle AI Lua command string for GTA-like pursuit.
-- aggression 0..1: 0 = polite traffic, 1 = full GTA ramming.
local function _buildPursuitCmd(targetVehId, aggression)
    aggression = aggression or 1.0
    -- At aggression >= 0.6 cops ignore lane discipline and drive at any speed.
    -- At aggression >= 0.85 they also activate ramming / no-traffic-respect flags.
    local lines = {
        'if ai then',
        '  ai.setMode("chase")',
        string.format("  ai.setTargetObjectID(%d)", targetVehId),
        string.format("  ai.setAggression(%.2f)", aggression),
    }
    if aggression >= 0.6 then
        -- Ignore lane markings – drive off-road straight at the target
        table.insert(lines, "  if ai.driveInLane   then ai.driveInLane(false) end")
        -- Remove the speed cap so cops can go as fast as physics allows
        table.insert(lines, "  if ai.setSpeedMode  then ai.setSpeedMode('limit', 999) end")
    end
    if aggression >= 0.85 then
        -- Treat other vehicles as obstacles to ram through, not avoid
        table.insert(lines, "  if ai.setAvoidCars  then ai.setAvoidCars(false) end")
        -- Some BeamNG builds expose direct flags
        table.insert(lines, "  if ai.setParameters then ai.setParameters({avoidCars=false, aggressive=true}) end")
    end
    table.insert(lines, "end")
    return table.concat(lines, "\n")
end

-- Try to make a vehicle AI pursue a target vehicle id.
-- Returns true if any method succeeded.
function M.assignPursuit(policeVehId, targetVehId, aggression)
    if not policeVehId or not targetVehId then return false end
    aggression = aggression or 1.0

    -- Method 1: traffic high-level pursuit API
    if M.caps.hasPolicePursuit then
        local ok = pcall(function()
            if traffic.requestPursuit then
                traffic.requestPursuit(policeVehId, targetVehId, aggression)
            elseif traffic.setPursuitTarget then
                traffic.setPursuitTarget(policeVehId, targetVehId)
            elseif traffic.startPursuit then
                traffic.startPursuit(policeVehId, targetVehId)
            end
        end)
        if ok then
            -- Also queue the direct AI command so aggression/speed flags apply
            local veh = be and be:getObjectByID(policeVehId)
            if veh then
                pcall(function()
                    veh:queueLuaCommand(_buildPursuitCmd(targetVehId, aggression))
                end)
            end
            return true
        end
    end

    -- Method 2: direct vehicle AI commands (primary fallback)
    local veh = be and be:getObjectByID(policeVehId)
    if not veh then return false end

    local ok2 = pcall(function()
        veh:queueLuaCommand(_buildPursuitCmd(targetVehId, aggression))
    end)
    if ok2 then
        M.caps.hasAiSetMode = true
        logD("assignPursuit: queued GTA-mode chase on vehicle %d (aggression=%.2f)",
            policeVehId, aggression)
        return true
    end

    -- Method 3: last resort – basic traffic mode so at least it drives
    pcall(function()
        veh:queueLuaCommand('if ai then ai.setMode("traffic") end')
    end)
    logD("assignPursuit: fell back to traffic mode for vehicle %d", policeVehId)
    return false
end

-- ---------------------------------------------------------------------------
-- Damage event stub
-- ---------------------------------------------------------------------------
-- Called by the manager's onVehicleTakenDamage hook (if it exists) OR polled.
-- Returns a normalised damage delta (0 if unknown).
function M.normaliseDamageDelta(vid, data)
    if not data then return 0 end
    -- Some BeamNG builds pass a number directly; others pass a table.
    if type(data) == "number" then return data end
    if type(data) == "table" then
        return data.damage or data.delta or data.value or 0
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function M.onExtensionLoaded()
    M.detect()
    logD("Event normalizer ready.")
end

return M
