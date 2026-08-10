# PLAN — Drivetrain & Differentials, then Suspension & Weight Transfer

_Written 2026-08-02 by the planning agent (Fable). Executor: Opus, phase by phase, fresh
context per session. This document is self-contained: read it top to bottom, then execute
ONE phase per session, in order. Do not skip the feel checkpoints — the user is the only
feel-verification instrument this project has._

---

## 0. How to work in this repo (read first)

- Project: `/Users/sgyzrbl/rally-sim` — Godot 4.4 + Jolt, native M1, everything built
  procedurally in code (no `.tscn` editing for gameplay). Read `CLAUDE.md` and
  `docs/ROADMAP.md` before starting any phase.
- **Compile gate after every edit:** run `./check.sh` from the project root. It must print
  `✅ Godot check clean`. This only proves the code loads — it says NOTHING about feel.
- **Feel gate:** every phase below ends with a user driving checklist. Ask the user to
  drive it and report back BEFORE marking the phase done or starting the next. Never claim
  a feel change works.
- **Functions over constants:** every behaviour must come from a physical model with
  physically-meaningful tunables (Hz, damping ratio, N·m, ramp ratios), not magic numbers.
- New tunables: `@export` vars on the vehicle + a row in `tuning_panel.gd` `_specs`
  (label, property, min, max, step, formatter — see existing rows at
  [tuning_panel.gd:13](../scripts/tuning_panel.gd)).
- **GDScript gotchas:** tabs not spaces; `:=` cannot infer from a Variant (untyped
  `stage.*`/dict access → `var x: Type = ...`); unshaded `StandardMaterial3D` ignores
  emission; macOS has no `timeout` (use `--quit-after N`, N = frames); Godot 4.4/macOS
  does not detect the wired Xbox controller — keyboard is the only input, analog code
  paths must stay intact but cannot be tested.
- Keyboard input map is built in `world.gd` `_build_input()` (`_add_keys`, ~line 218).
  New keys go there.
- After finishing a phase, update the phase's checkbox in §9 of this file and add a
  one-line status note (date + what the user's drive test concluded).

---

## 1. Vision & goal (interview outcome, 2026-08-02)

The user wants the DRIVING FEEL deepened, in this order:

1. **Arc A — Drivetrain & differentials**: corner-exit diff behaviour, clutch & launch,
   engine braking & lift-off character. Handbrake refinement only as a small late phase
   (current handbrake "feels decent").
2. **Arc B — Suspension & weight transfer**: body roll / left-right transition rhythm
   ("Scandinavian-flick-ability") and bump absorption / road texture. Jumps and landings
   are acceptable as-is.

Preceded by **Phase 0: the 120 Hz physics tick** (roadmap M15) so everything new is built
and tuned once, on the stable foundation.

- **Reference feel:** Assetto Corsa Rally and DiRT Rally 1. (RBR is the long-term
  benchmark but the user hasn't been able to run it properly on the Mac.)
- **Philosophy:** realism at the core, with toggleable "training wheels" on top:
  anti-stall (default ON), auto-blip/rev-match (toggle), stability assist (default OFF),
  launch assist (default OFF). The existing TC toggle stays.
- **Input:** keyboard-only for now; input shaping is FIRST-CLASS feel work (a binary
  throttle gates everything you can feel). Analog paths stay ready underneath.
- **Constraints:** every phase must leave the car fully drivable on keyboard. Nothing is
  sacred — existing tuning may be re-tuned in service of the end result.

### Feel acceptance criteria (the end state, in the user's terms)

- **Launch:** from standstill, launches differ by surface — asphalt hooks up after brief
  clutch slip; dirt needs throttle discipline; grass is loose but no longer "ice-like".
  Bogging the engine is possible (too tall a gear, too little throttle) and audible.
- **Corner exit:** the diff is FELT — an open front diff spins the inside wheel and washes
  wide; a clutch LSD pulls the car straight and tight on power; a locked rear on dirt
  steers with the throttle. Changing diff setup on the Tab panel changes the car's
  character within one lap.
- **Corner entry:** lifting off rotates the nose in, more with aggressive coast settings;
  downshifts without auto-blip produce a felt (and survivable) jolt of engine braking.
- **Transitions:** a left-right flick chain on dirt has readable rhythm — the body takes a
  set, returns predictably, and a Scandinavian flick can be timed and repeated.
- **Road texture:** washboard, ruts and berms read through the car without launching it —
  the suspension is felt "working"; the car stays planted at speed on the rough dirt loop.
- **Sound follows physics for free:** free-revving in neutral, bogging, blips and engine
  braking are all audible because engine rpm is finally a real state (`sound.gd` already
  pitches the drone from `get_engine().rpm` — zero audio work needed).

---

## 2. Current-state assessment (code read 2026-08-02)

All in `scripts/vehicle_m2.gd` (840 lines) unless noted. What exists is GOOD — a mature
combined-slip Pacejka tyre (slip ratio + slip angle + friction ellipse + load sensitivity,
lines ~605–790), a per-wheel spin-ODE drivetrain with semi-implicit integration
(lines ~666–756), surface-derived longitudinal stiffness `Bx` (the 2026-08-01 fix), tyre
thermal/wear/puncture (M7), damage (M8). **Do not rebuild any of that. Refine.**

### Drivetrain gaps (Arc A targets)

| # | What the code does today | Why it blocks the vision |
|---|---|---|
| D1 | **No engine state.** `_engine_rpm` is kinematically clamped to the driven-wheel average each substep (line ~690: `clampf(|wavg|·gr·final·60/TAU, idle, redline)`). | No flywheel → no free revving, no bog, no stall, no rev-match, no launch technique. The idle clamp is an invisible, infinitely slipping clutch. |
| D2 | **No clutch.** Launch behaviour comes from the idle clamp + `idle_torque_frac` + the `_t_drive` first-order torque lag. | Clutch bite/slip is the heart of launch feel and of the suspected grass-standstill problem ([[rally-sim-grass-standstill]]). |
| D3 | **No neutral.** `_gear` 0 = reverse, 1..6 = forward. | Free revving and real launches need N; remapping gears touches HUD + shift logic. |
| D4 | **Instant shifts.** Ratio swaps in one tick, no torque interruption, no blip. | Shifts have no rhythm, downshifts have no consequence. |
| D5 | **Engine braking is a constant** −50 N·m when `throttle < 0.05` (line ~703). | Real overrun torque grows with rpm (friction + pumping losses). Constant drag = no lift-off character to tune, no entry rotation from a downshift. |
| D6 | **Axle diffs are one hardcoded formula**: `t_axle·0.5 + lsd_lock·(mate.ω − w.ω)` (line ~726) — open + viscous coupling, same `lsd_lock` front and rear. | No preload, no torque-sensitive (Salisbury power/coast) locking, no per-axle setup, no selectable types. Corner-exit character is exactly this. |
| D7 | **Centre "diff" is a pure torque split** `eff_split` — front and rear axle speeds are completely uncoupled. | A real centre diff/coupling transfers torque when axles overspeed each other; also the rally handbrake trick (open the centre, lock the rears) is impossible. |
| D8 | **Handbrake fakes it**: adds rear brake torque (fine) but then multiplies rear lateral force by `rear_grip_cut = 0.2` (line ~780) — a magic-number hack. | Locked wheels already lose lateral grip naturally through the combined-slip ellipse; the hack double-counts and hides the real behaviour. |
| D9 | **Throttle and brake are raw 0/1 keys.** Only `_t_drive` smooths torque; brake is an unshaped 2600 N·m step. | No trail braking, no throttle modulation — the driver's foot needs a physical model too (virtual pedals). Steering, notably, IS already shaped (ramps + speed falloff, lines ~570–591). |
| D10 | Dead export: `brake_force` (M1 leftover, unused in M2; panel slider does nothing). `handbrake_torque` panel row maps to nothing on M2. | Cleanup when touching brakes. |

### Suspension gaps (Arc B targets)

| # | What the code does today | Why it blocks the vision |
|---|---|---|
| S1 | Hand-set constants: `spring_k = 40000`, `damper_c = 8000`, per-wheel corner mass ≈ 312 kg. | That is ride frequency ≈ **1.8 Hz** (tarmac-racecar stiff — gravel cars run much softer) and damping ratio **ζ ≈ 1.13 — overdamped** (race baseline is 0.65–0.70). Physically explains BOTH complaints: overdamped = dead, slow transitions AND harsh washboard skipping. |
| S2 | One damper coefficient for bump and rebound, linear. | Real (rally) dampers are asymmetric (rebound ≫ bump) and digressive — stiff low-speed for body control, soft high-speed with blow-off for square-edge hits. This one change carries most of "transitions" AND "road texture". |
| S3 | No bump stops: compression is silently clamped at `max_travel`, `Fz` hard-clamped at 20 000 N (line ~633) — which the ARBs then overflow past (up to ~40 000, the reason M7's impact-puncture proxy was unreliable). | Bottoming is a cliff, not a progressive event; the Fz clamp distorts loads; a real bump-stop gives M7 its clean puncture trigger (`w.bottomed`). |
| S4 | ARBs are N per metre of compression difference (14 000 / 10 000), hand-set. | Should be derived from a target roll gradient (deg/g) + front roll-couple %; estimate: the current setup is ≈ 1.8 deg/g — very flat, racecar-stiff. |
| S5 | Lateral tyre force is instantaneous with slip angle (line ~778). | No relaxation length → no tyre "take a set" lag; transitions feel darty rather than rhythmic. (Longitudinal already has natural lag via the ω ODE.) `By = 10` is also fixed while `Bx` is surface-derived — the lateral peak slip angle should differ tarmac vs gravel too. |
| S6 | CoM pinned very low (−0.45, comment: "corner hard without tipping"). | Suppresses honest roll/weight transfer; once ARBs/dampers are real, the CoM height can come up toward physical and roll can be controlled the real way. |
| S7 | Physics tick 60 Hz, drivetrain sub-stepped ×6 (= 360 Hz). | Community norm for raycast vehicles is ≥120 Hz; suspension/tyre forces update at only 60 Hz today. Doubling the base rate benefits everything Arc B touches. |

---

## 3. Research: chosen techniques, rationale, sources

### 3.1 Engine + clutch as a two-inertia driveline (Phases A1, A2, A4)

**Chosen approach:** give the engine its own integrated angular-velocity state
(`I_e·ω̇_e = T_combustion − T_friction(ω) − T_clutch`) coupled to the gearbox by a clutch
that transmits up to a capacity torque `T_cap = engagement · clutch_max_torque`, with
stick-slip: while slipping, torque is Coulomb-like (sign of Δω, smoothed); when |Δω| is
small and the through-torque fits inside capacity, the clutch LOCKS and the engine follows
the wheels kinematically — which is exactly today's code path, kept as the "locked" branch.
This is the standard real-time automotive approach:

- Two-inertia clutch models with Karnopp-style stick-slip (a dead zone around Δω = 0 to
  avoid chatter) are the established real-time technique — [Bataus et al., *Automotive
  clutch models for real-time simulation*](https://academiaromana.ro/sectii2002/proceedings/doc2011-2/05-Bataus.pdf).
- Vehicle Physics Pro (the best-documented commercial driveline for games) models exactly
  this: engine as rotating inertia with passive/active idle, stall + bump-start, clutch as
  lock-ratio or friction clutch-pack — [Edy: Engine, clutch and gearbox in VPP](https://www.edy.es/dev/2015/02/engine-clutch-and-gearbox-in-vehicle-physics-pro/),
  [VPP driveline docs](https://vehiclephysics.com/blocks/driveline/).
- **Engine braking becomes emergent**: motoring torque = mechanical friction + pumping
  losses, which GROW with rpm — model as `T_fric(ω) = c0 + c1·ω` (optionally +c2·ω²),
  with `c0`,`c1` DERIVED from two physical anchors (idle friction and engine-brake torque
  at redline) — [MIT 2.61 friction/pumping-loss notes](https://web.mit.edu/2.61/www/Lecture%20notes/Lec.%2019%20Friction%20and%20tribology.pdf),
  [Autosport: engine braking calculation](https://forums.autosport.com/topic/180576-engine-braking-calculation/).
  Closed throttle → negative net torque → overrun drag through the driveline. Off-throttle
  character then falls out of gear choice + rpm, and the flat `engine_brake = 50` constant
  dies.
- The existing `_t_drive` rise/fall lag is RETIRED in A1 — replaced by the real dynamics
  (engine inertia + clutch slip + a small first-order intake/manifold lag `intake_tau`,
  which keeps the physical grain of the 2026-08-01 fix without the fudged 0.25 s ramp).

**Alternative considered:** keeping the kinematic rpm and layering fake "clutch feel" on
the torque lag. Rejected: it cannot produce free-rev, bog, stall, rev-match or launch
technique, all of which the user explicitly asked for — and it's a constants-not-functions
dead end.

### 3.2 Differentials: Salisbury clutch-pack + selectable types + real centre coupling (Phase A3)

**Chosen approach:** a small diff abstraction evaluated per axle with selectable types —
OPEN / VISCOUS (today's model, kept) / **CLUTCH-PACK (Salisbury)** / LOCKED — plus a
centre coupling for AWD. Salisbury lock capacity: `T_lock = preload + k_ramp·|T_input|`,
where `k_ramp` differs for power (throttle-on) vs coast (overrun) — the ramp-angle
mechanism. Transfer torque opposes the wheel-speed difference up to that capacity
(Coulomb, integrated with the same semi-implicit `k_stiff` pattern already in the code).

- Model + parameters (preload N·m, power/coast angles, friction) documented in
  [VPP differential docs](https://vehiclephysics.com/blocks/differential/); mechanism
  background: [Autosport: LSDs and ramp angles](https://forums.autosport.com/topic/52016-limited-slip-differentials-and-ramp-angles/).
- Assetto Corsa (the user's reference title) exposes exactly POWER / COAST / PRELOAD per
  diff in `drivetrain.ini` — matching its semantics makes setup intuition transferable —
  [AC diff physics discussion](https://www.overtake.gg/threads/differentials-open-and-limited-slip.207521/).
- Feel mapping (why this serves "corner-exit diff feel"): more preload/power-lock = car
  drives straighter and tighter out of corners (push on entry, traction on exit); open =
  inside wheelspin; more coast-lock = stable on lift; less = eager lift-off rotation —
  [LSD effects on vehicle dynamics](https://www.designjudges.com/articles/differential-effects).
- **Centre:** keep the `torque_split` (it's the asymmetric-epicyclic split, real) and ADD a
  speed-coupling element (viscous or clutch preload) between the axles; the handbrake
  OPENS it (real rally hydraulic handbrakes disengage the centre so the rears can lock).

**Alternative considered:** Torsen/torque-bias model. Deferred — Salisbury + viscous +
locked covers rally practice (gravel cars run clutch/locked diffs), Torsen adds a type
later if wanted (the abstraction makes it a small add).

### 3.3 Suspension: derived setup, asymmetric digressive dampers, bump stops (Phases B1–B3)

**Chosen approach (all functions-over-constants):**

- **Springs from ride frequency:** `k = m_corner·(2π·f)²`. Targets from OptimumG: 0.5–1.5 Hz
  passenger, 1.5–2.0 Hz sedan racecar; rally gravel wants the soft end (~1.2–1.6 Hz front,
  rear ~10–20 % higher for flat-ride) — [OptimumG Tech Tip 1: Springs & Dampers](https://optimumg.com/wp-content/uploads/2020/01/SpringsDampers_Tech_Tip_1.pdf).
- **Dampers from damping ratio:** `c = 2·ζ·√(k·m_corner)`, baseline ζ ≈ 0.65–0.70, and
  asymmetric bump/rebound — [OptimumG Tech Tip 3: damping ratio](http://downloads.optimumg.com/Technical_Papers/Springs&Dampers_Tech_Tip_3.pdf).
  Current code is ζ ≈ 1.13 → the plan expects a LARGE felt improvement from this alone.
- **Digressive + blow-off:** low-speed damping (body roll/pitch — where the damper spends
  most of its time) stiff; above a knee velocity the slope drops so square-edge hits pass
  through softly — the defining rally-damper trait (gravel dampers add a high-speed
  blow-off precisely for ruts/rocks) — [damper low/high-speed tuning guide](https://corneringperformance.com/adjustable-suspension-tuning/),
  [Reiger gravel rally dampers (blow-off)](https://shop.vexperformance.com/products/reiger-suspensions-rally-performance-dampers-bmw-3-series-e46-1999-2006-gravel).
- **ARBs from roll gradient:** compute roll moment per g from mass and CoM height, choose a
  target roll gradient (deg/g) + front roll-couple %, derive the two bar rates —
  [OptimumG Tech Tip 2 (units/ARB)](https://optimumg.com/wp-content/uploads/2020/01/SpringsDampers_Tech_Tip_2.pdf),
  [Suspension Secrets: spring & ARB rates](https://suspensionsecrets.co.uk/calculating-ideal-spring-and-roll-bar-rates/).
- **Bump stops:** progressive force in the last ~20 % of travel replacing the silent clamp;
  raycast-vehicle norm of asymmetric bump/rebound damping is standard practice —
  [DigitalRune vehicle-physics notes](https://digitalrune.github.io/DigitalRune-Documentation/html/143af493-329d-408f-975d-e63625646f2f.htm).

### 3.4 Lateral relaxation length (Phase B4)

First-order lag on slip angle: `α̇ = (v/σ)·(α_ss − α)` — the tyre needs to roll ~σ metres
(≈ 63 % convergence) before lateral force builds. σ ≈ 1.5–2× tyre radius (~0.5–0.7 m
here), with a low-speed floor on `v` to avoid parking oscillation —
[Relaxation length review & time-constant analysis](https://www.researchgate.net/publication/281321108_Relaxation_Length_Review_and_Time_Constant_Analysis_for_Agile_Tire_Dynamics_Control).
This is the missing half of "transition rhythm" (the suspension is the other half); the
longitudinal side already has natural lag via the wheel-spin ODE. Also mirror the
2026-08-01 `Bx` derivation for `By`: derive from peak slip ANGLE per surface (tarmac
peaks ~8–10°, gravel slides deeper, ~12–16°) so gravel holds on longer before letting go.

### 3.5 The 120 Hz tick (Phase 0)

Raycast-vehicle stability is timestep-bound; sub-60 Hz is known-unstable and ≥120 Hz is
the community norm for stiff suspension/tyre updates ([gamedev raycast-vehicle stability
threads](https://www.gamedev.net/forums/topic/702824-raycast-suspension-at-high-physics-time-step-problem/)).
Keeping `drive_substeps` product constant (120 Hz × 3 = 360 Hz, same as today's 60 × 6)
means the drivetrain ODE budget is unchanged while suspension/tyre/lateral forces update
twice as often.

### Reference implementations worth reading during execution

- **Vehicle Physics Pro docs** (vehiclephysics.com) — the driveline/differential/engine
  chapters are the closest public blueprint to what Arc A builds.
- **Assetto Corsa `drivetrain.ini`** semantics (POWER/COAST/PRELOAD) — match the user's
  reference title's setup language.
- **Marco Monster, *Car Physics for Games*** — the classic grounding text
  ([mirror](https://www.asawicki.info/Mirror/Car%20Physics%20for%20Games/Car%20Physics%20for%20Games.html)),
  with Brian Beckman's *Physics of Racing* series as the deeper companion.
- **Richard Burns Rally / Assetto Corsa Rally / DiRT Rally 1** — feel benchmarks only.

---

## 4. Phase map (execute strictly in order)

| Phase | Arc | Title | Size |
|---|---|---|---|
| 0 | — | 120 Hz tick + virtual pedals | S |
| A1 | A | Engine inertia + clutch + neutral + anti-stall | L |
| A2 | A | Emergent engine braking + overrun + auto-blip | M |
| A3 | A | Differentials: Salisbury + selectable types + centre coupling | L |
| A4 | A | Gearshift model + launch assist + stability assist | M |
| A5 | A | Handbrake refinement (remove the grip hack, open centre) | S |
| B1 | B | Derived suspension setup (freq/ζ/roll-gradient sliders) | M |
| B2 | B | Damper model: bump/rebound split + digressive knee | M |
| B3 | B | Bump stops + honest load path (`w.bottomed` for M7) | S |
| B4 | B | Lateral relaxation length + surface-derived `By` + CoM height | M |
| B5 | B | Bake defaults, prune dead tunables, end-to-end verification | S |

Every phase: `./check.sh` clean → user drives the checklist → user verdict recorded →
next phase. Every phase leaves the car fully keyboard-drivable.

---

## 5. Phase details

### Phase 0 — 120 Hz foundation + virtual pedals

**Files:** `project.godot`, `scripts/vehicle_m2.gd`, `scripts/tuning_panel.gd`.

1. `project.godot` `[physics]`: add `common/physics_ticks_per_second=120`.
2. `vehicle_m2.gd`: default `drive_substeps` 6 → 3 (keeps the driveline at 360 Hz — no
   drivetrain re-tune expected; the semi-implicit ODE is rate-robust).
3. **Virtual pedals** (input shaping — the driver's foot, distinct from machine dynamics):
   add states `_throttle_pedal`, `_brake_pedal` (0..1) that chase the key state with
   physical rates; analog input (if a controller ever works) bypasses the shaping exactly
   like `_steer` already does for the stick.
   - New exports + Tab rows: `throttle_rise_time` (~0.18 s), `throttle_fall_time`
     (~0.08 s), `brake_rise_time` (~0.12 s), `brake_fall_time` (~0.08 s).
   - Replace direct `Input.get_action_strength("throttle"/"brake")` reads in
     `_physics_process` with the pedal states. Handbrake stays raw (it's a lever).
   - Note: `_t_drive` still exists in this phase (it goes away in A1); the stack of pedal
     shaping + torque lag is temporarily doubled smoothing — acceptable for one phase.
4. Watch perf: physics cost doubles. Add a TEMPORARY probe print of
   `Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)` avg, confirm headroom on
   the M1, then REMOVE the probe (repo convention).

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Baseline intact: top speed on the drag strip still ≈ 259 km/h in 6th; dirt-loop lap
  time within a couple of seconds of the ghost; no new vibration/jitter at speed or at rest.
- [ ] Brake taps now modulate — trail braking into a dirt corner is possible without
  instant lockup.
- [ ] Throttle feels progressive, not switch-like, especially in 1st–2nd on dirt.
- [ ] FPS unchanged (V-Sync 60).

### Phase A1 — Engine as a real inertia + clutch + neutral + stall/anti-stall

**Files:** `vehicle_m2.gd` (drivetrain block ~650–756, `_engine_torque`, `respawn`,
`get_engine`), `world.gd` (input map), `hud.gd` (gear display), `tuning_panel.gd`.

1. **Engine state:** add `_omega_e` (rad/s). Integrate inside the substep loop:
   `I_e·ω̇_e = T_comb − T_fric(ω_e) − T_clutch`, where:
   - `T_comb = throttle_pedal · _engine_torque(rpm)` through a first-order intake lag
     `intake_tau` (~0.07 s, export) — the physical remnant of the retired `_t_drive`.
   - `T_fric(ω) = c0 + c1·ω` with `c0`, `c1` DERIVED from two exports:
     `engine_brake_idle` (~18 N·m) and `engine_brake_redline` (~55 N·m) (see §3.1).
   - Active idle (VPP-style): below `idle_rpm`, inject up to `idle_torque_frac`-anchored
     torque to hold idle — keeps the existing no-stall default behaviour.
   - Rev limiter: keep the existing `rev_cut` shape, applied to `T_comb`.
2. **Clutch:** engagement `_clutch` (0..1). Capacity
   `T_cap = _clutch · clutch_margin · peak_torque` (`clutch_margin` export ~1.4).
   - Slipping: `T_clutch = T_cap · tanh(Δω / ω_smooth)` (Karnopp-style smoothing band);
     reaction torque drives the gearbox input (wheel side) through the existing gear maths.
   - Locked (|Δω| small AND through-torque < T_cap): switch to today's kinematic path —
     engine rpm follows driven-wheel average, reflected engine inertia exactly as now
     (torque-share weighting stays). Unlock when through-torque exceeds capacity.
   - **Auto-clutch (default):** engagement scheduled from rpm vs `bite_rpm` (~1800,
     export) and gear state; **anti-stall** (export `anti_stall := true`, Tab toggle)
     dips the clutch when rpm falls toward stall.
   - **Manual clutch toggle:** export `manual_clutch := false` + Tab toggle; new input
     action `clutch` on LEFT SHIFT (add in `world.gd`). Held = disengaged. If the engine
     stalls (manual mode, anti-stall off): rpm → 0, torque 0; restart by holding the
     clutch ~0.5 s (re-fires at idle), or bump-start by releasing the clutch in gear while
     rolling.
3. **Neutral:** remap `_gear`: **−1 = R, 0 = N, 1..6 forward** (Q from 1st → N, Q again →
   R; E from R → N → 1st). Update: shift logic (~line 651), `reverse` flag, gear display
   in `hud.gd` and `get_engine()` (grep ALL consumers of `get_engine()["gear"]` and
   `_gear` — hud.gd, sound.gd, component_hud.gd), and the shift-light gating (`_gear > 0`).
4. **Retire `_t_drive`** and its exports `torque_rise_time`/`torque_fall_time` (remove the
   Tab rows). Keep `slip_ref_speed`, substeps, semi-implicit pattern untouched. Fold the
   clutch torque into `k_stiff` on the wheel side for stability (same pattern as
   `lsd_lock`).
5. `respawn()`: reset `_omega_e` (to idle), `_clutch`, pedal states, stall flag.
6. New Tab rows: `clutch_margin`, `bite_rpm`, `intake_tau`, `engine_brake_idle`,
   `engine_brake_redline`, `anti_stall` (toggle), `manual_clutch` (toggle).

**Compile gate:** `./check.sh` clean. Use a temporary print probe to sanity-check rpm
convergence headlessly (engine settles to idle in N; revs to redline at WOT in N), then
remove it.
**User drive checklist:**
- [ ] In N at standstill: throttle revs the engine freely and the DRONE PITCH follows
  (this is the audible proof the engine state is real).
- [ ] 1st gear, anti-stall ON: pull away cleanly with just throttle; launch on grass is no
  longer ice-like — wheelspin responds to throttle taps ([[rally-sim-grass-standstill]]
  closure test).
- [ ] Manual clutch ON: it's possible to stall it; restart works; a clutch-drop launch in
  1st lights the tyres on asphalt.
- [ ] 3rd gear at 30 km/h WOT: the engine BOGS (labours below the power band) instead of
  instantly delivering.
- [ ] Nothing regressed at speed: top-speed run and dirt lap feel unchanged from Phase 0.

### Phase A2 — Emergent engine braking, overrun & auto-blip

**Files:** `vehicle_m2.gd`, `tuning_panel.gd`.

1. Delete the old `engine_brake` constant and its `throttle < 0.05` gate — overrun drag
   now flows automatically: closed throttle → `T_comb ≈ 0` → `T_fric(ω)` decelerates the
   engine → the locked/slipping clutch drags the driven wheels (through the diffs — note
   engine braking is split by the SAME paths as drive torque; verify it appears in
   `t_axle` with negative sign).
2. **Auto-blip / rev-match** (export `auto_blip := true`, Tab toggle): on downshift, while
   the auto-clutch re-engages, feed throttle to bring `ω_e` toward the post-shift target
   (`ω_wheels · gr · final`); cap the blip duration (~0.4 s). The target is COMPUTED, not
   a magic throttle constant. With `auto_blip` OFF the downshift lands with a felt
   engine-braking jolt (and, RWD on dirt, a rear twitch).
3. Verify lift-off behaviour end-to-end: mid-corner lift in 2nd–3rd should transfer load
   forward and tuck the nose (the tyre model already does this given the drag + weight
   transfer).

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Lift at speed in 3rd: the car decelerates noticeably harder in gear than in N
  (coasting in N now exists!).
- [ ] Lift mid-corner on dirt: nose tucks in, slight rotation — repeatable.
- [ ] Downshift into a hairpin, blip ON: smooth; blip OFF: a felt jolt + momentary slide.
- [ ] Engine-braking strength changes with the `engine_brake_redline` slider, felt within
  one lap.

### Phase A3 — Differentials: selectable types, Salisbury LSD, centre coupling

**Files:** `vehicle_m2.gd` (replace the per-wheel torque line ~726 and `eff_split`
plumbing), `tuning_panel.gd`.

1. **Axle diff abstraction.** Exports `front_diff_type`, `rear_diff_type`
   (0 = OPEN, 1 = VISCOUS, 2 = CLUTCH-PACK, 3 = LOCKED; Tab slider with a name
   formatter). Per axle, compute the wheel-pair transfer torque `T_x`:
   - OPEN: `T_x = 0` (plus tiny friction, ~5 N·m).
   - VISCOUS: `T_x = visc_lock · Δω` (today's model; per-axle exports `front_visc`,
     `rear_visc` replacing the single `lsd_lock`).
   - CLUTCH-PACK: capacity `T_cap = preload + ramp·|t_axle|`, `ramp = power_ramp` when
     `t_axle` drives forward, `coast_ramp` on overrun; `T_x = clamp(k_smooth·Δω, −T_cap,
     T_cap)` — Coulomb with a Karnopp band, added into `k_stiff` for the semi-implicit
     update. Exports per axle: `front_preload`/`rear_preload` (N·m, ~30–120),
     `front_power_ramp`/`rear_power_ramp` (0..1, AC-style), `front_coast_ramp`/
     `rear_coast_ramp`.
   - LOCKED: very high coupling (implemented as clutch-pack with huge preload — one code
     path, no special case).
   - Wheel pairing stays `_wheels[i]`/mate as today (FL–FR, RL–RR).
2. **Centre coupling (AWD only).** Keep `torque_split` as the base epicyclic split. Add
   `centre_coupling` (N·m per rad/s of front-rear average-speed difference, export,
   ~0–200) and `centre_preload` (N·m). The coupling transfers torque between axles when
   they overspeed each other (front axle spin on loose exit → torque migrates rearward —
   THE AWD rally feel). Handbrake interaction lands in A5.
3. Engine-rpm source: driven-wheel average must now respect the centre device (weight by
   actual torque share, as today — verify after refactor).
4. Defaults that match the current feel as closely as possible (VISCOUS both axles,
   `visc = 90`) so this phase STARTS neutral; character comes from the user moving Tab
   sliders. Then bake preferred defaults per drive mode after the drive test (expected
   rally baseline: clutch-pack front ~low power ramp, clutch-pack/locked rear, AWD centre
   coupling moderate).

**Compile gate:** `./check.sh` clean.
**User drive checklist** (drive each on the dirt loop hairpins + asphalt ring):
- [ ] FWD + OPEN front: inside front spins out of hairpins, car washes wide (watch the
  HUD per-wheel slip).
- [ ] FWD + CLUTCH-PACK front (moderate power ramp): pulls straight and tight on exit —
  clearly different from open within one corner.
- [ ] RWD + LOCKED rear on dirt: throttle steers the car; slides are stable and long.
- [ ] Coast ramp high vs low (rear): entry stability vs eager lift-off rotation — felt.
- [ ] AWD: with centre coupling up, loose-surface exits feel "four paws digging"; with 0
  it reverts to today's uncoupled feel.

### Phase A4 — Gearshift model + launch assist + stability assist

**Files:** `vehicle_m2.gd`, `tuning_panel.gd`.

1. **Shift model:** shifting takes `shift_time` (~0.18 s, export): auto-clutch dips,
   ratio swaps mid-dip, clutch re-engages (with A2 blip on downshifts). Money-shift guard
   (export `overrev_guard := true`, Tab toggle): refuse a downshift that would send
   `ω_e` past redline; with the guard OFF the overrev is allowed and adds `_damage`
   (small, via the existing M8 accumulator) — training-wheel semantics.
2. **Launch assist** (export `launch_assist := false`, Tab toggle): at standstill in 1st
   with throttle held, hold rpm at the COMPUTED peak-slip launch rpm and manage clutch
   engagement toward `peak_slip_*` for the current surface; cancel on brake. (It is an
   automated version of what manual clutch + throttle discipline achieves — an aid, not a
   different physics path.)
3. **Stability assist** (export `stability_assist := false`, Tab toggle): compute target
   yaw rate from the bicycle model (`ψ̇_target = v·δ / (L + K_us·v²)` — a FUNCTION of
   geometry, not a constant); when actual yaw exceeds target by a margin, apply a small
   counter-torque via per-wheel brake torque (ESC-style, gentle, clearly an aid).

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Full-throttle upshifts on the drag strip have a rhythmic dip (and cost a tenth or
  two vs Phase A3 — check the timer).
- [ ] Overrev guard OFF + deliberate money shift: engine screams past redline and the
  damage bar ticks up; guard ON: the shift is refused.
- [ ] Launch assist ON: consistent hard launches on asphalt AND dirt; OFF: manual
  technique still beats or matches it with practice (it must not be strictly superior).
- [ ] Stability assist ON: big dirt slides get visibly tamed (learning mode); OFF: raw.

### Phase A5 — Handbrake refinement (small)

**Files:** `vehicle_m2.gd`, `tuning_panel.gd`.

1. Delete the `Fy *= rear_grip_cut` hack (line ~780). Locked rears must lose lateral grip
   EMERGENTLY: verify that full handbrake locks the rear ω in the spin ODE, slip ratio
   saturates, and the friction ellipse trims `Fy`. If the emergent effect is too weak,
   the fix is in the tyre/ellipse maths, not a grip multiplier — investigate before
   reaching for any constant. Remove the `rear_grip_cut` export + Tab row.
2. Handbrake OPENS the centre coupling (A3) while held (`handbrake_opens_centre := true`,
   export) — AWD can now do proper handbrake turns without fighting the front axle.
3. Auto-clutch dips while the handbrake is held at speed (rally technique: clutch in so
   the engine doesn't fight/stall the rear lock) — with `manual_clutch` ON, that's the
   driver's job.
4. Cleanup from D10: remove the dead `brake_force` export + its Tab row; remove the
   orphan `handbrake_torque` Tab row (or wire a real `handbrake_torque` export replacing
   `brake_torque · handbrake_strength` — prefer the wire-up, it's the more honest name).

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Space-tap into a dirt hairpin at ~60–80: the rear steps out predictably, the car
  rotates, release + throttle exits cleanly (all three drive modes; AWD notably better
  than before).
- [ ] The handbrake no longer feels like a "grip switch" — rotation builds with how long
  Space is held.
- [ ] Engine doesn't stall/fight during the pull (auto-clutch dip working).

### Phase B1 — Derived suspension setup (functions replace constants)

**Files:** `vehicle_m2.gd` (suspension block ~611–648, exports), `tuning_panel.gd`.

1. Compute static corner masses from `chassis_mass` + CoM position (INCLUDING the
   per-mode `_com_bias()` z-shift — front/rear split changes with drive mode).
2. Replace `spring_k` with derived per-axle rates: exports `ride_freq_front` (default
   1.4 Hz), `ride_freq_rear` (1.6 Hz); `k_axle = m_corner·(2π·f)²`. Replace `damper_c`
   with `zeta` (default 0.65): `c = 2·ζ·√(k·m_corner)` (asymmetry comes in B2).
3. Replace `arb_front`/`arb_rear` with `roll_gradient_target` (deg/g, default 4.5 —
   gravel-soft) + `roll_couple_front` (%, default 55): compute total needed roll
   stiffness from mass, CoM height and track width, subtract the springs' contribution,
   split the remainder into the two bar rates (§3.3 sources).
4. Fz clamp: raise the hard 20 000 N clamp to a DERIVED cap (e.g. 6× static corner load)
   as an interim until B3's bump stops replace it properly.
5. Tab panel: remove `spring_k`/`damper_c`/`arb_front`/`arb_rear` rows; add
   `ride_freq_front`, `ride_freq_rear`, `zeta`, `roll_gradient_target`,
   `roll_couple_front`. (The raw N/m / N·s/m values should be printed once via a
   temporary probe for sanity — expect front k ≈ 24–28 k at 1.4 Hz — then remove.)

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] The car is immediately softer and more alive over the dirt loop (1.4/1.6 Hz + ζ 0.65
  vs the old 1.8 Hz / ζ 1.13) without floating or bottoming everywhere.
- [ ] `roll_gradient_target` slider: 2.5 = flat/dead, 6 = wallowy — pick the sweet spot.
- [ ] `roll_couple_front` slider audibly/visibly shifts balance (more front = understeer).
- [ ] Changing drive mode (T) re-derives the setup sensibly (FWD noses down slightly, etc.).

### Phase B2 — Damper model: bump/rebound asymmetry + digressive knee

**Files:** `vehicle_m2.gd` (damper force line ~633), `tuning_panel.gd`.

1. Replace `damper_c · comp_vel` with a physical damper FUNCTION per corner:
   - Asymmetry: `zeta_bump` (default 0.55) for compression, `zeta_rebound` (default 0.85)
     for extension (real dampers: rebound > bump).
   - Digressive knee: full slope below `knee_speed` (default 0.08 m/s, export); above it
     the incremental slope multiplies by `hs_blowoff` (default 0.35, export) — low-speed
     handles roll/pitch/transitions, high-speed swallows washboard and rocks.
   - Force = piecewise-linear in damper velocity, built from those four physical params;
     keep the ±3 m/s velocity clamp (safety) but it should rarely engage now.
2. Remove the interim single `zeta` from B1 (it splits into bump/rebound); keep the Tab
   panel tidy: `zeta_bump`, `zeta_rebound`, `knee_speed`, `hs_blowoff`.

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Washboard/berm sections at speed: the car stays planted and reads the texture
  instead of skipping/pogoing (compare the centre dirt patch ruts too).
- [ ] Left-right flick chain on dirt: the body takes a set and returns with a rhythm you
  can time — try an actual Scandinavian flick into a hairpin.
- [ ] Crest landings: compress-and-settle, no double bounce (rebound doing its job).
- [ ] `hs_blowoff` slider low→high changes rough-road harshness audibly/visibly.

### Phase B3 — Bump stops + honest load path

**Files:** `vehicle_m2.gd`, `tuning_panel.gd`.

1. Progressive bump stop: in the last `bumpstop_zone` (default 20 %, export) of
   `max_travel`, add a stiffening force (quadratic or cubic ramp, `bumpstop_stiffness`
   export scaled from corner load — derived default) so bottoming is an EVENT with a
   ramp, not a silent clamp. Set `w.bottomed := true` on engagement (new Wheel field).
2. Remove the interim Fz cap from B1 — loads are now bounded physically by the bump stop.
   Verify the ARB pass can no longer produce absurd Fz (the M7 note about 40 000 N).
3. `w.bottomed` is exposed for M7: it is THE clean hard-hit puncture trigger the roadmap
   asked for (`impact_punctures` stays OFF; wiring it to `bottomed` is a one-line
   follow-up the user can opt into later — note it in ROADMAP).

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Jump landings and kerb strikes on the asphalt ring feel progressive — firm, not
  crashy, no physics spikes.
- [ ] Deliberately slam the biggest dirt-loop crest flat-out: the car survives with a
  hard-but-controlled bottoming, and the HUD Fz numbers stay sane.

### Phase B4 — Transition rhythm: lateral relaxation + surface-derived `By` + CoM height

**Files:** `vehicle_m2.gd` (lateral force site ~777–778, `_mf_peak_u` reuse), `tuning_panel.gd`.

1. **Relaxation length:** per wheel, add a relaxed slip-angle state:
   `w.alpha_rel += (α_ss − w.alpha_rel) · clamp(v/σ_lat · dt, 0, 1)` with `sigma_lat`
   export (default 0.55 m ≈ 1.6× wheel radius) and `v` floored at `slip_ref_speed`.
   Feed `w.alpha_rel` (not raw α) into the lateral `_mf`. Longitudinal stays as-is.
2. **Surface-derived `By`:** mirror the Bx derivation — exports `peak_alpha_tarmac`
   (default 9°) and `peak_alpha_gravel` (default 14°); derive `By` per wheel via
   `_mf_peak_u(Cy, Ey)` and blend by surface grip exactly like `bxw` (line ~736). Remove
   the fixed `By = 10`. Gravel now holds a deeper slide before letting go — the DiRT-1
   "lean on it" gravel feel.
3. **CoM height** as an export `com_height` (default −0.45, the current value). After 1+2
   feel right, test raising toward −0.30/−0.25 with the user: more honest roll and load
   transfer, tamed by the now-real ARBs/dampers. Bake whatever the user prefers; keep the
   slider.

**Compile gate:** `./check.sh` clean.
**User drive checklist:**
- [ ] Steering feels less darty; the car "takes a set" into corners with a beat of delay
  that makes flicks timeable (σ slider 0.2 vs 0.9 must feel clearly different).
- [ ] Gravel slides hold longer/deeper before breaking away vs asphalt (peak-α split).
- [ ] No shimmy or weaving at parking speeds or at 250 km/h on the strip (low-speed floor
  working).
- [ ] CoM A/B: raised CoM verdict recorded (keep or revert — user's call).

### Phase B5 — Bake, prune, end-to-end

**Files:** `vehicle_m2.gd`, `tuning_panel.gd`, `docs/ROADMAP.md`.

1. Bake the user's preferred slider values from ALL phases into the `@export` defaults.
2. Prune dead code/exports/panel rows: `_t_drive` remnants, `engine_brake` constant,
   `lsd_lock` (replaced per-axle), `rear_grip_cut`, `brake_force`, old suspension
   constants — grep the panel `_specs` against the vehicle's actual properties.
   **KEEP the [1]/[2]/[3] differential presets** (`DIFF_PRESETS`, `apply_diff_preset`,
   `diff_preset_index/name`, the keyboard + touchpad bindings, the HUD readout): the user
   asked for them to stay as a permanent setup-comparison tool, not a temporary eval aid.
   Re-bake their values if later phases change what "rally" should mean, but don't delete.
3. Run the FULL end-to-end verification (§8) with the user.
4. Update `docs/ROADMAP.md`: mark M15 done, record the drivetrain/suspension state, note
   the `w.bottomed` puncture-trigger option, retire superseded notes (e.g. the Tier-3
   torque-delivery entry is superseded by the real engine/clutch model — say so
   explicitly so future sessions don't resurrect `_t_drive`).

---

## 6. What must NOT break (regression surface)

- **The tyre model core** (`_mf`, `_mf_slope`, `_mf_peak_u`, friction ellipse, `_mu_load`,
  surface-blended `Bx`): Arc A routes torque INTO it; B4 adds a state in FRONT of the
  lateral path. Never restructure the ellipse (ROADMAP: "refine, don't rebuild").
- **M7 tyre thermal/wear/puncture:** `_update_tyre(w, Fx, Fy, v_long, v_lat, dt)` call
  signature and the `w.tyre_grip` fold-in sites must keep working; `[P]` debug key; the
  deflated-visual + shake path.
- **M8 damage:** `damage_power_loss` must keep multiplying engine output (relocates into
  `T_comb`), grip-loss sites unchanged, steering pull unchanged.
- **M6 wear line:** `surface_source.grip_at()` is wrapped by `wear.gd` — every grip query
  must keep going through `surface_source` (never call `stage.grip_at` directly).
- **Consumers of vehicle state:** `hud.gd` (per-wheel Fz/slip/grip + `get_engine()`),
  `component_hud.gd`, `sound.gd` (rpm→pitch, slip→tyre audio, puncture flap), `world.gd`
  (skid-mark gate reads base grip; `w.slip` feeds terrain dig + dust), `terrain.gd`
  (`w.slip` wheelspin excavation), `time_trial.gd`/`pace_notes.gd` (untouched). After the
  gear remap (A1), grep EVERY consumer of `_gear`/`get_engine()["gear"]`.
- **Respawn contract:** R must reset every new state added by every phase (engine ω,
  clutch, pedals, alpha_rel, bottomed, assist states). Check `respawn()` at the end of
  each phase.
- **Keyboard drivability at every phase boundary** — the user must always be able to test.
- **Headless check** must stay clean — no phase may introduce editor-only dependencies.

## 7. Risks & unknowns, and de-risking

- **120 Hz perf on the M1** (raycasts, wear sampling, terrain all tick 2×): measure with
  the Performance monitor probe in Phase 0 before building on it. Fallback: 90 Hz
  (`physics_ticks_per_second=90`, substeps 4 = 360 Hz driveline) — decide with data.
- **120 Hz feel drift:** damper forces sampled 2× as often behave slightly differently.
  Phase 0's checklist explicitly re-baselines (top speed, lap vs ghost) BEFORE any model
  changes, so any drift is caught in isolation.
- **Clutch ODE stiffness:** a locked clutch is a rigid constraint; the plan avoids
  stiffness blowups by keeping the LOCKED state kinematic (today's proven path) and only
  integrating during slip, with the tanh/Karnopp band + `k_stiff` fold-in. If chatter
  appears at the lock boundary, widen the Karnopp band or raise `drive_substeps` — do NOT
  add damping constants.
- **Gear remap fallout (A1):** `_gear` semantics change; the de-risk is the explicit
  grep step for all consumers + the shift-light/reverse checklist items.
- **Salisbury sign conventions** (power vs coast under reverse gear / negative torque):
  test reverse explicitly in A3's headless probe; the ramp selection must use the SIGN of
  axle input torque, not the throttle.
- **Removing `rear_grip_cut` (A5) may reveal the ellipse under-trimming locked-wheel
  lateral force.** That would be a genuine tyre-model finding — investigate the ellipse
  maths rather than restoring the hack; worst case keep the export defaulted to 1.0
  (= off) and document.
- **Relaxation length at near-zero speed** can oscillate — floored `v` and the clamp on
  the blend factor prevent it; the parking-speed checklist item verifies.
- **Raising the CoM (B4)** risks rollovers on berms; it's gated behind a user A/B with
  the old value one slider-drag away.
- **Softer springs (B1) + existing 1.35-ish jump geometry** may bottom more: B3's bump
  stops are deliberately ordered right after; if B1 testing bottoms violently, temporary
  mitigation is a higher `ride_freq` until B3 lands.
- **Assists masking physics bugs:** all assists land LAST in their arc (A4) and default
  OFF (except anti-stall) — raw physics is always the tested baseline first.

## 8. End-to-end verification (after B5)

Compile: `./check.sh` clean, plus one windowed run for audio/TTS sanity.

User drive-through, all in one session, keyboard:
1. **Cold start ritual:** spawn, N, free-rev (pitch follows), 1st, pull away — no stall
   with anti-stall ON; deliberately stall with manual clutch ON; restart.
2. **Drag strip:** launch-assist OFF manual launch, then ON — compare; full upshift run
   to ~259 km/h in 6th (baseline preserved); money-shift guard test at speed.
3. **Dirt loop, 3 laps AWD:** flick chain through the esses (rhythm), handbrake hairpin,
   lift-off rotation test, washboard section planted, one deliberate crest slam
   (bump-stop event, no spike), lap time within reach of the pre-plan ghost (feel must
   not have cost pace unless the user prefers it).
4. **Diff character A/B on the same corner:** open vs clutch-pack front (FWD), locked vs
   open rear (RWD) — each change felt within a lap.
5. **Asphalt ring, 2 laps:** tarmac tyres bite at low slip angles (derived By), trail
   braking works, kerb strikes progressive.
6. **Consumables intact:** [P] puncture visual+flap+shake; tyre temps move sensibly; a
   deliberate crash damages power/grip/steer-pull; R repairs and resets everything.
7. **Systems intact:** ghost + sector splits + pace notes on both circuits, wear line
   darkens the dirt racing line, [B]/[C]/[T]/[L]/Tab all work.
8. User records a verdict per acceptance criterion in §1 — anything unmet becomes a
   follow-up tuning session, not a silent pass.

## 9. Phase status (executor updates this)

- [x] Phase 0 — 120 Hz + virtual pedals — DONE 2026-08-02: user confirms top speed, throttle ramp, and 120 Hz all feel correct/more concrete; steady physics 1.84 ms/tick (huge M1 headroom).
- [x] A1 — Engine inertia + clutch + neutral — DONE 2026-08-03: headless probe PASS (N coast-down 3000→988 rpm, N WOT →7150/7200); user drove the checklist and verdict is "feels good".
- [x] A2 — Engine braking + auto-blip — implemented 2026-08-03 (`./check.sh` clean; headless probe PASS: 2s coast 20→ in 3rd drops 4.29 m/s vs 3.74 in N (overrun drag reaches the axles); blipped 3→2 dips clutch to 0.00, lands 14 rpm off the computed target, re-locks; jolt A/B 0.3s post-shift: 0.28 m/s lost blipped vs 1.10 raw; probe removed). Note: `engine_brake` constant already deleted during A1's rewrite; shifts now break the clutch lock so the ratio jump resolves through the plates. First drive feedback 2026-08-04: engine braking too weak in 3rd + no felt tuck → friction anchors raised to competition-spec 25/90 N·m (probe: in-gear coast extra 0.55→0.90 m/s per 2s); added [I] ignition starter (stabs clutch + 1.2s anti-stall grace so a worst-case 1st-gear restart survives, probe PASS). Eager lift-off ROTATION beyond this is A3's coast-ramp territory. Re-drive verdict 2026-08-04: engine braking "good now, feels comfortable" at 25/90; lift-off tuck accepted as A3 coast-ramp territory. A2 DONE.
- [x] A3 — Differentials — DONE 2026-08-05: user drove the [3] RALLY preset and reports it
  "feels good"; presets stay in the game as a permanent A/B tool (see §5 B5 — do NOT prune).
  Implemented 2026-08-04 (`./check.sh` clean; headless probe PASS: airborne pair split 20 rad/s after 0.25s → OPEN 18.2 / VISCOUS 0.00 / LOCKED 0.00; AWD launch 14.7 m/s, reverse −9.3 m/s, centre 150/80 stable. Found+fixed: saturated-Coulomb chatter on LOCKED — transfer torque now impulse-capped at the one-substep pair equaliser, same for the centre. Ramp power/coast selected by sign of engine-side torque `t_gb` → reverse-safe. Defaults VISCOUS 90/90 + centre 0/0 = pre-A3 feel; probe removed). Stall-restart report re-checked same day: all four paths (detect / Shift-hold / release pull-away / bump-start) PASS headless on current build — user's failures were on the pre-`[I]`/pre-grace build. AWAITING user drive checklist verdict.
- [ ] A4 — Shift model + assists
- [ ] A5 — Handbrake refinement
- [ ] B1 — Derived suspension setup
- [ ] B2 — Damper model
- [ ] B3 — Bump stops
- [ ] B4 — Relaxation length + By + CoM
- [ ] B5 — Bake, prune, end-to-end
