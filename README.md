# Rally Sim

A physics-based rally driving sim, native on Apple Silicon. Vehicle dynamics grounded in
published models (Pacejka tires, Bekker-Wong deformable terrain) and adapted from
permissively-licensed open source. See [docs/DESIGN.md](docs/DESIGN.md) for the full
literature compilation, model choices, license plan, and milestone roadmap.

## Status: M0 — Skeleton ✅

The first vertical slice: a rigid-body chassis you can drive on a flat plane, with a
chase camera, keyboard + gamepad input, and a telemetry HUD. **The drive in M0 is an
intentional placeholder** (force-based arcade proxy) whose only job is to prove the
engine + input + camera + HUD loop. The real vehicle model arrives in M1–M4.

## Requirements
- **Godot 4.4 or newer** (needed for the native Jolt physics backend). Free: https://godotengine.org/download
  - Apple-Silicon build runs natively on Metal — no translation layers.

## Run it
1. Install Godot 4.4+ (the standard, non-.NET build is fine).
2. Open Godot → **Import** → select `rally-sim/project.godot`.
3. Press **F5** (Play).
4. (Optional) Confirm the Jolt backend is active: **Project → Project Settings → Physics → 3D → Physics Engine** should read **Jolt Physics**. If it says "Godot Physics", the project still runs — just re-select Jolt.

## Controls
| Action | Keyboard | Gamepad |
|---|---|---|
| Throttle | W / ↑ | Right Trigger |
| Brake / Reverse | S / ↓ | Left Trigger |
| Steer | A / D or ← / → | Left Stick X |
| Reset car | R | Y |

## Project layout
```
rally-sim/
  project.godot          Godot config (Jolt backend, main scene)
  main.tscn              Minimal root scene -> scripts/world.gd
  scripts/
	world.gd             Bootstrap: builds input map, sky, ground, car, camera, HUD
	vehicle.gd           M0 placeholder rigid-body drive (replaced in M1)
	chase_camera.gd      Smoothed follow camera
	hud.gd               Telemetry overlay (M1/M3 rows stubbed)
  docs/
	DESIGN.md            Literature + models + license plan + roadmap
```

## What M0 proves
- Native Metal rendering + Jolt rigid-body physics on Apple Silicon.
- Input (keyboard + gamepad) → forces on a real rigid body.
- Camera, HUD, and reset loop.
- A clean structure with explicit extension points for the real physics.

## Next: M1 — Suspension + first real tires
Replace `vehicle.gd`'s placeholder drive with **4× raycast wheels**: spring-damper
suspension feeding per-tire normal load `Fz`, and a **Fiala/brush tire model** (few
coefficients, cited) for longitudinal + lateral force. The HUD's per-wheel row comes
alive here. Then M2 (Pacejka), M3 (deformable terrain POC), M4 (AWD drivetrain).
