-- lua/ge/extensions/jonesing/plateText.lua
--
-- Dynamic license-plate text manager for the Jonesing mod.
--
-- Usage (from GE Lua console or another extension):
--   extensions.load('jonesing_plateText')
--   jonesing_plateText.setPlayerPlate("Jonesing")
--
-- The module automatically re-applies the configured plate text whenever:
--   • the player's vehicle is reset / respawned  (onVehicleResetted)
--   • the player switches to a different vehicle  (onPlayerVehicleChanged)
--   • a vehicle's part configuration changes      (onVehiclePartsChanged)
--
-- NOTE: This module only controls the *text overlay* rendered on top of the
-- existing plate mesh.  The plate mesh / flexbody defined in the vehicle JBeam
-- is intentionally left untouched.

local M = {}

local TAG         = "jonesing_plateText"
local _plateText  = "Jonesing"   -- default text applied on load

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function d(level, msg, ...)
    if select('#', ...) > 0 then msg = string.format(msg, ...) end
    log(level, TAG, msg)
end

--- Safely obtain the numeric ID of the current player vehicle.
--- Returns nil (with a warning) if no vehicle is available.
local function getPlayerVehicleId()
    -- be:getPlayerVehicleID is available on most modern BeamNG builds.
    if be and be.getPlayerVehicleID then
        local ok, id = pcall(function() return be:getPlayerVehicleID(0) end)
        if ok and id then return id end
    end
    -- Fallback: derive ID from the vehicle object itself.
    if be and be.getPlayerVehicle then
        local veh = be:getPlayerVehicle(0)
        if veh then
            if veh.getId then
                local ok, id = pcall(function() return veh:getId() end)
                if ok and id then return id end
            end
            -- Some builds expose .id as a plain field.
            if veh.id then return veh.id end
        end
    end
    d("W", "getPlayerVehicleId: no player vehicle found.")
    return nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Apply `text` as the plate text on the current player vehicle.
--- Stores the text so it can be re-applied automatically on future events.
---
--- @param text string  The plate string to display (e.g. "Jonesing").
function M.setPlayerPlate(text)
    if type(text) ~= "string" or text == "" then
        d("W", "setPlayerPlate: invalid text argument (%s)", tostring(text))
        return
    end

    _plateText = text

    local vehId = getPlayerVehicleId()
    if not vehId then return end   -- warning already logged by helper

    if not (core_vehicles and core_vehicles.setPlateText) then
        d("W", "setPlayerPlate: core_vehicles.setPlateText unavailable.")
        return
    end

    d("I", "Applying plate text '%s' to vehicle id=%s", text, tostring(vehId))
    core_vehicles.setPlateText(text, vehId)
end

--- Return the plate text that is currently configured.
function M.getPlateText()
    return _plateText
end

-- ── Event hooks ───────────────────────────────────────────────────────────────

--- Re-apply after a vehicle is reset / respawned (Insert / I key).
--- Signature: onVehicleResetted(vehicleId)
function M.onVehicleResetted(vehicleId)
    d("D", "onVehicleResetted(vehId=%s) — re-applying plate '%s'",
      tostring(vehicleId), _plateText)
    M.setPlayerPlate(_plateText)
end

--- Re-apply after the player enters a different vehicle (Tab key / scripted switch).
--- Signature: onPlayerVehicleChanged(playerIndex, newVehicleId, oldVehicleId)
function M.onPlayerVehicleChanged(playerIndex, newVehicleId, oldVehicleId)
    d("D", "onPlayerVehicleChanged(player=%s, new=%s, old=%s) — re-applying plate '%s'",
      tostring(playerIndex), tostring(newVehicleId), tostring(oldVehicleId),
      _plateText)
    M.setPlayerPlate(_plateText)
end

--- Re-apply when parts are reconfigured (covers selecting a new plate design).
--- Signature: onVehiclePartsChanged(vehicleId)
function M.onVehiclePartsChanged(vehicleId)
    d("D", "onVehiclePartsChanged(vehId=%s) — re-applying plate '%s'",
      tostring(vehicleId), _plateText)
    M.setPlayerPlate(_plateText)
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function M.onExtensionLoaded()
    d("I", "Loaded. Default plate text = '%s'. Applying to player vehicle now.",
      _plateText)
    -- Apply immediately so the text is set as soon as the mod is loaded.
    M.setPlayerPlate(_plateText)
end

return M
