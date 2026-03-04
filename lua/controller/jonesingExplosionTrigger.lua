-- jonesingExplosionTrigger.lua
-- Standalone explosion mod controller.
-- Attached to the ".Jonesing explosion mod" license plate slot on any vehicle.
--
-- When the plate is equipped this controller:
--   1. Loads explosionSystem (VE context) — monitors engine thermals and
--      triggers obj:ignite() + notifies GE when engine failure is detected.
--   2. Loads explosionManager (GE context) — receives the notification and
--      calls core_explosion.createExplosion(pos, power, radius), which is the
--      BeamNG built-in explosion used by "Fun Stuff → Boom!" in the radial menu.
--
-- No pedestrians or traffic are spawned by this controller.

local M = {}


-- ── jbeam lifecycle callbacks ─────────────────────────────────────────────────

local function init(jbeamData)
    -- Load the vehicle-side explosion monitor (VE context).
    extensions.load("explosionSystem")

    -- Load the GE-side explosion trigger (GE context).  Idempotent if already loaded.
    obj:queueGameEngineLua("extensions.load('explosionManager')")
end


local function reset()
    -- explosionSystem handles its own state reset via onReset().
end


-- ── public interface ──────────────────────────────────────────────────────────
M.init  = init
M.reset = reset

return M
