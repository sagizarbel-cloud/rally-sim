# Realistic Rally Simulation — Literature Compilation & Implementation Plan

**Goal:** A physics-based rally driving sim that runs natively on Apple Silicon, with vehicle dynamics grounded in published models and adapted from permissively-licensed open source — not invented.

**Provenance rule for this project:** every physics component maps to (a) a named published model and (b) a readable reference implementation. Coefficients come from cited datasets, not guesses. Where a value is a placeholder for tuning, it is labeled as such.

**Status:** planning. Verified sources in this doc were checked on the web (July 2026); links at the bottom. Standard textbooks are named as canonical references to acquire; they were not re-verified online this session.

---

## 1. The physics, and the model behind each piece

A realistic car sim is a rigid body (the chassis) with forces applied at four tire contact patches. The realism lives almost entirely in **how those tire forces are computed**. Component by component:

### 1.1 Tire force model — the crux
The industry-standard empirical model is the **Pacejka "Magic Formula"** (Hans Pacejka; originally funded by Volvo and Audi). It expresses a normalized force as a function of slip:

`y(x) = D · sin( C · arctan( B·x − E·(B·x − arctan(B·x)) ) )`  (+ horizontal/vertical shifts Sh, Sv)

- `x` = **slip ratio** (longitudinal) or **slip angle** (lateral)
- `B` stiffness, `C` shape, `D` peak (∝ friction × normal load), `E` curvature
- Produces the characteristic curve: grip rises with slip to a peak, then falls — the progressive break-away that makes a sim *feel* real instead of on/off.

**Inputs it needs each step:**
- **Slip ratio** `κ = (ω·r − v_long) / |v_long|` (wheel-spin vs ground speed)
- **Slip angle** `α = atan(v_lat / |v_long|)` (contact velocity vs tire heading)
- **Normal load** `Fz` (from suspension / weight transfer)
- **Combined slip:** longitudinal and lateral forces share one friction budget — combine via a **friction ellipse / traction circle** so you can't get full grip in both at once.

**Model progression I recommend (simple → full), matching what Chrono offers:**
1. **Brush / Fiala model** — few coefficients, physically-based, stable. Chrono's `Fiala` tire. Great for milestone 1: real slip behavior with minimal parameters to source.
2. **Pacejka MF (PAC2002 / "Pac02")** — the full empirical model; Chrono's **recommended** handling tire. This is milestone-2 realism.
3. **TMeasy** (Georg Rill) — handles nonlinear effects with easier-to-obtain parameters; a good alternative to full MF.

*Sources to follow:* Pacejka, *Tyre and Vehicle Dynamics*; Beckman's *Physics of Racing* (accessible derivation + how to combine long/lat forces); Chrono's `ChPacejkaTire` / `Fiala` / `TMeasy` implementations (BSD-3, readable C++).

### 1.2 Suspension & load transfer
Per-wheel **spring + damper** (Hooke force `−k·x`, damping `−c·ẋ`) sets each tire's normal load `Fz`. Longitudinal load transfer under accel/brake and lateral transfer in corners **continuously change `Fz`**, which changes grip per tire — this coupling is what makes weight-shift techniques (the Scandinavian flick, trail-braking) emerge naturally. *Source:* Gillespie, *Fundamentals of Vehicle Dynamics*; Milliken, *Race Car Vehicle Dynamics*.

### 1.3 Drivetrain
Chain: **engine torque curve** (torque vs RPM lookup) → **clutch** → **gearbox ratios** → **final drive** → **differentials** → wheel torque. RPM back-computed from wheel speed × ratios. Rally cars are **AWD**: model a **center diff** plus front/rear diffs (open / limited-slip / locked) — the diff behavior strongly shapes handling. *Source:* Gillespie; Chrono `powertrain`/`driveline` subsystems.

### 1.4 Rally-specific: surfaces + deformable terrain **(v1 POC — the differentiator)**
Two coupled parts:

**(a) Surface friction sets** — per-surface parameters (peak friction, curve shape) for **gravel / tarmac / snow / mud**. On hard surfaces (tarmac) this drives the Pacejka tire directly.

**(b) Deformable terrain** — the flagship POC. When a tire loads loose soil it **sinks, cuts a rut, and pushes up a berm**, and driving *into* that berm gives grip — the essence of rally. The grounded, real-time approach:

- **Soil Contact Model (SCM)** — developed at DLR (German Aerospace Center); a generalization of **Bekker-Wong** pressure-sinkage + **Janosi-Hanamoto** shear to arbitrary 3D contact patches. It explicitly models **sinkage, plastic yield, shear deformation, and bulldozing flow**. Terrain is an **implicit Cartesian grid deformed by vertical node deflection** (i.e. a heightfield you push down). **Verified real-time: ~1 ms/step** for a vehicle on a patch. Reference implementation is **Chrono's `SCMTerrain` (BSD-3)** — readable and portable.
- **Core equations to implement (all published, semi-empirical):**
  - **Bekker pressure–sinkage:** `p(z) = (k_c/b + k_φ) · z^n` — normal pressure `p` from sinkage `z`, wheel width `b`, soil moduli `k_c` (cohesive), `k_φ` (frictional), exponent `n`. This sets how deep the tire sinks under load.
  - **Janosi–Hanamoto shear:** shear stress from shear displacement `j`, giving **traction** (`τ = (c + p·tanφ)·(1 − e^(−j/K))`) — this is what makes digging in *produce* forward grip.
  - **Bulldozing / compaction resistance:** displaced soil ahead of the wheel = resistance + the berm.
- **Game-scoping (how it stays real-time):** maintain a **localized deformable heightfield patch around the car** (not the whole stage); deform nodes under contact, persist ruts within the patch, stream/reset outside it. Single vehicle → the ~1 ms/step figure holds with headroom in a 16 ms frame.
- **Blend model:** a per-cell "hardness" drives a blend between **Pacejka (hard/tarmac)** and **SCM terramechanics (soft/gravel/mud/snow)** so one car handles both surface types continuously.

*Sources:* Bekker, *Theory of Land Locomotion* / *Introduction to Terrain-Vehicle Systems*; J.Y. Wong, *Theory of Ground Vehicles* & *Terramechanics and Off-Road Vehicle Engineering*; the SCM papers (DLR / UW-Madison SBEL); Chrono `SCMTerrain`.

### 1.5 Force feedback (later)
Derived from the tire's **self-aligning torque** (Pacejka's `Mz` output). Comes almost for free once the MF tire model is in and a wheel is connected.

---

## 2. Verified open-source references (with license reality)

| Project | Use for | License | Notes |
|---|---|---|---|
| **Project Chrono / Chrono::Vehicle** | Reference tire models (**Pac89, Pac02, Fiala, TMeasy, LuGre, rigid**), driveline, terramechanics | **BSD-3 (permissive)** | Academic-grade C++; the gold standard to read & port equations from. Pac02 is its recommended handling tire; Fiala = brush model w/ few coefficients. |
| **Jolt Physics** | Rigid-body engine + `VehicleConstraint` base | **MIT (permissive)** | Default tire model is simple (Marco Monster linear curves) but exposes a **tire-force override callback** → drop in our Pacejka model. Native in Godot 4.4+. |
| **Godot Engine 4.4+** | Editor, rendering (native Metal), scene/asset pipeline | **MIT (permissive)** | Ships **Jolt as a native physics backend**. NOTE: its built-in `VehicleBody3D` docs explicitly say it "isn't designed to provide realistic physics" → **we build a custom vehicle on `RigidBody3D`/Jolt, not `VehicleBody3D`.** |
| **VDrift** | Reference reading only | **GPL v3 (copyleft)** | Complete open driving sim w/ Pacejka; great to learn from. **Don't copy code** unless the whole game goes GPL. |
| **Stunt Rally**, **TORCS/Speed Dreams** | Reference reading only (rally surfaces, stages) | **GPL (copyleft)** | Same caveat. |

**License strategy:** build on the **permissive** set (Godot + Jolt + Chrono-derived math) so you own the result. Treat GPL projects (VDrift, Stunt Rally, TORCS) as *study material*, never copy-paste.

---

## 3. Foundational literature

**Accessible / free (start here):**
- **Brian Beckman — *The Physics of Racing* (13-part series, free online).** Weight transfer, tire grip, the Magic Formula, and a solid method for combining longitudinal + lateral forces. Best on-ramp.
- **Marco Monster — *Car Physics for Games*.** The classic game-dev intro (capped-linear slip, 2D "bicycle" model). Good for structure; its 2D simplification is a known limitation for true 3D — don't stop here.

**Canonical textbooks (acquire for depth):**
- **Hans Pacejka — *Tyre and Vehicle Dynamics*** — the Magic Formula source.
- **Thomas Gillespie — *Fundamentals of Vehicle Dynamics* (SAE)** — suspension, load transfer, drivetrain.
- **Milliken & Milliken — *Race Car Vehicle Dynamics* (SAE)** — handling/tires bible.
- **Georg Rill — *Road Vehicle Dynamics: Fundamentals and Modeling*** — TMeasy tire model.
- **Rajesh Rajamani — *Vehicle Dynamics and Control*** — clean state-space formulations.

---

## 4. Tech stack decision

**Chosen: Godot 4.4+ (Jolt backend) + a custom rigid-body vehicle with a Pacejka/Fiala tire model.**

Why:
- **Native Apple-Silicon / Metal** — zero of the translation pain from the RBR effort; 60+ fps is free.
- **Permissive (MIT)** — you own the game.
- **Jolt** gives a fast, modern rigid-body base and a tire-override hook; **Godot** gives editor, rendering, input, and asset pipeline.
- We deliberately **avoid `VehicleBody3D`** (not sim-grade per its own docs) and implement the vehicle ourselves — which is the whole point of "realistic," and where the cited models go.

*Alternative if you want maximum physics rigor over art/tooling:* a standalone C++ sim directly on Chrono::Vehicle (BSD-3), rendered minimally. More rigorous, less game-friendly. Godot+Jolt is the better balance for an actual playable game.

---

## 5. Implementation plan (vertical-slice first)

Each milestone is a *drivable build*, not a subsystem in isolation. Deformable terrain is a **v1 POC pillar**, so it lands early (M3) to de-risk it, right after there's a vehicle to apply it to.

- **M0 — Skeleton.** Godot 4.4 project, Jolt backend enabled, a rigid-body chassis box on a flat plane, chase camera, keyboard+gamepad input, on-screen telemetry (speed, per-wheel load/slip/sinkage). *Deliverable: a box you can shove around with real rigid-body physics.*

- **M1 — Suspension + first real tires (hard ground).** Four raycast wheels with spring-damper suspension feeding `Fz`; implement the **Fiala/brush** tire (few coefficients, cited) for longitudinal+lateral force; basic engine force + brake, on a rigid plane. *Deliverable: a car that drives, leans, and loses grip believably.*

- **M2 — Full Pacejka + load transfer (hard ground).** Upgrade to **Pacejka MF (Pac02-style)**, combined-slip friction ellipse, proper lateral+longitudinal load transfer. Validate tire curves vs published plots. *Deliverable: it feels like a car on tarmac.*

- **M3 — Deformable terrain POC ⭐ (the flagship).** Heightfield grid + **Bekker-Wong pressure-sinkage** (tire sinks under load), **Janosi-Hanamoto shear** (grip from digging in), and **bulldozing** (ruts + berms), following **Chrono `SCMTerrain`** (BSD-3). Localized deformable patch around the car; persistent ruts within it. Blend hard-surface Pacejka ↔ soft-surface SCM by per-cell hardness. *Deliverable: drive across loose gravel/mud, leave ruts, get grip off the berm — the thing that proves the whole project.*

- **M4 — Drivetrain.** Engine torque curve, clutch, gearbox, **AWD center+front+rear diffs** (open/LSD). *Deliverable: gears, throttle character, AWD handling on both surfaces.*

- **M5 — Stage & game loop.** A real stage (terrain mesh + deformable patch streaming), start/finish, split timing, pace-note trigger system, HUD. *Deliverable: run a timed stage on deforming ground.*

- **M6 — Feel & polish.** Force-feedback from `Mz`, tuning pass, surface-set variety (gravel/tarmac/snow/mud), optional light damage, audio, controller mapping. *Deliverable: something worth replaying.*

**Risk note (M3):** deformable terrain is the highest-risk milestone — the real-time budget (~1 ms/step for a localized single-vehicle patch is documented, but persistent whole-stage deformation needs streaming/LOD) and the Pacejka↔SCM blend are the two things to prototype earliest. That's exactly why it's front-loaded as the POC.

Deferred / research-grade beyond v1: granular DEM soil (vs semi-empirical SCM), tire thermal/wear, soft-body damage, multi-vehicle deformable terrain.

---

## 6. Validation approach (keeps it honest)
- Plot each tire model's force-vs-slip curve and compare shape to published Pacejka/Fiala figures before trusting it in-sim.
- Seed vehicle parameters (mass, wheelbase, CG height, spring rates) from a **real rally car's published specs**, cited in the data file.
- Sanity checks: steady-state cornering radius vs speed, longitudinal accel vs available grip, weight-transfer magnitude — all have closed-form expectations from Gillespie to check against.

---

## 7. Decisions & open questions
- ✅ **Deformable terrain: IN for v1** as the flagship POC (M3), via SCM / Bekker-Wong (semi-empirical, real-time). Granular DEM is out of scope for v1.

Still to confirm:
1. **Engine:** Godot 4.4+/Jolt (recommended) vs the Chrono-native C++ route. *Note:* since deformable terrain is now central and Chrono has the reference `SCMTerrain`, a hybrid is worth weighing — Godot+Jolt for the game, porting SCM's math from Chrono's BSD-3 source. My recommendation stays Godot+Jolt.
2. **Content/art:** OK to prototype every milestone (incl. the deformable-terrain POC) with placeholder primitives? Real car/stage art is a separate track.
3. **License intent:** staying permissive (recommended) → we *read* GPL sims (VDrift/Stunt Rally) but port math only from permissive sources (Chrono BSD-3, Jolt MIT). Confirm.

---

## Sources (verified July 2026)
- Project Chrono (BSD-3, Chrono::Vehicle): https://github.com/projectchrono/chrono — tire models list: https://api.projectchrono.org/wheeled_tire.html — Pacejka class: https://api.projectchrono.org/classchrono_1_1vehicle_1_1_ch_pacejka_tire.html
- Jolt Physics (MIT) VehicleConstraint: https://jrouwe.github.io/JoltPhysics/class_vehicle_constraint.html — Pacejka discussion: https://github.com/jrouwe/JoltPhysics/discussions/1628
- Godot Jolt backend: https://docs.godotengine.org/en/stable/tutorials/physics/using_jolt_physics.html — VehicleBody3D (limitations): https://docs.godotengine.org/en/stable/classes/class_vehiclebody3d.html
- VDrift (GPL v3): https://github.com/VDrift/vdrift
- Brian Beckman, *The Physics of Racing*: https://www.miata.net/sport/Physics/
- Tire model overview: https://en.wikipedia.org/wiki/Tire_model
- Chrono terrain models (incl. SCM): https://api.projectchrono.org/vehicle_terrain.html
- SCM — "A soil contact model for multi-body system simulations": https://www.researchgate.net/publication/225003294_SCM-A_soil_contact_model_for_multi-body_system_simulations
- "Real-Time Simulation of Ground Vehicles on Deformable Terrain" (ASME J. Comput. Nonlinear Dynam.): https://asmedigitalcollection.asme.org/computationalnonlinear/article/18/8/081007/1156640
- "An Overview of the Chrono Soil Contact Model (SCM) Implementation": https://www.researchgate.net/publication/326922379_An_Overview_of_the_Chrono_Soil_Contact_Model_SCM_Implementation
