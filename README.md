# Rally Sim

A physics-based rally driving sim, native on Apple Silicon. Vehicle dynamics grounded in
published models (Pacejka tires, Bekker-Wong deformable terrain) and adapted from
permissively-licensed open source. **[docs/ROADMAP.md](docs/ROADMAP.md) is the authoritative
living state** — milestones, decisions and working patterns; [docs/DESIGN.md](docs/DESIGN.md)
holds the original literature compilation, model choices and license plan.

## Status: M0–M10 complete ✅ — drivetrain & suspension arc in progress

The car (`scripts/vehicle_m2.gd`) is a rigid body on four raycast wheels, with:

- **Combined-slip Pacejka tires** — slip ratio and slip angle resolved through a friction
  ellipse, with load-sensitive grip and longitudinal stiffness derived per surface (tarmac
  peaks at low slip, gravel much later).
- **A real driveline** — the engine is its own rotating inertia: it free-revs in neutral,
  bogs when lugged, and can stall. A stick-slip clutch couples it to a manual 6-speed
  (R–N–1..6). Engine braking is emergent (motoring friction grows with rpm), and downshifts
  rev-match on request.
- **Selectable differentials** — open / viscous / Salisbury clutch-pack / locked per axle,
  with separate power and coast ramps, plus a speed-sensing centre coupling for AWD.
- **Consumables and damage** — per-tire temperature, wear and punctures fold into grip;
  hard impacts cost power, grip and steering trim until repaired.

Around it: three concentric circuits (dirt rally loop, asphalt ring, centre skid pad) plus a
drag strip; a wear line that darkens the driven racing line and changes its grip; deformable
terrain on the centre patch; time-trial ghosts with sector splits; a co-driver calling
procedurally detected pace notes through the OS text-to-speech; and a live tuning panel over
the physical parameters.

## Requirements
- **Godot 4.4 or newer** (needed for the native Jolt physics backend). Free: https://godotengine.org/download
  - Apple-Silicon build runs natively on Metal — no translation layers.

## Run it
1. Install Godot 4.4+ (the standard, non-.NET build is fine).
2. Open Godot → **Import** → select `rally-sim/project.godot`.
3. Press **F5** (Play).
4. (Optional) Confirm the Jolt backend is active: **Project → Project Settings → Physics → 3D → Physics Engine** should read **Jolt Physics**. If it says "Godot Physics", the project still runs — just re-select Jolt.

## Controls

Gamepad layout follows the Assetto Corsa rally convention (pedals on the triggers, gearbox on
the shoulders, handbrake on the south face button). Button names below are **DualShock 4**;
on an Xbox pad read Cross/Circle/Square/Triangle as A/B/X/Y.

**Driving**

| Action | Keyboard | Gamepad |
|---|---|---|
| Throttle | W / ↑ | R2 |
| Brake | S / ↓ | L2 |
| Steer | A / D or ← / → | Left stick |
| Shift up | E | R1 |
| Shift down (R–N–1..6) | Q | L1 |
| Clutch (hold) | Left Shift | Square |
| Handbrake | Space | Cross |
| Ignition / starter | I | Circle |

**Setup & views**

| Action | Keyboard | Gamepad |
|---|---|---|
| Drive mode AWD/RWD/FWD | T | Share |
| Diff preset open/viscous/rally | 1 / 2 / 3 | Touchpad click (cycles) |
| Tuning panel | Tab | Options |
| Camera | C | Triangle |
| Circuit | B | D-pad left |
| Time of day | L | D-pad right |
| HUD size | − / + | D-pad up/down |
| Reset car | R | R3 (right stick click) |

Analog triggers bypass the virtual-pedal input shaping (which exists to make binary keys
behave like a foot), so a gamepad gives direct pedal travel. The HUD's `input` line names the
detected pad — if it reads `no gamepad detected`, Godot isn't seeing the controller.

## Project layout
```
rally-sim/
  project.godot          Godot config (Jolt backend, 120 Hz physics tick, main scene)
  main.tscn              Minimal root scene -> scripts/world.gd
  check.sh               Headless compile gate; must print "Godot check clean"
  scripts/
    world.gd             Bootstrap: input map, sky + time of day, stage, car, cameras, HUDs
    vehicle_m2.gd        The car: tires, driveline, differentials, consumables, damage
    stage.gd             Procedural stage: 3 circuits + drag strip, per-surface grip
    terrain.gd           GPU height-displaced deformable dirt (centre patch)
    wear.gd              Racing-line surface wear -> visual trail + grip
    time_trial.gd        Lap timing, ghosts and sector splits, per circuit
    pace_notes.gd        Corner detection from road curvature, spoken via OS TTS
    sound.gd             Engine drone pitched by rpm, surface-aware tire audio
    hud.gd               Telemetry overlay
    component_hud.gd     Car schematic: tire temps/wear, engine temp, damage
    tuning_panel.gd      Live tuning sliders (Tab)
    chase_camera.gd      Smoothed follow camera
    vehicle.gd           M0 placeholder drive — superseded, kept for reference
    course.gd            Flat test course — superseded by stage.gd, kept for reference
  docs/
    ROADMAP.md           Authoritative living state: milestones, decisions, patterns
    PLAN-drivetrain-suspension.md
                         Active phased plan: drivetrain arc, then suspension arc
    DESIGN.md            Literature compilation, model choices, license plan
```

## How it's built
- **Everything procedural** — the stage, the car's geometry and the UI are built in code;
  `main.tscn` is a near-empty root. No scene editing for gameplay.
- **Functions over constants** — behaviour comes from physical models with physically
  meaningful tunables (N·m, Hz, damping ratio, ramp fractions), not tuned magic numbers.
- **Verified headless** — `./check.sh` loads the whole project without a window and fails on
  any script error. Feel is verified the only way it can be: by driving it.

## Where it's going next
The active work is [docs/PLAN-drivetrain-suspension.md](docs/PLAN-drivetrain-suspension.md), a
phased deepening of driving feel: the **drivetrain arc** (engine and clutch, engine braking,
differentials, shift model, handbrake) followed by the **suspension arc** (setup derived from
ride frequency and damping ratio, asymmetric digressive dampers, bump stops, tire relaxation
length). Each phase ends at a driving checklist — nothing is called done on a clean compile
alone. Remaining milestones beyond it live in `docs/ROADMAP.md`: dust and smoke, rivals and
medals, aero downforce and self-aligning torque, force feedback, replay and photo mode.
