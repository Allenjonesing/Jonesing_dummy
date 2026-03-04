🚷Jonesing Pedestrians

Jonesing Pedestrians is a BeamNG.drive mod that adds spawnable, moving pedestrian crash-test dummies to the world — building toward a more immersive sandbox experience.

📦 Repository Contents

This repository contains:
The latest Jonesing_Pedestrians.zip mod file
Source and controller adjustments used to build the mod
Packed releases ready for manual installation
The .zip file in this repo is the packaged mod and can be used directly in BeamNG.

🚗 Installing (Sideloading)

If the official BeamNG repository version is pending approval or not yet updated, you can manually install the mod:
Download the latest Jonesing_Pedestrians.zip from this repo.
Move the file into your BeamNG mods folder:
/BeamNG.drive/mods/
Launch BeamNG.drive
Ensure the mod is enabled in the in-game mod manager.
No extraction is required — BeamNG reads the .zip directly.

🌐 Official BeamNG Repository Page

The mod is also published on the official BeamNG repository:
https://www.beamng.com/resources/crash-test-dummy-pedestrian-traffic.36089/
Once approved, the repository version may be the easiest way to stay updated.

⚠️ Notes

Do not rename the .zip file once installed.
Keep file names consistent to avoid update warnings.
This repository may contain newer builds than the official repo while approval is pending.

---

## 💥 Vehicle Explosion System

A standalone, future-proof GTA-style explosion system that can make any vehicle explode when damage thresholds are reached — without modifying any BeamNG core files.

### What it does

- Tracks an "explosion health" value (0–100) on each vehicle.
- Decrements health from collisions, beam breaks, engine damage, and electrics failures.
- When health reaches 0 (or on a manual trigger), the vehicle explodes once:
  - Parts detach / breakgroups fire.
  - An outward impulse scatters the vehicle.
  - Fire/smoke starts (built-in ignite API with fallbacks).
  - An explosion sound plays.
- An arming delay (default 3 s) prevents explosions on spawn or teleport.
- An optional GE manager (explosionManager) applies radial impulse and chain-reaction damage to nearby vehicles.
- All effect APIs are called with pcall — missing APIs produce a warning, not a crash.

### File locations

```
lua/vehicle/extensions/explosionSystem.lua   ← vehicle-side extension
lua/ge/extensions/explosionManager.lua       ← optional global chain-reaction manager
```

### How to load

Open the BeamNG in-game Lua console and run:

```lua
-- Load on the current (player) vehicle:
extensions.load("explosionSystem")

-- Load the global chain-reaction manager (optional):
extensions.load("explosionManager")
```

### How to enable debug logging

```lua
extensions.explosionSystem.configure({ debug = true })
-- or at init time via jbeam: "explosionSystem_debug": true
```

Debug mode prints:
- Current explosionHealth after every damage event.
- The damage source and amount.
- The reason the explosion was triggered.

### How to test

1. Spawn any car on any map.
2. Open the Lua console (`~` key).
3. Load the extension: `extensions.load("explosionSystem")`
4. Wait 3 seconds for the arming delay to expire.
5. Trigger a manual detonation: `extensions.explosionSystem.detonate()`
   — the vehicle should scatter parts, catch fire, and play a sound.

To test crash-triggered explosion:
1. Load the extension as above.
2. Drive the vehicle into a wall at speed — repeated hard impacts drain health to 0.
3. Watch the console for `[explosionSystem] Damage … → health …` messages.

### How to override config for a specific vehicle

Pass a table to configure() at runtime:

```lua
extensions.explosionSystem.configure({
    startHealth             = 50,    -- easier to explode
    armDelaySeconds         = 1,
    collisionDamageScale    = 2.0,
    minCollisionSpeed       = 2,
    explosionImpulse        = 80000,
    explosionRadius         = 20,
    chainReaction           = true,
    debug                   = true,
})
```

Or add matching keys to a vehicle's jbeam slot data (prefix: `explosionSystem_`).

### Check current status

```lua
extensions.explosionSystem.getStatus()
-- prints: health=…  exploded=…  armed=…  lastEvent=…  lastDmg=…
```

### Simple test plan (5 steps)

| Step | Action | Expected result |
|------|--------|-----------------|
| 1 | Load extension: `extensions.load("explosionSystem")` | Console prints "init — startHealth=100 …" |
| 2 | Wait 3 s and call `extensions.explosionSystem.getStatus()` | armed=true, health=100 |
| 3 | Call `extensions.explosionSystem.detonate()` | Vehicle explodes (parts fly, fire starts) |
| 4 | Reset vehicle (Ctrl+R), wait 3 s, then crash into a wall at > 30 m/s twice | Health drains to 0, explosion triggers automatically |
| 5 | Load manager and explode: `extensions.load("explosionManager"); extensions.explosionSystem.detonate()` | Nearby parked vehicles receive an outward impulse |
