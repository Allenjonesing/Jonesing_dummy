-- lua/ge/extensions/jonesingPolicePursuitDetector.lua
-- Detects when BeamNG's native police/traffic system is actively pursuing the
-- player, using the real traffic extension APIs rather than speculative hook names.
--
-- Detection strategy (highest → lowest priority):
--   1. gameplay_police.getPursuitData() — post-v0.32 pursuit gameplay wrapper.
--   2. traffic.getTraffic() polling — iterate every traffic vehicle, look for
--      police roles whose action is "chase" (or similar) and whose target is the
--      player vehicle.
--   3. Real GE hooks fired by the traffic/police role system when they exist:
--         onTrafficAction(vehId, newAction, prevAction)
--         onPoliceAction(vehId, newAction)
--         onVehicleRoleChanged(vehId, newRole, prevRole)
--      These hooks set an internal flag and are combined with the poll result.
--   4. Scenetree proximity scan as a last-resort fallback (only when the
--      traffic extension is absent entirely).
--
-- Usage from jonesingPoliceManager:
--   local det = extensions.jonesingPolicePursuitDetector
--   det.update(playerVehId)          -- call each update tick
--   det.isPlayerBeingPursued()       -- true when a cop is chasing the player
--   det.getPursuingOfficerIds()      -- set { [vehId]=true, ... }
--   det.getTrafficPoliceCount()      -- count of police in the traffic system

local M = {}
local TAG = "jonesingPolicePursuitDetector"

local function logD(msg, ...) log("D", TAG, string.format(msg, ...)) end
local function logI(msg, ...) log("I", TAG, string.format(msg, ...)) end

-- ---------------------------------------------------------------------------
-- Internal state
-- ---------------------------------------------------------------------------
local _pursuitActive      = false
local _pursuingOfficers   = {}   -- { [numericVehId] = true }
local _trafficPoliceCount = 0    -- police vehicles known to the traffic system
local _hookFired          = false  -- set by real GE hooks when they fire

-- Set of action strings (lower-case) that indicate active pursuit.
local CHASE_ACTIONS = {
    chase        = true,
    chasing      = true,
    pursuing     = true,
    pursuit      = true,
    intercept    = true,
    intercepting = true,
}

-- ---------------------------------------------------------------------------
-- Helper: get the player vehicle's numeric ID safely
-- ---------------------------------------------------------------------------
local function _getPlayerVehId(explicitId)
    if explicitId then return explicitId end
    if not be then return nil end
    local ok, v = pcall(function() return be:getPlayerVehicle(0) end)
    if not ok or not v then return nil end
    local ok2, id = pcall(function()
        if v.getId   then return v:getId() end
        if v.getID   then return v:getID() end
        return nil
    end)
    if ok2 and id then return tonumber(id) end
    return nil
end

-- ---------------------------------------------------------------------------
-- Helper: read a traffic vehicle's police role action string (or nil)
-- Tries every known field path defensively; BeamNG field names vary by version.
-- ---------------------------------------------------------------------------
local function _getPoliceRoleAction(tv)
    -- Path A: role.data.action  (most common in v0.28–v0.36)
    local ok, v = pcall(function()
        return tv.role and tv.role.data and tv.role.data.action
    end)
    if ok and type(v) == "string" then return v:lower() end

    -- Path B: role.state  (alternate naming in some builds)
    ok, v = pcall(function()
        return tv.role and tv.role.state
    end)
    if ok and type(v) == "string" then return v:lower() end

    -- Path C: role.currentAction
    ok, v = pcall(function()
        return tv.role and tv.role.currentAction
    end)
    if ok and type(v) == "string" then return v:lower() end

    -- Path D: role.actionId
    ok, v = pcall(function()
        return tv.role and tv.role.actionId
    end)
    if ok and type(v) == "string" then return v:lower() end

    return nil
end

-- ---------------------------------------------------------------------------
-- Helper: get the suspect/target vehicle ID that a police vehicle is chasing
-- ---------------------------------------------------------------------------
local function _getPoliceTarget(tv)
    -- Path A: role.target.id  (v0.28+)
    local ok, v = pcall(function()
        return tv.role and tv.role.target and tv.role.target.id
    end)
    if ok and v then return tonumber(v) end

    -- Path B: role.data.target.id
    ok, v = pcall(function()
        return tv.role and tv.role.data and
               tv.role.data.target and tv.role.data.target.id
    end)
    if ok and v then return tonumber(v) end

    -- Path C: role.suspectId
    ok, v = pcall(function()
        return tv.role and tv.role.suspectId
    end)
    if ok and v then return tonumber(v) end

    -- Path D: role.data.suspectId
    ok, v = pcall(function()
        return tv.role and tv.role.data and tv.role.data.suspectId
    end)
    if ok and v then return tonumber(v) end

    return nil
end

-- ---------------------------------------------------------------------------
-- Helper: determine whether a traffic vehicle is a police unit.
-- Checks role name first, then jbeam model name as fallback.
-- ---------------------------------------------------------------------------
local function _isPoliceTrafficVeh(tv)
    -- Role name check (fastest path)
    local ok, rn = pcall(function()
        return tv.role and (tv.role.roleName or tv.role.name)
    end)
    if ok and type(rn) == "string" and rn:lower():find("police") then
        return true
    end
    -- roleName may be a direct field on the traffic vehicle object
    ok, rn = pcall(function() return tv.roleName end)
    if ok and type(rn) == "string" and rn:lower():find("police") then
        return true
    end
    -- Jbeam model name fallback via traffic vehicle's veh object
    ok, rn = pcall(function()
        if not tv.veh then return nil end
        return tv.veh:getField("jbeam", "")
    end)
    if ok and type(rn) == "string" and rn:lower():find("police") then
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Method 1: gameplay_police.getPursuitData()  (post-v0.32)
-- Returns true and fills _pursuingOfficers if pursuit active.
-- ---------------------------------------------------------------------------
local function _checkGameplayPolice(playerVehId)
    local gp = gameplay_police
    if not gp then return false end

    -- Try getPursuitData()
    local ok, data = pcall(function()
        if gp.getPursuitData then return gp.getPursuitData() end
        if gp.getActivePursuit then return gp.getActivePursuit() end
        return nil
    end)
    if not ok or not data or type(data) ~= "table" then return false end

    -- data may be { heat=n, suspects={...}, officers={...} }
    -- or { suspect=id, officers={...} }
    local isSuspect = false
    if playerVehId then
        if data.suspects and data.suspects[playerVehId] then
            isSuspect = true
        elseif data.suspect and tonumber(data.suspect) == playerVehId then
            isSuspect = true
        end
    end
    -- If there's any active pursuit data, treat the player as suspect unless
    -- explicit suspect info says otherwise.
    if not isSuspect and data.officers and next(data.officers) then
        -- Some versions don't record the suspect id; trust any active pursuit.
        isSuspect = true
    end
    if not isSuspect then return false end

    -- Record the pursuing officers
    if data.officers then
        for id, _ in pairs(data.officers) do
            _pursuingOfficers[tonumber(id)] = true
        end
    end
    local officerCount = 0
    for _ in pairs(_pursuingOfficers) do officerCount = officerCount + 1 end
    logD("gameplay_police: pursuit active; filled %d officers", officerCount)
    return true
end

-- ---------------------------------------------------------------------------
-- Method 2: traffic.getTraffic() polling
-- ---------------------------------------------------------------------------
local function _checkTrafficPolling(playerVehId)
    if not traffic then return false end
    local ok, tvehicles = pcall(function()
        if traffic.getTraffic        then return traffic.getTraffic() end
        if traffic.activeVehicles    then return traffic.activeVehicles end
        if traffic.getActiveVehicles then return traffic.getActiveVehicles() end
        return nil
    end)
    if not ok or not tvehicles or type(tvehicles) ~= "table" then return false end

    local found = false
    local count = 0
    for id, tv in pairs(tvehicles) do
        if type(tv) == "table" and _isPoliceTrafficVeh(tv) then
            count = count + 1
            local action = _getPoliceRoleAction(tv)
            local target = _getPoliceTarget(tv)
            local chasing = (action and CHASE_ACTIONS[action]) or
                            (playerVehId and target == playerVehId)
            if chasing then
                _pursuingOfficers[tonumber(id)] = true
                found = true
            end
        end
    end
    _trafficPoliceCount = count
    return found
end

-- ---------------------------------------------------------------------------
-- Proximity fallback — only used when the traffic extension is absent.
-- Radius is kept tight to avoid false-positives from parked police cars.
-- ---------------------------------------------------------------------------
local PROXIMITY_RADIUS    = 80
local PROXIMITY_RADIUS_SQ = PROXIMITY_RADIUS * PROXIMITY_RADIUS

local function _checkProximity(playerVehId)
    if not scenetree or not be then return false end
    if not playerVehId then return false end

    local playerVeh = be:getObjectByID(playerVehId)
    if not playerVeh then return false end
    local ok, ppos = pcall(function() return playerVeh:getPosition() end)
    if not ok or not ppos then return false end

    local ok2, names = pcall(function()
        return scenetree.findClassObjects("BeamNGVehicle")
    end)
    if not ok2 or not names then return false end

    local found = false
    for _, name in ipairs(names) do
        pcall(function()
            local obj = scenetree.findObject(name)
            if not obj then return end
            local ok3, jbeam = pcall(function() return obj:getField("jbeam", "") end)
            if not ok3 or type(jbeam) ~= "string" then return end
            if not jbeam:lower():find("police") then return end
            local ok4, opos = pcall(function() return obj:getPosition() end)
            if not ok4 or not opos then return end
            local dx = opos.x - ppos.x
            local dy = opos.y - ppos.y
            if dx*dx + dy*dy < PROXIMITY_RADIUS_SQ then
                local ok5, vid = pcall(function() return obj:getID() end)
                if ok5 and vid and tonumber(vid) ~= playerVehId then
                    _pursuingOfficers[tonumber(vid)] = true
                    found = true
                end
            end
        end)
    end
    return found
end

-- ---------------------------------------------------------------------------
-- Public: update() — call once per manager tick with the player vehicle ID.
-- Returns (pursuitActive, pursuingOfficers, trafficPoliceCount).
-- ---------------------------------------------------------------------------
function M.update(playerVehId)
    _pursuingOfficers   = {}
    _trafficPoliceCount = 0

    playerVehId = _getPlayerVehId(playerVehId)

    local found = false

    -- Priority 1: gameplay_police wrapper
    if not found then found = _checkGameplayPolice(playerVehId) end

    -- Priority 2: traffic.getTraffic() polling
    if not found then found = _checkTrafficPolling(playerVehId) end

    -- Priority 3: hook-fired flag (set by real GE hooks below)
    if not found and _hookFired then found = true end

    -- Priority 4: proximity scan (only when traffic system absent)
    if not found and not traffic and not gameplay_police then
        found = _checkProximity(playerVehId)
    end

    _pursuitActive = found
    return _pursuitActive, _pursuingOfficers, _trafficPoliceCount
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
function M.isPlayerBeingPursued()   return _pursuitActive end
function M.getPursuingOfficerIds()  return _pursuingOfficers end
function M.getTrafficPoliceCount()  return _trafficPoliceCount end

-- Reset the hook-fired flag (call when wanted level is cleared)
function M.resetHookFlag() _hookFired = false end

-- ---------------------------------------------------------------------------
-- Real BeamNG GE hooks fired by the traffic / police role system.
-- These may or may not exist depending on the BeamNG version.
-- Registering them costs nothing when they don't fire.
-- ---------------------------------------------------------------------------

-- Fired by traffic.lua when any traffic vehicle changes action.
-- Signature varies: (vehId, newAction) or (vehId, newAction, prevAction)
function M.onTrafficAction(vehId, newAction, prevAction)
    if not newAction then return end
    local act = tostring(newAction):lower()
    if CHASE_ACTIONS[act] then
        logD("onTrafficAction: vehicle %s → %s (chase detected)", tostring(vehId), act)
        _hookFired = true
    end
end

-- Alternate hook name used in some BeamNG builds
function M.onPoliceAction(vehId, newAction)
    M.onTrafficAction(vehId, newAction)
end

-- Fired when a vehicle's role changes (e.g. basic → police chase)
function M.onVehicleRoleChanged(vehId, newRole, prevRole)
    if type(newRole) == "string" and newRole:lower():find("chase") then
        logD("onVehicleRoleChanged: vehicle %s → %s", tostring(vehId), newRole)
        _hookFired = true
    end
end

-- Fired by gameplay_police when pursuit state changes
function M.onPolicePursuitChanged(data)
    if type(data) == "table" and data.active then
        logD("onPolicePursuitChanged: active=true")
        _hookFired = true
    elseif type(data) == "table" and data.active == false then
        _hookFired = false
    end
end

-- Alternate name seen in some versions
function M.onPoliceChaseStarted(data)
    logD("onPoliceChaseStarted fired")
    _hookFired = true
end

function M.onPoliceChaseEnded(data)
    logD("onPoliceChaseEnded fired – clearing hook flag")
    _hookFired = false
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function M.onExtensionLoaded()
    _pursuitActive    = false
    _pursuingOfficers = {}
    _hookFired        = false
    logI("Jonesing Pursuit Detector loaded. "
        .. "traffic=%s  gameplay_police=%s",
        tostring(traffic ~= nil), tostring(gameplay_police ~= nil))
end

return M
