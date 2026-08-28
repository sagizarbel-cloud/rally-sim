extends RefCounted
class_name StageGen
## D3 — the stage generator (docs/PLAN-stages-ground-map.md §5 Phase D3, §3.2, §3.3).
##
## It does NOT place corners and bumps. It samples a handful of stage parameters and then SOLVES
## geometry under real road-design constraints, which is the functions-over-constants answer to
## "what does a principled stage generator look like". The pipeline:
##
##   1. Route a coarse control polygon across the terrain, biased to follow contours rather than
##      climb them (the cheap stand-in for Galin et al.'s cost-based routing: a road that ignores
##      elevation reads as drawn-on rather than built), honouring authored control points as hard
##      constraints.
##   2. Fit a CENTRIPETAL Catmull-Rom spline through it. Centripetal specifically: unlike the
##      uniform parameterisation it is provably free of cusps and self-intersection within a
##      segment, which is the failure mode that turns a generated road into a knot
##      (Yuksel et al., Parameterization and Applications of Catmull-Rom Curves).
##   3. Enforce the design-speed minimum radius by RELAXING the control polygon where curvature
##      exceeds it, then refitting - so the constraint shapes the road instead of clipping it.
##   4. Emit an open Centreline plus a width profile along s.
##
## Everything is a pure function of StageDef.seed. No per-frame RNG, no dependence on load order:
## same def, same road, forever. That is §1.3's "the same stage twice is the same stage".
##
## §3.2's caveat is honoured deliberately: the design equations exist to make roads SAFE at their
## design speed, and a rally stage is the opposite - a road driven far beyond what it was built
## for. So they are used as the generator's constraint set and the design speed is set BELOW the
## car's capability on purpose. The driver is meant to be over-driving the geometry.

const SAMPLES_PER_METRE := 0.8            ## centreline sample density (~1.25 m); Centreline's own
                                          ## arc-length table refines between these
const RELAX_PASSES_MAX := 64              ## bounded, but see _enforce_min_radius: the loop EXITS on
                                          ## the constraint being met, not on the count. The count is
                                          ## only a non-convergence guard.

var def: StageDef
var centreline: Centreline
var _noise := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _rng := RandomNumberGenerator.new()
var _control: PackedVector2Array = PackedVector2Array()
var _relax_used := 0
var _worst_curvature := 0.0

func _init(stage_def: StageDef) -> void:
	def = stage_def
	# Elevation is a pure function of position and seed. Handed to StageDef as the FALLBACK so that
	# every elevation read in this file goes through def.elevation_at() - that is the import seam,
	# and routing this way is what makes swapping in a DEM a one-place change (§5 D3).
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = def.seed
	_noise.frequency = 0.0035
	_noise.fractal_octaves = 3
	_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail.seed = def.seed + 977
	_detail.frequency = 0.012
	_detail.fractal_octaves = 2
	def.set_fallback(Callable(self, "_procedural_elevation"))
	_rng.seed = def.seed

func _procedural_elevation(x: float, z: float) -> float:
	## fBm landform. §3.3 wants a hydraulic-erosion pass on top so valleys and ridgelines read as
	## deliberate; that is deliberately NOT here, because erosion is a GLOBAL iterative process and
	## §3.3's own resolution is to bake it offline per seed into the stage data - which belongs with
	## D5's area data, not with a single static area. Named as a seam, not smuggled in.
	var amp := lerpf(4.0, 26.0, clampf(def.elevation_character, 0.0, 1.0))
	var h := _noise.get_noise_2d(x, z) * amp
	h += _detail.get_noise_2d(x, z) * amp * 0.18
	return h

# ---------------------------------------------------------------- generation

func generate() -> void:
	## Route, fit, and let the design-speed constraint REshape the road until it holds. The loop
	## terminates on the constraint being satisfied, not on a pass count - a fixed iteration count
	## is how the _mf_peak_u bisection silently produced wrong geometry (§9 B4 of the drivetrain
	## plan), and the cap below exists only to catch non-convergence and say so.
	_control = _route()
	var pts := _fit_spline(_control)
	_relax_used = 0
	for pass_i in range(RELAX_PASSES_MAX):
		var hot := _violations(pts)
		_worst_curvature = _worst_k(pts)
		if hot.is_empty():
			_relax_used = pass_i
			_build_centreline(pts)
			return
		# Relax the CONTROL POLYGON, not the dense samples, and refit. Smoothing the samples was a
		# real bug: a 1.2 m-spaced point barely moves the curvature measured across its neighbours,
		# so it took hundreds of passes to achieve nothing, while moving a 22 m polygon vertex
		# actually changes the corner the spline draws.
		_control = _relax_polygon(_control, hot, pts.size())
		pts = _fit_spline(_control)
	_relax_used = RELAX_PASSES_MAX
	_worst_curvature = _worst_k(pts)
	push_warning("StageGen: min-radius relaxation did not converge in %d passes (worst R=%.1f m, limit %.1f m)"
			% [RELAX_PASSES_MAX, 1.0 / maxf(_worst_curvature, 1e-6), def.min_radius_m()])
	_build_centreline(pts)

func _violations(pts: PackedVector2Array) -> PackedInt32Array:
	var kmax := def.max_curvature()
	var hot := PackedInt32Array()
	for i in range(pts.size()):
		if _curvature_at(pts, i) > kmax:
			hot.append(i)
	return hot

func _worst_k(pts: PackedVector2Array) -> float:
	var w := 0.0
	for i in range(pts.size()):
		w = maxf(w, _curvature_at(pts, i))
	return w

func _relax_polygon(poly: PackedVector2Array, hot: PackedInt32Array, dense_n: int) -> PackedVector2Array:
	## Map each too-tight dense sample back to the polygon vertex that drew it and ease that corner
	## open, spreading the correction over its neighbours so the road keeps its line instead of
	## developing a flat spot. Authored control points are re-pinned afterwards: the constraint may
	## reshape the road around them, but it may not move them - they are hard constraints.
	var out := poly.duplicate()
	var n := poly.size()
	if n < 3:
		return out
	var touch := PackedFloat32Array(); touch.resize(n)
	for i in range(n):
		touch[i] = 0.0
	for h in hot:
		var v := int(round(float(h) * float(n - 1) / maxf(float(dense_n - 1), 1.0)))
		for k in range(-1, 2):
			var j := clampi(v + k, 0, n - 1)
			touch[j] = maxf(touch[j], 1.0 if k == 0 else 0.6)
	for i in range(1, n - 1):
		if touch[i] <= 0.0:
			continue
		out[i] = poly[i].lerp((poly[i - 1] + poly[i + 1]) * 0.5, 0.45 * touch[i])
	if def.control_points.size() > 0:
		out = _apply_control_points(out)
	return out

func _route() -> PackedVector2Array:
	## A stage is a ROUTE: it goes from a start line to a finish line (§1.2 answer 1). So the road is
	## built as a lateral offset along a straight SPINE between two points, not as a free heading
	## walk across the terrain.
	##
	## That is not a simplification, it is the fix for a real defect. A free walk has no sense of
	## progress, so it can double back and cross itself - measured on the default seed, which
	## produced a self-intersecting road the curvature relaxation could not repair, because easing a
	## corner open cannot untie a knot. A curve expressed as a bounded offset along a straight spine,
	## parameterised monotonically, is a GRAPH over that spine and therefore cannot self-intersect at
	## all. The property is structural rather than tested-for.
	##
	## The terrain still shapes it: the offset is nudged toward the flatter side, so the road leans
	## around high ground instead of climbing it. It just can no longer tie itself in a knot doing so.
	var o := def.origin
	var half := def.area_size * 0.5
	var inset := half * 0.86
	# Start and finish on opposite corners, so the spine is the box's diagonal - the longest run
	# available, which leaves the wiggle amplitude small enough to stay inside the area.
	var a := Vector2(o.x - inset, o.z - inset)
	var b := Vector2(o.x + inset, o.z + inset)
	var span := b - a
	var spine_len := span.length()
	var dir := span / spine_len
	var nrm := Vector2(-dir.y, dir.x)

	var step := 22.0
	var n := maxi(8, int(ceil(spine_len / step)))

	# WAVELENGTH IS DERIVED FROM THE LENGTH TARGET, not chosen. A sinusoid of amplitude A and
	# wavelength L adds a length fraction of about (A*2*PI/L)^2 / 4, and the curvature limit caps
	# A at kmax*L^2/(4*PI^2). Substituting, the achievable gain is (kmax*L/(2*PI))^2 / 4, so the
	# wavelength that just reaches the target is L = 4*PI*sqrt(gain)/kmax. Solving for it rather
	# than picking it is what lets length_m, sinuosity and design_speed stay independent knobs.
	var gain := maxf(def.length_m / spine_len - 1.0, 0.0)
	var kmax := def.max_curvature()
	var wavelength := clampf(4.0 * PI * sqrt(gain) / maxf(kmax, 1e-6),
			4.0 * def.min_radius_m(), spine_len)
	return _solve_amplitude(a, dir, nrm, spine_len, n, wavelength)

func _solve_amplitude(a: Vector2, dir: Vector2, nrm: Vector2, spine_len: float, n: int,
		wavelength: float) -> PackedVector2Array:
	## Bisect the offset amplitude against the length the road ACTUALLY ends up with - after the
	## spline fit and after the min-radius relaxation, both of which shorten it. Solving against the
	## raw control polygon instead was measurably wrong: it hit 1200 m on the polygon and shipped a
	## 926 m road. Terminates on the length tolerance; the iteration cap is a non-convergence guard.
	var lo := 0.0
	var hi := spine_len * 0.35
	var best := PackedVector2Array()
	var tol := maxf(def.length_m * 0.02, 5.0)
	for _iter in range(24):
		var amp := (lo + hi) * 0.5
		var poly := _offset_polygon(a, dir, nrm, spine_len, n, amp, wavelength)
		if def.control_points.size() > 0:
			poly = _apply_control_points(poly)
		best = poly
		var got := _final_length(poly)
		if absf(got - def.length_m) <= tol:
			break
		if got < def.length_m:
			lo = amp
		else:
			hi = amp
	return best

func _final_length(poly: PackedVector2Array) -> float:
	var pts := _fit_spline(poly)
	for _p in range(RELAX_PASSES_MAX):
		var hot := _violations(pts)
		if hot.is_empty():
			break
		poly = _relax_polygon(poly, hot, pts.size())
		pts = _fit_spline(poly)
	return _polyline_length(pts)

func _offset_polygon(a: Vector2, dir: Vector2, nrm: Vector2, spine_len: float, n: int,
		amp: float, wavelength: float) -> PackedVector2Array:
	var out := PackedVector2Array(); out.resize(n + 1)
	# CHARACTER ENVELOPE. Without it every corner sits hard against the minimum radius, because the
	# relaxation drives them all to the same limit - measured: 7 of 9 corners came out the same
	# severity, a road with rhythm but no variety. A slow envelope over the stage makes some
	# sections open and fast and others tight and technical, which is what gives a road book more
	# than one severity to say. The envelope is a function of position along the stage, so it is
	# still fully determined by the seed.
	var env_phase := float(def.seed % 29) * 0.216
	var phase := float(def.seed % 61) * 0.103
	var prev_along := 0.0
	for i in range(n + 1):
		var u := float(i) / float(n)
		var along := u * spine_len
		# 0 = open sweeping section, 1 = tight technical section
		var tight := 0.5 + 0.5 * sin(TAU * u * 1.5 + env_phase)
		tight = clampf(tight * 0.85 + 0.15 * _noise.get_noise_2d(u * 260.0, 91.0), 0.0, 1.0)
		# tighter sections turn more often AND harder; both terms push curvature up together, which
		# is what actually separates a hairpin from a sweeper.
		var local_wl := wavelength * lerpf(1.45, 0.62, tight)
		var local_amp := lerpf(0.72, 1.18, tight)
		phase += TAU * (along - prev_along) / maxf(local_wl, 1.0)
		prev_along = along
		# Low-frequency shape so corners arrive in SEQUENCES rather than as independent noise -
		# "corners have rhythm" is the drive-checklist item this is aimed at.
		var w := sin(phase)
		w += 0.55 * _noise.get_noise_2d(along * 0.9, float(def.seed) * 0.21)
		w = clampf(w / 1.55, -1.0, 1.0) * local_amp
		# taper to zero at both ends so the start and finish lines sit exactly on the spine
		var taper := sin(PI * clampf(u, 0.0, 1.0))
		var lat := amp * w * taper * clampf(def.sinuosity, 0.05, 1.0)

		var base := a + dir * along
		# terrain bias: lean toward the flatter side, so the road contours instead of climbing.
		var probe := 26.0
		var hl := def.elevation_at(base.x + nrm.x * probe, base.y + nrm.y * probe)
		var hr := def.elevation_at(base.x - nrm.x * probe, base.y - nrm.y * probe)
		var lean := clampf((hr - hl) / 14.0, -1.0, 1.0) * clampf(def.elevation_character, 0.0, 1.0)
		lat += lean * amp * 0.35 * taper
		out[i] = base + nrm * lat
	return out

func _polyline_length(p: PackedVector2Array) -> float:
	var l := 0.0
	for i in range(p.size() - 1):
		l += p[i].distance_to(p[i + 1])
	return l

func _apply_control_points(poly: PackedVector2Array) -> PackedVector2Array:
	## Authored control points are HARD constraints (§1.2 answer 3): the road must pass through
	## them. Each is snapped onto the nearest polygon vertex and its neighbours are blended toward
	## it over a falloff, so the road bends to meet the point instead of kinking at it.
	var out := poly.duplicate()
	for cp in def.control_points:
		var best := 0
		var bd := INF
		for i in range(out.size()):
			var d := out[i].distance_squared_to(cp)
			if d < bd:
				bd = d; best = i
		var delta := cp - out[best]
		var reach := 6                       # vertices either side that share the correction
		for k in range(-reach, reach + 1):
			var i2 := best + k
			if i2 < 0 or i2 >= out.size():
				continue
			var w := 1.0 - absf(float(k)) / float(reach + 1)
			out[i2] = out[i2] + delta * smoothstep(0.0, 1.0, w)
		out[best] = cp                       # exact hit at the pinned vertex
	return out

func _fit_spline(poly: PackedVector2Array) -> PackedVector2Array:
	## CENTRIPETAL Catmull-Rom (alpha = 0.5). It passes through its control points, which is what
	## "authored waypoints" requires, and unlike the uniform parameterisation it cannot form a cusp
	## or self-intersect inside a segment.
	var out := PackedVector2Array()
	var n := poly.size()
	if n < 4:
		return poly
	var per_seg := maxi(2, int(ceil(22.0 * SAMPLES_PER_METRE)))
	for i in range(n - 1):
		# PHANTOM ENDPOINTS. Clamping p0/p3 to the first/last control point makes them coincide with
		# p1/p3 at the ends, which collapses the centripetal knot spacing to zero and drops the end
		# segments entirely - leaving a single 22 m gap in an otherwise 1.2 m polyline. That gap then
		# broke the grade limiter, which smooths against neighbours and cannot cope with a 20x
		# spacing jump. Reflecting the end points instead gives the spline a real tangent to start
		# and finish on.
		var p0 := poly[i - 1] if i >= 1 else poly[0] * 2.0 - poly[1]
		var p1 := poly[i]
		var p2 := poly[i + 1]
		var p3 := poly[i + 2] if i + 2 <= n - 1 else poly[n - 1] * 2.0 - poly[n - 2]
		var t0 := 0.0
		var t1 := t0 + pow(p0.distance_to(p1), 0.5)
		var t2 := t1 + pow(p1.distance_to(p2), 0.5)
		var t3 := t2 + pow(p2.distance_to(p3), 0.5)
		if t1 <= t0 or t2 <= t1 or t3 <= t2:
			out.append(p1)
			continue
		for k in range(per_seg):
			var t := lerpf(t1, t2, float(k) / float(per_seg))
			var a1 := p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
			var a2 := p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
			var a3 := p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
			var b1 := a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
			var b2 := a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
			out.append(b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1)))
	out.append(poly[n - 1])
	return out

func _curvature_at(pts: PackedVector2Array, i: int) -> float:
	if i <= 0 or i >= pts.size() - 1:
		return 0.0
	var a := pts[i - 1]; var b := pts[i]; var c := pts[i + 1]
	var h0 := b - a
	var h1 := c - b
	if h0.length() < 1e-5 or h1.length() < 1e-5:
		return 0.0
	var dphi := atan2(h0.x * h1.y - h0.y * h1.x, h0.dot(h1))
	return absf(dphi) / maxf((h0.length() + h1.length()) * 0.5, 0.01)

func _build_centreline(pts: PackedVector2Array) -> void:
	var n := pts.size()
	var world := PackedVector3Array(); world.resize(n)
	var hw := PackedFloat32Array(); hw.resize(n)
	for i in range(n):
		var p := pts[i]
		world[i] = Vector3(p.x, def.elevation_at(p.x, p.y), p.y)
		# width profile: the road pinches and opens along its length, low-frequency so it reads as
		# the road narrowing through a section rather than flickering
		var t := float(i) / maxf(float(n - 1), 1.0)
		var w := 1.0 - def.width_var * (0.5 + 0.5 * sin(t * TAU * 2.3 + float(def.seed % 17)))
		hw[i] = def.width_m * 0.5 * w
	world = _limit_grade(world)                              # cut and fill: the VERTICAL constraint
	centreline = Centreline.from_points(world, hw, false)     # OPEN: a stage is a route, not a lap

func _limit_grade(world: PackedVector3Array) -> PackedVector3Array:
	## The vertical constraint, and the reason a generated road looks BUILT rather than painted on.
	## Raw terrain here reaches a 33% grade; real roads cut into high ground and fill across low
	## ground to hold a workable gradient. The cut and fill this produces IS the earthworks, and the
	## corridor flatten then blends the terrain to meet the road.
	##
	## EXACT, and it terminates in four sweeps - no iteration cap and nothing to not-converge.
	## Two approaches were tried and discarded first, both measured:
	##   - Laplacian smoothing: a diffusion process, so relaxing a steep run of k samples costs
	##     O(k^2) passes. 256 passes left 24.6% against a 12% limit.
	##   - Splitting each violating segment's excess between its endpoints: a valid convex
	##     projection, but Gauss-Seidel-slow. 1024 passes still left 18.7% on one seed.
	## The standard grade limiter is a slope-limited sweep. Clamping forward then backward with a
	## MINIMUM yields the highest feasible profile that never rises above the terrain (pure cut);
	## the same sweeps with a MAXIMUM yield the lowest feasible profile that never drops below it
	## (pure fill). Both are feasible, the feasible set is convex, so their average is feasible too -
	## and averaging is what balances cut against fill instead of only digging.
	var n := world.size()
	if n < 3:
		return world
	var g := maxf(def.max_grade, 0.005)
	var ds := PackedFloat32Array(); ds.resize(n)
	for i in range(n - 1):
		ds[i] = Vector2(world[i + 1].x - world[i].x, world[i + 1].z - world[i].z).length()
	ds[n - 1] = 0.0

	var hi := PackedFloat32Array(); hi.resize(n)     # pure-cut envelope
	var lo := PackedFloat32Array(); lo.resize(n)     # pure-fill envelope
	for i in range(n):
		hi[i] = world[i].y
		lo[i] = world[i].y
	for i in range(1, n):
		hi[i] = minf(hi[i], hi[i - 1] + g * ds[i - 1])
	for i in range(n - 2, -1, -1):
		hi[i] = minf(hi[i], hi[i + 1] + g * ds[i])
	for i in range(1, n):
		lo[i] = maxf(lo[i], lo[i - 1] - g * ds[i - 1])
	for i in range(n - 2, -1, -1):
		lo[i] = maxf(lo[i], lo[i + 1] - g * ds[i])

	var out := world.duplicate()
	for i in range(n):
		var v: Vector3 = out[i]
		v.y = (hi[i] + lo[i]) * 0.5
		out[i] = v
	return _limit_vertical_curvature(out, ds)

func _limit_vertical_curvature(world: PackedVector3Array, ds: PackedFloat32Array) -> PackedVector3Array:
	## VERTICAL CURVES - the other half of a road's vertical alignment, and the half whose absence
	## made the grade limiter actively harmful. Clamping a slope leaves a CORNER where the clamp
	## stops biting, and a corner is a curvature spike: measured, the grade-limited stage held 12%
	## slope everywhere (gentler than the rally loop's 20.7%) while feeding the suspension a peak
	## d2y/ds2 of 0.110 1/m against the rally loop's 0.012 - nine times worse, 10 g of wheel
	## acceleration at 108 km/h. Real roads join their grades with parabolic vertical curves sized
	## so the vertical acceleration stays comfortable at the design speed, which is exactly the
	## constraint applied here (AASHTO's ~0.3 m/s^2).
	var n := world.size()
	if n < 5:
		return world
	var kv := def.max_vertical_curvature()
	var out := world.duplicate()
	# Binomial (1-2-1) smoothing of the elevation profile, run until the curvature constraint holds.
	# Terminates on the constraint, not on a pass count.
	for _pass in range(4000):   # binomial smoothing converges slowly; this is a guard, not the exit
		var worst := 0.0
		for i in range(1, n - 1):
			var h := maxf((ds[i - 1] + ds[i]) * 0.5, 0.05)
			worst = maxf(worst, absf(out[i + 1].y - 2.0 * out[i].y + out[i - 1].y) / (h * h))
		if worst <= kv:
			return out
		var nxt := out.duplicate()
		for i in range(1, n - 1):
			var v: Vector3 = nxt[i]
			v.y = 0.25 * out[i - 1].y + 0.5 * out[i].y + 0.25 * out[i + 1].y
			nxt[i] = v
		out = nxt
	push_warning("StageGen: vertical curvature limiting did not converge")
	return out

# ---------------------------------------------------------------- reporting (probes read these)

func control_polygon() -> PackedVector2Array:
	return _control

func relax_passes_used() -> int:
	return _relax_used

func worst_curvature() -> float:
	return _worst_curvature
