# Changelog

Newest first. One entry per working day, grouped by what changed and why it mattered — not a
copy of the commit log. **`docs/ROADMAP.md` remains the authoritative state**; this file is the
history of how it got there, so a future session can answer "when did this change, and why?"
without reading every diff.

**Keep it current:** add an entry when a plan phase closes, when a bug is fixed, or when a
measured finding changes what we believe about the car. Feel verdicts belong here too — they are
the only verification this project has for feel, and they are otherwise lost in chat.

**Write entries to be SEARCHED, because that is what this file is for.** Its main job is
forensic: when something breaks, or an old bug comes back, this is where you grep for hints
before touching code. So every entry must name the **symptom in the words you would use while
driving** — "inside rear wheel cooking on gentle turns", "car pogos above 400 km/h", "top speed
capped around 130", "launches on grass feel like ice" — not only the mechanism or the name of the
fix. A symptom you cannot search for is a symptom you will diagnose twice. Record the measured
numbers alongside it (before/after, per-wheel loads, distances), since a recurrence is usually
recognised by the numbers drifting back rather than by the symptom returning in full.

---

## 2026-08-13 (evening, later)

**Tyre smoke on hard stops, and particles that look like dust instead of flying squares.**
Symptoms this fixes: *"stamping on the brakes on tarmac produces no smoke"*, *"the particles look
like squares flying"*, *"dust puffs around the car instead of trailing behind it"*.
**Smoke had one cause and needed two.** It gated on M7 tyre temperature alone, so a panic stop
made none — the tread had not had time to heat up, which is precisely when a real tyre smokes
most. Smoke now takes whichever route is stronger: THERMAL (a tyre worked hot over a long drift)
or POWER — friction power at the contact patch, P = mu.Fz.v_slip, which a locked wheel dumps into
the tread instantly. Measured: a hard stop on cold tyres (60 C, 5 kN, 25 m/s of slip) now reads
**1.00 where the temperature-only gate read 0.00**; a cold lock-up at 30 km/h reads 0.68; threshold
braking with small slip reads a faint 0.07; cruising stays at 0.02. Colour is white-grey (0.90,
0.90, 0.92) burnt rubber.
**Particles** now use procedurally generated soft puff sprites — 5 variants, each with its own
lobed silhouette and internal mottling from its own seed, generated in code like everything else
(no image assets). Each particle also gets a random start rotation, its own spin, a wide scale
spread (0.35–1.7), randomised lifetime and air damping, and a gradient that fades it in and
dissolves it rather than blinking it out. Verified: ~145 of 256 sampled pixels per sprite are
partial alpha, where a flat square would be 0. Dust is smaller (0.20 m) and there is more of it
(44 per wheel), which is what reads as dust rather than debris.
**Dust now trails.** Material is thrown BACKWARD along travel (`dust_trail` 0.65 of the kick)
instead of straight up, so a plume streams behind the car rather than puffing around it.
**Still not drive-tested** — visual, so only driving can judge it. `slip_ref` (6 m/s for full
intensity) and `smoke_power_ref` (45 kW) are the first knobs to reach for if it is too eager or
too shy.

## 2026-08-13 (evening)

**M11 dust, smoke and skid marks — now driven by physics instead of a threshold.** New
`scripts/effects.gd`, self-contained; the old inline code in `world.gd` is gone.
Symptoms this fixes, in driving words: *"sliding sideways on gravel throws no dust"*, *"dust
looks identical on grass and on the gravel loop"*, *"tyre smoke on tarmac whenever a wheel
spins, even stone cold"*, *"skid marks vanish mid-corner"*.
The old test was `w.slip > 0.35` — slip RATIO only — so it saw wheelspin and lock-ups and was
blind to everything else. Effects now scale with **contact-patch slip velocity** (m/s of rubber
actually sliding, combining slip ratio AND slip angle) times **load**, so a lightly loaded wheel
throws less. Measured on synthetic cases: a pure sideways slide at 25 km/h reads 12.0 m/s of slip
and full intensity where the old test emitted **nothing**; a big slide on an unloaded wheel drops
to 0.20 intensity where the old test emitted at full; a blip at a standstill drops to 0.19 (a
puff, not a plume); gripping at 108 km/h stays at 0.00.
**Smoke is thermal, not merely frictional** — it gates on M7's per-tyre temperature, starting at
110 °C and reaching full at 165 °C (optimum is 85 °C), so a cold lock-up puffs and a long drift
billows. **Dust takes its colour from the ground it came from** via `stage._surface_color()`, so
the gravel loop throws dusty tan and the grass verge throws olive — no per-surface colour
constants. **Marks** moved from 600 individual nodes to one MultiMesh with per-instance alpha and
a 14 s fade, so the pool wrapping thins the oldest mark out instead of making it disappear.
*Owed follow-up: the new `@export`s (slip_ref, smoke_temp, mark_fade, …) have no tuning-panel rows
or HELP lines yet — `tuning_panel.gd` was held by the B2 session at the time. Add them when it is
free, per the convention.* **Not yet drive-tested — this is a visual change and only driving can
judge it.**

## 2026-08-13 (later still)

**B2 CLOSED — drive verdict: "feels good".** Asymmetric digressive damper accepted.

**Suspension travel cut from 500 mm to 320 mm — the "vertical budget" was never the problem.**
Symptom this closes: *"all four corners bottom out on the dirt loop"*, *"suspension bottoming
going uphill at 100 km/h"*, and the instinct that follows it — *"the car needs more travel"* /
*"raise the ride height"*. It does not. Real gravel WRC cars run **250-300 mm of TOTAL wheel
travel**; this car had 500 mm, i.e. **373 mm of BUMP travel alone — more than a real rally car's
entire stroke — and it still pegged 100%**. Travel was never the constraint, and the ride-height
lever taken earlier (0.45 → 0.50) made it worse, not better. Ground clearance had reached 538 mm
against a real gravel car's ~300 mm.
Measured on the dirt loop at ~100 km/h, 500 mm vs 320 mm: peak travel 100% in both, 4/4 corners
pegged in both, frames on the stops **50 → 177**, and — the counter-intuitive part — **peak Fz
28.8 kN → 23.1 kN**. Less travel produced LOWER peak loads, because the spring keeps building
force over the whole stroke: at full compression it made 12.1 kN of spring force at 500 mm
against 7.7 kN at 320 mm. The inflated travel was manufacturing its own load spikes.
Static sag is unchanged at 127 mm (springs untouched, B1 is drive-verified), so sag is now 40% of
total travel and bump travel is 193 mm; body clearance 358 mm.
**What to expect, and what NOT to diagnose as a bug:** the car now rides its bump stops often
(177 frames vs 50). That is correct — a real rally car on rough gravel is on the stops constantly.
It is also exactly why the stop wants to become **hydraulic** (velocity-sensitive, dissipating
energy as heat) instead of the current pure displacement spring, which stores the impact and
hands it straight back. That is the outstanding B3 revision, and it is now the ONLY remaining
suspect for bottoming harshness: B2 was tested and disproven as the fix (it cut peak load 23% but
slightly increased stop contact), and travel is ruled out by the numbers above.

## 2026-08-13 (later)

**B1 CLOSED — drive verdict: "feels good".** The derived suspension setup is accepted, and the
verdict covers the 5 cm ride height and the `chassis_mass` slider fix as well, since both landed
before the drive. B2 is now unblocked.

**Tuning panel: A–Z ordering and a live explanation banner.** The B1 drive surfaced that
`roll_gradient_target` was unintelligible — and the cause was structural, not that one label: the
panel was ~76 sliders in one flat list, in source order, with no explanation of any of them
anywhere in the game. Every control now carries a one-line explanation, shown in a fixed banner
under the title on hover (and as the native tooltip), and the list is sorted alphabetically so a
control can be found by name. Each explanation opens with the system it belongs to — ENGINE,
DIFF, SUSPENSION, TYRE — because alphabetical order scatters related knobs and the tag is what
carries the grouping. Coverage is verified: 76 of 76 sliders have help, with no orphaned entries.
*Convention added: a phase that adds a tunable adds its HELP line in the same commit.*

## 2026-08-13

**Drag strip extended to 4 km, with markers and barriers.** `strip_x1` now derives from a new
`strip_len` (4000 m) instead of being hand-set, so the strip re-marks itself if the length
changes. Distance posts every 100 m down both shoulders as a single MultiMesh (taller and orange
on each kilometre), a billboard call-out per kilometre, and a W-beam guard-rail arc round the far
lip of the runoff pad — 46 collision panels, 183 posts, beam top 0.75 m. `_guard_rail(polyline)`
lays panels and posts along any polyline and is reusable for new areas. *Note for top-speed runs:
at 259 km/h you need ~174 m to stop but there are only 91 m from the 4 km mark to the rail, so be
on the brakes by the 3.9 km post — or raise `runoff_r`.*

**B3 travel budget resolved — the car is jacked up 5 cm.** `rest_length` and `max_travel` 0.45 →
0.50, settling the item B3 left open. Ride frequencies deliberately untouched: stiffening them
would walk back the softness B1 exists to provide. Spring rates derive from corner mass and ride
frequency rather than ride height, so static sag in metres is unchanged — what changed is the room
above it. Measured: no corner bottoms at rest, and the bump stop now engages from 0.40 m instead
of 0.36 m, about **+4 cm of free bump travel per corner, +15% total**. Costs ~5 cm of CoM height
and so ~16% more roll moment, so **B1's roll couple wants a re-check on the next drive**.

**Fixed: the car-weight slider desynced the body from its own suspension.** `mass = chassis_mass`
is assigned once in `_ready()`, and the Tab panel's "Car weight" row drove the RigidBody's `mass`
only — so `chassis_mass`, the single authority for corner masses, roll gradient, the tyre load
reference (`_mu_load`) and rolling resistance, stayed at 1250 whatever the slider read. The row now
drives `chassis_mass`, and `_derive_setup` keeps the body's `mass` following it, so a live weight
edit re-rates the whole car. Only reachable by moving the slider to an extreme, which is why a
stress test found it and normal driving never would.

**Stress-test findings (user drove every slider to its goes-faster extreme).** None of these are
defects; they characterise the model's edges. Recorded in full in `docs/ROADMAP.md`.
- **Top speed is a numeric clamp, not a force balance.** 490 km/h is the wheel-spin clamp
  (±400 rad/s × 0.34 m = 489.6 km/h), with the valve-float ceiling (1.35 × redline through 6th)
  landing within half a km/h of it by coincidence. `top_speed_kmh()` knows about neither, so the
  speedo it graduates can under-read by >100 km/h at extreme settings.
- **The ~1 km stop from 490 km/h is correct physics.** Probed and swept: `mu_long` 0.9 → 856 m /
  1.13 g, 1.6 → 589 m / 1.65 g, 2.6 → 433 m / 2.22 g. With `drag_k` slidered down to 0.05 the aero
  term falls from ~13 kN to ~0.7 kN, so nothing but the tyres slows the car. An earlier attribution
  blaming the weight slider was wrong and has been corrected in the roadmap.
- **The car pogos above ~400 km/h, and it is underdamping — not aero.** Coasting with no input,
  suspension load collapses below 15% of static weight on 0% of frames at 299 km/h, 4% at
  468 km/h and 34–45% at 489.6 km/h. With `drag_k` at 0.0 it is unchanged (drag is a central force
  with no vertical component and no downforce model exists); with `zeta` 1.2 it drops to 3%, and
  2.5 to 0%. **This is B2's target and its headless success metric** — do not "fix" it by raising
  `zeta`, which would undo B1's compliance.
- **Nothing has ceiling behaviour.** Engine torque holds flat above redline instead of collapsing;
  tyre temperature reaches 128–299 °C against an 85 °C optimum with no upper bound. The model is
  well-behaved inside its envelope and simply extrapolates outside it.

**Planning.** Arc D (`docs/PLAN-stages-ground-map.md`) planned: the ground map and real
point-to-point stages, built on Arc C1's roughness field. **Settled decision: new maps go in a NEW
area — the existing circuits, centre patch and 4 km strip stay untouched as the calibration bed**,
because every baseline the project has is expressed in their terms. C1's execution prompt written.

## 2026-08-12

- **Fixed the real top-speed limiter:** Godot's default linear damping (COMBINE mode) was capping
  the car around 130 km/h. The 3rd-gear-redline ~140 reading was a separate red herring.
- **Speedo scales to the car's real top speed**, circular see-through dial.
- **A real engine thermal model** plus a cluster restyle; bottom-right outside-view cluster with
  warning telltales for the exterior cameras.
- **Camera:** right-stick look-around, click to glance behind.

## 2026-08-11

- **B1 — derived suspension setup.** `spring_k`/`damper_c`/`arb_*` are gone; springs come from
  ride frequency (1.4/1.6 Hz), dampers from `zeta` 0.65, bars from a target roll gradient and front
  roll couple, re-derived each tick so live edits and drive-mode CoM shifts both re-rate the car.
  First drive exposed the inside driven wheel overheating: the bars were sized only to reach the
  roll-gradient target, so they solved to zero and the springs' own distribution set the balance
  (43.4% front against a 55% setting). `_derive_setup` now enforces the couple first. **Still
  awaiting its drive verdict.**
- **B3 — bump stops, brought forward ahead of B2** because B1 testing bottomed. Progressive cubic
  stop over the last 20% of travel, sized off each corner's own static load; `w.bottomed` is now
  available to M7 as a clean hard-hit puncture trigger (not yet wired).
- **A4 and A5 closed, both drive-verified.** A5's first attempt was rejected as "way too strong"
  and reworked so sliding tyres take their force direction from the slip velocity.
- Cabin work: analog tacho and speedo dials, restyle, binnacle clipping fixed.
- Plan: Arc C added (surface roughness, self-aligning torque, wheel input, FFB), then C1 inserted
  ahead of the FFB phases.

## 2026-08-09 – 2026-08-10

- **A3 differentials drive-verified**; diff presets `[1]/[2]/[3]` marked a permanent keeper.
- **A4 shift model + launch and stability assists**, including a money-shift guard; stability
  assist later fixed for cutting power through ordinary corners.
- **DualShock 4 support** in an Assetto-Corsa-style rally layout — analog pedals live.
- Plan: the reusable headless input-probe harness pattern recorded in §0.

## 2026-08-04 and earlier

Initial repository snapshot: **M0–M10 complete plus the drivetrain arc through Phase A3.** That
covers the procedural stage (three concentric circuits, drag strip, deformable centre patch), the
combined-slip Pacejka tyre model with load sensitivity, the two-inertia engine and clutch driveline,
selectable differentials, tyre temperature/wear/punctures, the damage model, pace notes over OS TTS,
time-trial ghosts with sector splits, surface wear, and the live tuning panel. See the milestone
history in `docs/ROADMAP.md` for the detail behind each.
