# PLAN — Plumes: growth functions, aggregation LOD, and multiplayer readiness

_Draft 2026-08-18. Companion to `docs/ROADMAP.md` M11 and the Arc D prompt. Same working rules as
`docs/PLAN-drivetrain-suspension.md` §0: one phase at a time, every behaviour a physical function
with physically-meaningful tunables, new tunables get exports + Tab rows, `respawn()` resets new
state, headless probes for anything measurable, and **no phase is ticked without a drive verdict.**_

---

## 0. Why this exists

`scripts/effects.gd` is a four-layer, data-driven particle system (`plume`, `smoke`, `gravel`,
`spray`) with a shared `LAYERS` config table and a shared puff atlas. It works and it looks good.
Three pressures now push on it:

1. **Fill rate, not particle count.** The measured cost is overdraw — layers of semi-transparent
   pixels. One plume particle at the 160 km/h ceiling is ~4.4 m across; a dozen overlapping is a
   full-screen alpha blend. On the iPhone's tile-based GPU this is disproportionately expensive.
2. **Multiplayer.** Six cars each trailing an independent plume multiplies the same cost by six,
   and raises the question of what is replicated and what is derived.
3. **Dust and smoke have drifted together.** They are separate entries in `LAYERS` but the entries
   differ mostly by magnitude, so the two read as one effect in two colours.

The through-line: **cost should scale with what the player can see, not with how many cars exist.**

---

## 1. The growth-function question

The current growth is `"grow": [birth, mid_t, mid_v, death]` — a four-point piecewise ramp per
layer, sampled per particle by age. The proposal is to replace it with a continuous function of
normalised age `u = t_alive / lifetime`, so growth is a curve with meaning rather than four numbers.

**How to implement any of these for free:** Godot's `ParticleProcessMaterial` takes a
`scale_curve` (a `CurveTexture`). Bake the chosen function into a `Curve` once at startup and the
GPU applies it per particle at no per-frame CPU cost. **Do not evaluate growth functions in
GDScript per particle.** This makes the whole question a tuning exercise rather than a performance
trade — which is why it is worth getting right.

### 1.1 The candidates

Let `u ∈ [0,1]` be normalised age. All are normalised so `f(1) = 1`.

| # | Function | Shape | Physical reading | Verdict |
|---|---|---|---|---|
| A | `∫(\|sin x\| + x)` (your proposal) | accelerating, with gentle steps | ballistic throw + billow ripple | **good silhouette, wrong tail** |
| B | `√u` | fast then flattening | **turbulent diffusion** — the actual physics | **best physical default** |
| C | `u^(3/5)` | between A and B | Richardson/Taylor dispersion in a turbulent field | **best single answer** |
| D | `1 - e^(-ku)` | fast rise, hard asymptote | relaxation to an equilibrium size | good for smoke |
| E | `logistic 1/(1+e^(-k(u-u₀)))` | S-curve | a slow start then bloom | good for a *building* column |
| F | `√u · (1 + a·\|sin(ωu)\|)` | B's envelope, A's ripple | diffusion **plus** eddy structure | **the synthesis — recommended** |

### 1.2 On `∫(|sin x| + x)`

Worth being precise, because the idea is half right and the half that is right is the valuable half.

`∫₀ˣ(|sin s| + s) ds = x²/2 + (2⌊x/π⌋ + 1 - cos(x mod π))`

Two components. The `x²/2` term is **quadratic growth** — the plume expands ever faster as it ages.
Real dust does the opposite: a puff of particulate injected into still air expands fast at first
(the injection has momentum and the concentration gradient is steep) and then slows as it dilutes.
Turbulent diffusion gives radius ∝ `√t` in the simplest case, and `t^(3/5)` under Richardson
dispersion in a turbulent field. **Quadratic is backwards.** Left as-is, plumes would look like
they are inflating rather than dispersing, and the largest, most expensive sprites would be the
oldest and faintest ones — precisely the wrong place to spend fill rate.

The `1 - cos` staircase is the good part. It rides on the trend and gives each puff a subtle,
repeating swell — the visual signature of discrete eddies rolling off the wheel. That is real, and
it is exactly what a plain `√u` curve lacks.

**So: keep the ripple, replace the trend.** That is candidate F:

```
f(u) = √u · (1 + a·|sin(π·n·u)|) / (normaliser)
```

with `a` ≈ 0.12–0.25 (ripple depth) and `n` ≈ 2–3 (eddies per lifetime). Both are physically
meaningful tunables in the repo's sense: `a` is eddy strength, `n` is shedding frequency, and `n`
should rise with speed because faster wheels shed eddies faster — a real Strouhal-number
relationship, which is the kind of link this project prefers over a magic constant.

### 1.3 What to expose

- `plume_growth_exp` (0.5 default = √, range 0.4–0.8 — 0.6 is the Richardson value)
- `plume_eddy_depth` `a`
- `plume_eddy_count` `n` at the reference speed
- and `n` scaled by `plume_speed_t(v)`, which already exists

**Probe:** assert `f(0) = birth_frac`, `f(1) = 1`, `f` monotonic non-decreasing, and that the area
under the curve (a proxy for total screen coverage over a particle's life) *falls* versus the
current ramp. That last one is the performance claim and should be measured, not assumed.

---

## 2. Aggregation LOD — the actual saving

The growth curve changes how it looks. **This changes what it costs.**

Real dust coalesces: discrete puffs merge into a diffuse cloud within a second or two. So model
that, and let it pay for itself. Two populations:

- **Detail puffs** — near the wheel, short life (~0.8–1.2 s), small, fully simulated. This is what
  the player looks at.
- **Aggregate puffs** — one spawned per N expired detail puffs, at their centroid, with the summed
  cross-section (`r_agg = √(Σrᵢ²)`, conserving area, not radius), long life, slow drift, low alpha.

Overdraw falls because N overlapping semi-transparent sprites become one. Draw calls fall. And it
is *more* physical than the current model, not less — mass and cross-section are conserved through
the merge.

**Design constraint:** the transition must not pop. Cross-fade the last ~15% of a detail puff's life
against the aggregate's first ~15%. Probe: total emitted cross-section before and after the merge
boundary should match within a few percent.

**This is the phase that makes multiplayer affordable.** Six cars × detail puffs is untenable;
six cars where only the nearest one or two run detail puffs and the rest run aggregates only is
roughly the cost of one car today.

---

## 3. Splitting dust from smoke properly

The rule: **separate branches with distinct physics, never one config copied with a colour change.**
Right now they are close cousins. Concretely, from `LAYERS`:

| | `plume` (dust) | `smoke` | Problem |
|---|---|---|---|
| gravity | **−0.45** | **−0.30** | **dust currently rises faster than smoke — backwards** |
| life | 4.6 | 3.0 | plausible |
| turbulence | 0.55 | 0.30 | plausible |
| atlas | shared | shared | same silhouette for both |

Dust is **particulate**: it has mass, is thrown ballistically by the tyre, and **settles**. Its
vertical motion should be *up then down* — an initial kick against gravity that loses to
sedimentation. Smoke is **buoyant**: hot vaporised rubber and steam that rises the whole time it
exists and never settles.

Proposed split:

| Property | Dust | Smoke |
|---|---|---|
| Vertical | ballistic kick, then **positive** settling velocity (Stokes terminal) | sustained negative gravity (buoyant) |
| Growth | §1 candidate F (diffusion + eddies) | candidate D (`1 - e^(-ku)`, relaxes to a size) |
| Opacity | higher, granular; alpha falls with dilution | lower, wispy; alpha falls with cooling |
| Silhouette | **own atlas** — denser lobe clusters, harder edges | **own atlas** — fewer, softer, more stretched lobes |
| Driver | speed + slip + surface looseness | tyre temperature + friction power (already modelled) |
| Colour | ground colour (`ground_color()`) | **not** ground colour — rubber grey-white, tinted by heat |
| Wind | strongly advected | strongly advected + rises out of the wake |

Both get a settling/buoyancy tunable in real units rather than a shared `gravity` scalar.

---

## 4. Multiplayer model

**Plumes are never replicated.** They are a pure client-side function of state that is already on
the wire: car transform, velocity, wheel slip, surface class, tyre temperature. Every client
derives its own particles from that.

This resolves the culling worry directly. Camera-frustum culling is unsafe only if a plume is
authoritative shared state; if it is derived, each client culls against its own camera with no
desync risk. Two clients seeing different dust is not a bug — it is the same situation as two
clients seeing different shadow cascades.

Consequences:
- **No "memory of the plume path" is needed** for correctness. If a plume is off-camera and comes
  back into view, re-derive it from the last ~2 s of replicated car state. Cheaper than storing it,
  and it self-corrects after a network hiccup.
- **Emission budget becomes per-client and global**, not per-car: a total particle budget allocated
  across cars by screen-space size and distance. The player's own car always gets detail puffs;
  a car 200 m away gets aggregates only; a car off-camera gets nothing but keeps its emitter state
  so it can resume.
- **Determinism is not required**, which is what makes all of the above legal.

---

## 5. Phases

| Phase | Content | Risk | Drive-verified? |
|---|---|---|---|
| **P1** | Growth curves: bake `Curve` → `scale_curve`, expose the §1.3 tunables, keep current look as the default so P1 alone changes nothing | low | yes — A/B the exponent |
| **P2** | Dust/smoke split: separate atlases, settling vs buoyancy, independent drivers | medium — this is a look change | yes |
| **P3** | Aggregation LOD: detail + aggregate populations, cross-fade, area conservation | medium | yes, plus a perf probe |
| **P4** | Budget allocator: global particle budget by screen size and distance; per-car emitter state | low | yes |
| **P5** | Multiplayer derivation: emitters driven by replicated state only; frustum culling enabled | high — needs a network layer that does not exist yet | deferred |

P1 and P3 are the performance phases. P2 is the look phase. **P4 is the one that makes multiplayer
tractable and is worth doing even if multiplayer never ships**, because it also fixes the
single-player worst case (a big plume filling the screen).

---

## 6. Standing in for future upgrades

Hooks worth building now, cheap at this stage and expensive to retrofit:

- **A `SurfaceSample` struct** — colour, looseness, moisture, particle size — returned by one stage
  query instead of the current several. Arc D's ground map will fill it properly; today it can be
  derived from `_surface_color` + `grip_at`. Moisture in particular is the hook for wet stages
  later: wet dust does not plume at all, it sprays, and `spray` is already a layer.
- **Wind as a world-level vector field**, not a per-layer constant. One `Wind.sample(pos)` used by
  every layer means weather becomes a stage property rather than a particle edit.
- **Emitter state as data, not nodes.** If a plume is a small struct (origin, age, size, budget
  tier) that a renderer consumes, then swapping GPU particles for a ribbon mesh later — the other
  idea worth keeping alive — is a renderer change, not a rewrite.
- **A headless `--probe-effects` mode** that drives a scripted lap and reports emitted particle-
  seconds, peak concurrent particles and estimated overdraw. This is the missing instrument: it
  makes every phase above measurable before it is driven, which is the stated goal of running the
  full sim headlessly.

---

## 7. Open questions

1. Ribbon vs particles for the far LOD. A ribbon collapses when viewed edge-on and cannot respond to
   wind per-segment; particles cost fill. The aggregate puffs of §2 may make the ribbon unnecessary
   — decide after P3 measures the saving.
2. ~~Does the eddy count `n` scale with speed or with wheel angular velocity?~~ **RESOLVED: use the
   tyre's surface speed, `max(v, |omega|*r)`.** Neither alone survives the edge cases. Pure car speed
   `v` gives a stationary wheelspin no ripple at all, though that is exactly when the wheel is
   stirring the air hardest. Pure `|omega|*r` gives a fully locked wheel no ripple while the car
   slides at 100 km/h, which is worse. The physical driver is how fast the tyre surface moves
   relative to the ground it is throwing, and taking the max of the two is the cheap correct answer
   for both. Then `n = St * u_surf * T / D` with `St` ~ 0.2, `T` the particle lifetime and `D` the
   tyre diameter - all quantities the vehicle already tracks.
3. ~~Should dust colour sample the ground once at birth or continuously?~~ **DECIDED 2026-08-18:
   once at birth.** A puff is a parcel of material physically thrown off the surface at one instant;
   it carries that material's colour and has no mechanism to change it in flight. Crossing a
   surface boundary therefore shows a gradient of mixed puffs trailing behind the car rather than a
   whole plume switching colour at once - which is both cheaper and what actually happens. This
   makes `ground_color()` a per-emission call, not a per-frame one.
4. Where does the deformable patch's dug material fit? Digging a rut should throw *more* and
   *coarser* material than skimming a packed surface, and `terrain.gd` already knows how deep the
   rut is.
