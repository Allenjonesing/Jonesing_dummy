# Art Files — Structure & Manipulation Guide

This document explains what lives inside the `art/` folder and how it relates to the visual appearance of the Jonesing Dummy mod.

---

## art/groundModels/

The `art/groundModels/` directory contains **ground-material definitions** used by BeamNG.drive's physics and audio engine.
These files are **not** mesh or texture data — they define how surfaces _feel_ and _sound_ when objects slide or collide on them.

### flesh.json

```
art/groundModels/flesh.json
```

Defines the physical properties of the "flesh" ground model that is applied to the dummy's interior/organ surfaces.

| Property | Value | Meaning |
|---|---|---|
| `staticFriction` | 0.90 | High grip when stationary — body doesn't slide easily |
| `slidingFriction` | 0.75 | Moderate drag when sliding |
| `softnessCoef` | 0.6 | Soft, deformable contact |
| `spring` | 180000 | Medium-stiff contact spring |
| `damper` | 1800 | Contact damping (absorbs bounce) |
| `collisionType` | physical | Full rigid-body collision |
| `defaultBaseSoundName` | groundModel_mud | Wet/soft impact sounds |
| `defaultNodeSoundName` | groundModel_mud_scrape | Scrape/drag sounds |
| `skidmarkColorDecal` | blood_skid | Decal placed on the surface when dragged |

**To modify:** Edit the JSON values directly. The file is referenced by material meshes in the 3D models.

> **Note:** None of the files under `art/groundModels/` control _visual_ appearance. Textures and colors are stored under `vehicles/common/AgentY_Dummy/`.

---

## Where the Real Art Lives

All visual assets (textures, materials, 3D models) for the crash-test dummy are in:

```
vehicles/common/AgentY_Dummy/
```

See the [Reskinning Guide](#reskinning-guide) below for details.
