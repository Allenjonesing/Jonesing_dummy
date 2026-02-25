# Jonesing Dummy Mod

Standalone crash-test dummies and GTA-style walking NPCs for BeamNG.drive.

---

## Spawning dummies via hotkey

The mod adds two user-assignable actions that appear in BeamNG's **Controls** settings:

| Action | Default binding | Description |
|--------|----------------|-------------|
| **Spawn Ped Dummies** | *(unbound)* | Spawns a row of `agenty_dummy` props ahead of the player vehicle |
| **Despawn / Clear Dummies** | *(unbound)* | Removes all dummies spawned through the hotkey |

Both actions have **no default key** — you must bind them yourself so they never conflict with existing bindings.

### How to bind the hotkeys in BeamNG Controls

1. Launch BeamNG.drive and load any map.
2. Open **Options** → **Controls** (or press **Escape → Options → Controls**).
3. In the search box at the top type **"Jonesing"** (or browse to the **Jonesing Dummy Mod** category).
4. Click the empty binding next to **Spawn Ped Dummies** and press the key you want (e.g. `F7`).
5. Click the empty binding next to **Despawn / Clear Dummies** and press your chosen key (e.g. `F8`).
6. Click **Save** and close Options.

### How it works

* `settings/inputmaps/jonesingDummyMod.json` registers the two action names and their display strings so they appear in BeamNG's Controls UI.
* `lua/ge/extensions/gameplay/jonesingDummySpawner.lua` is a GE-side extension that receives `onInputAction` events and calls `core_vehicles.spawnNewVehicle("agenty_dummy", ...)` with the `Normal` config — the same vehicle used when spawning dummies through other means.
* A **500 ms cooldown** prevents accidental repeat-spawns while holding the key.
* Spawned IDs are tracked so **Despawn / Clear Dummies** can remove exactly the dummies this session created.

### Tuning spawn parameters

Open `lua/ge/extensions/gameplay/jonesingDummySpawner.lua` and adjust the constants near the top:

```lua
local SPAWN_COUNT  = 3      -- how many dummies per key press
local SPAWN_CONFIG = "Normal"  -- which .pc config to use (Normal, Ragdoll, Female, …)
local SPAWN_SPACING = 1.5   -- metres between dummies in the row
local SPAWN_FORWARD = 4.0   -- metres ahead of the player to place the row
local COOLDOWN      = 0.5   -- minimum seconds between key activations
```

Available configs (from `vehicles/agenty_dummy/`):

| Config | Description |
|--------|-------------|
| `Normal` | Standard standing dummy |
| `Ragdoll` | Floppy ragdoll |
| `Female` | Female body model |
| `Sitting` | Pre-posed seated |
| `Small` | Child-scale dummy |
| `Unbreakable` | Won't break apart on impact |

---

## In-game verification / testing

1. Bind **Spawn Ped Dummies** (e.g. `F7`) and **Despawn / Clear Dummies** (e.g. `F8`) in Controls.
2. Start **Free Roam** on any map.
3. Press `F7` — you should see 3 dummies spawn ~4 m ahead of your vehicle.  
   Check the **Lua console** (`` ` `` key → open Lua console) for log lines:
   ```
   [I] jonesingDummySpawner: spawning 3 ped dummy(s) ahead of player
   [I] jonesingDummySpawner: spawned agenty_dummy id=…
   ```
4. Press `F7` again within 500 ms — nothing should happen (cooldown).
5. Press `F8` — all 3 dummies should vanish and the console should show:
   ```
   [I] jonesingDummySpawner: despawning 3 tracked ped dummy(s)
   ```

---

## File map

```
lua/
  controller/
    agentyDummyPositioner.lua   — positions seated dummies inside cars
    jonesingGtaNpc.lua          — GTA-style walking NPC controller
  ge/
    extensions/
      gameplay/
        jonesingDummySpawner.lua  ← NEW: hotkey input handler & spawner

settings/
  inputmaps/
    jonesingDummyMod.json         ← NEW: registers actions in Controls UI

vehicles/
  agenty_dummy/                   — vehicle model & .pc configs for the prop dummy
```
