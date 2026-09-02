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
var timed_start_s := 0.0                  ## arc length of the START line (end of the run-up)
var timed_end_s := 0.0                    ## arc length of the FINISH line (start of the runoff)
var _spine_pts: PackedVector2Array = PackedVector2Array()
var _arc_lo := 0
var _arc_hi := 0
var _hairpin_r := 0.0
var _hairpin_sweep := 0.0
var _pre_n := 0                           ## extension sample counts, so _build_centreline can hold
var _post_n := 0                          ## the start area and runoff pad FLAT
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
	## Corners tighter than the design speed allows - EXCLUDING the hairpin, which is built at a
	## known legal radius and is deliberately exempt from relaxation. Counting it here made the
	## non-convergence warning permanent: the spline overshoots the arc slightly, relaxation is not
	## allowed to touch it, so the "violation" could never clear. The hairpin's delivered radius is
	## reported separately by hairpin_radius() instead of being hidden in this count.
	var kmax := def.max_curvature()
	var n := _spine_pts.size()
	var dn := pts.size()
	var hot := PackedInt32Array()
	for i in range(dn):
		if _curvature_at(pts, i) > kmax * 1.02:   # 2% tolerance: an exact test flags rounding noise
			var v := int(round(float(i) * float(maxi(n - 1, 1)) / float(maxi(dn - 1, 1))))
			if v >= _arc_lo - 2 and v <= _arc_hi + 2:
				continue
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
		# LEAVE THE HAIRPIN ALONE. It is built at 1.12x the minimum radius, so it is legal by
		# construction and has nothing to relax - but smoothing a vertex toward its neighbours'
		# midpoint FLATTENS an arc, and running that on the hairpin every refit walked a 130-degree
		# turn down to 96 and still did not converge. The relaxation exists for the offset wiggle.
		if i >= _arc_lo and i <= _arc_hi:
			continue
		out[i] = poly[i].lerp((poly[i - 1] + poly[i + 1]) * 0.5, 0.45 * touch[i])
	if def.control_points.size() > 0:
		out = _apply_control_points(out)
	return out

func _route() -> PackedVector2Array:
	## A stage is a ROUTE from a start line to a finish line (§1.2 answer 1), built as a bounded
	## lateral offset along a SPINE. Parameterised monotonically along that spine, the road is a
	## GRAPH over it and therefore cannot self-intersect - a structural guarantee, not a test.
	##
	## The spine BENDS. A straight spine confines the road's heading to +-90 degrees of it, so a
	## hairpin - a turn of more than 90 degrees - is impossible by construction, which is why the
	## first version could not produce one at any sinuosity. The spine now runs out to an apex and
	## doubles back, and the road is filleted through that apex at the tightest radius the design
	## speed allows. That IS the hairpin; everything else is offset wiggle either side of it.
	##
	## The offset tapers to zero through the hairpin, which is both realistic (a real hairpin is a
	## clean constant-radius turn, not a wiggly one) and what keeps the graph property safe where
	## the spine's own curvature is highest.
	var o := def.origin
	var half := def.area_size * 0.5
	# The inset must pay for the run-up and runoff, which stick straight out past both ends, AND
	# clear half a road width plus its shoulder, or the road surface overhangs the mesh edge.
	var ext := maxf(def.start_runup_m, def.finish_runoff_m)
	var edge_margin: float = 12.0 + def.width_m * 0.5 + 8.0
	var inset := maxf(half - edge_margin - ext, half * 0.30)

	# LENGTH AND CHARACTER ARE SEPARATE KNOBS, and were not before. Solving the spine for a fraction
	# of the target and then bisecting AMPLITUDE for the rest chased its own tail: after tapering
	# around the hairpin and both ends, the wiggle contributes almost nothing to length, so the two
	# solves fought and the stage always came out ~10% short. Now:
	#   - `sinuosity` sets the offset amplitude, as a fraction of what the curvature limit allows.
	#     It controls how much the road WEAVES - its character - and nothing else.
	#   - the apex position is bisected so the FINISHED road (offset, fitted and relaxed) comes out
	#     at `length_m`. Length is a property of the route, which is what a route length is.
	var lo := 0.06
	var hi := 0.95
	var apex := 0.5
	var best := PackedVector2Array()
	for _i in range(16):
		apex = (lo + hi) * 0.5
		var sp := _spine(apex, inset, o)
		if sp.size() < 2:
			break
		var poly := _offset_polygon(sp, _amplitude_for(sp))
		if def.control_points.size() > 0:
			poly = _apply_control_points(poly)
		_spine_pts = sp
		best = poly
		if _final_length(poly) < def.length_m:
			lo = apex
		else:
			hi = apex
	return best

func _amplitude_for(spine: PackedVector2Array) -> float:
	## How far the road weaves either side of its route. Bounded by the curvature limit - a sinusoid
	## of amplitude A and wavelength L peaks at A(2*PI/L)^2 - so sinuosity 1.0 is "as twisty as the
	## design speed permits" and cannot ask for a corner the constraint set forbids.
	var wl := _wavelength_for(spine)
	var legal := def.max_curvature() * wl * wl / (4.0 * PI * PI)
	return clampf(def.sinuosity, 0.05, 1.0) * legal

func _wavelength_for(_spine: PackedVector2Array) -> float:
	## How OFTEN the road changes direction, in metres per weave. Expressed in minimum radii so it
	## scales with the design speed: a tighter road turns more often as well as more sharply.
	# Measured: a 296 m weave over a 900 m stage gave 2.9 corners/km, which reads as a long road with
	# almost nothing on it. Real stages are far busier than that. Tightening the mapping raises the
	# corner count directly, and the amplitude bound above keeps every one of them legal.
	return def.min_radius_m() * lerpf(11.0, 3.5, clampf(def.sinuosity, 0.0, 1.0))

func _spine(apex_frac: float, inset: float, o: Vector3) -> PackedVector2Array:
	## Out to an apex and back, with the apex filleted at the tightest radius the design speed
	## allows - so the fillet IS a hairpin rather than a kink the relaxation would have to open up.
	var a := Vector2(o.x - inset, o.z - inset * 0.62)
	var b := Vector2(o.x + inset * apex_frac, o.z)
	var c := Vector2(o.x - inset, o.z + inset * 0.62)
	var d1 := (a - b).normalized()
	var d2 := (c - b).normalized()
	var cosphi := clampf(d1.dot(d2), -0.9999, 0.9999)
	var phi := acos(cosphi)                                  # interior angle at the apex
	var r := def.hairpin_radius_m()                          # its OWN design speed, not the road's
	var tanlen := r / maxf(tan(phi * 0.5), 0.05)
	var maxtan := minf((a - b).length(), (c - b).length()) * 0.8
	if tanlen > maxtan:
		tanlen = maxtan
		r = tanlen * tan(phi * 0.5)
	var p1 := b + d1 * tanlen
	var p2 := b + d2 * tanlen
	var bis := (d1 + d2).normalized()
	var centre := b + bis * (r / maxf(sin(phi * 0.5), 0.05))

	var out := PackedVector2Array()
	# Fine spine steps around a tight arc: the Catmull-Rom fit overshoots where curvature changes
	# abruptly, and sparse control points make that worse. Real roads use transition spirals for the
	# same reason; densifying is the cheap stand-in.
	var step := 2.0
	# straight in
	var seg1 := (p1 - a).length()
	var n1 := maxi(2, int(ceil(seg1 / step)))
	for i in range(n1):
		out.append(a.lerp(p1, float(i) / float(n1)))
	# the hairpin arc itself
	var ang1 := (p1 - centre).angle()
	var ang2 := (p2 - centre).angle()
	var sweep := wrapf(ang2 - ang1, -PI, PI)
	var narc := maxi(6, int(ceil(absf(sweep) * r / step)))
	_arc_lo = out.size()
	for i in range(narc + 1):
		var t := float(i) / float(narc)
		var ang := ang1 + sweep * t
		out.append(centre + Vector2(cos(ang), sin(ang)) * r)
	_arc_hi = out.size() - 1
	# straight out
	var seg2 := (c - p2).length()
	var n2 := maxi(2, int(ceil(seg2 / step)))
	for i in range(1, n2 + 1):
		out.append(p2.lerp(c, float(i) / float(n2)))
	_hairpin_r = r
	_hairpin_sweep = absf(sweep)
	return out

func _offset_polygon(spine: PackedVector2Array, amp: float) -> PackedVector2Array:
	var n := spine.size()
	var out := PackedVector2Array(); out.resize(n)
	var total := _polyline_length(spine)
	var env_phase := float(def.seed % 29) * 0.216
	var phase := float(def.seed % 61) * 0.103
	var wavelength: float = minf(_wavelength_for(spine), maxf(total, 1.0))
	# TAPER LENGTH IS DERIVED FROM THE CURVATURE LIMIT, not picked. Ramping the offset from zero to
	# amplitude A over a length L is itself a corner: a smoothstep ramp peaks at 6A/L^2 of curvature,
	# so L must be at least sqrt(6A/kmax) or the taper alone violates the minimum radius. A picked
	# 60 m ramp produced 12.2 m corners against a 30.8 m limit, and the relaxation could not open
	# them because the taper kept re-creating them on the next refit.
	var spacing: float = total / float(maxi(n - 1, 1))
	var taper_len: float = sqrt(6.0 * maxf(amp, 0.01) / maxf(def.max_curvature(), 1e-6))
	var taper_samples := maxi(4, int(ceil(taper_len / maxf(spacing, 0.1))))
	var along := 0.0
	var prev_along := 0.0
	for i in range(n):
		if i > 0:
			along += spine[i].distance_to(spine[i - 1])
		var u := along / maxf(total, 1.0)
		# CHARACTER ENVELOPE: open sweeping sections alternating with tight technical ones, so the
		# road book has more than one severity to say.
		var tight := 0.5 + 0.5 * sin(TAU * u * 1.5 + env_phase)
		tight = clampf(tight * 0.85 + 0.15 * _noise.get_noise_2d(u * 260.0, 91.0), 0.0, 1.0)
		var local_wl := wavelength * lerpf(1.45, 0.62, tight)
		var local_amp := lerpf(0.72, 1.18, tight)
		phase += TAU * (along - prev_along) / maxf(local_wl, 1.0)
		prev_along = along
		var w := sin(phase) + 0.55 * _noise.get_noise_2d(along * 0.9, float(def.seed) * 0.21)
		w = clampf(w / 1.55, -1.0, 1.0) * local_amp

		# taper to zero at both ends (so start and finish sit on the spine) AND through the
		# hairpin (a real hairpin is a clean constant-radius turn, and a flat offset there is what
		# keeps the graph-over-the-spine guarantee safe where spine curvature is highest)
		# End taper over a FIXED DISTANCE, not a half-sine across the whole road. The half-sine held
		# the weave below the corner-detection threshold for the entire first and last third -
		# measured, every corner on a 1 km stage fell between 397 m and 718 m, with nothing to call
		# either side of that. Its only job is to put the start and finish lines on the spine, and
		# that only needs the last few dozen metres.
		var taper: float = smoothstep(0.0, taper_len, along) * smoothstep(0.0, taper_len, total - along)
		var d_arc := 0
		if i < _arc_lo:
			d_arc = _arc_lo - i
		elif i > _arc_hi:
			d_arc = i - _arc_hi
		# smoothstep, not linear: a linear ramp has a kink at each end, which is a curvature spike
		taper *= smoothstep(0.0, 1.0, clampf(float(d_arc) / float(taper_samples), 0.0, 1.0))

		var tangent: Vector2 = (spine[mini(i + 1, n - 1)] - spine[maxi(i - 1, 0)]).normalized()
		var nrm := Vector2(-tangent.y, tangent.x)
		var base := spine[i]
		var probe := 26.0
		var hl := def.elevation_at(base.x + nrm.x * probe, base.y + nrm.y * probe)
		var hr := def.elevation_at(base.x - nrm.x * probe, base.y - nrm.y * probe)
		var lean := clampf((hr - hl) / 14.0, -1.0, 1.0) * clampf(def.elevation_character, 0.0, 1.0)
		var lat := amp * (w + lean * 0.35) * taper * clampf(def.sinuosity, 0.05, 1.0)
		out[i] = base + nrm * lat
	return out

func _final_length(poly: PackedVector2Array) -> float:
	## The length the road ACTUALLY ends up with: fitted and relaxed, not the raw control polygon.
	var pts := _fit_spline(poly)
	for _p in range(RELAX_PASSES_MAX):
		var hot := _violations(pts)
		if hot.is_empty():
			break
		poly = _relax_polygon(poly, hot, pts.size())
		pts = _fit_spline(poly)
	return _polyline_length(pts)

func hairpin_radius() -> float:
	return _hairpin_r

func hairpin_sweep_deg() -> float:
	return rad_to_deg(_hairpin_sweep)

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
		# Sample density follows the SEGMENT LENGTH. This used to be a fixed 18 samples per segment,
		# a number tied to the 22 m control spacing the first router happened to use - so halving the
		# spine step to 2 m silently made the spline 9x denser and generation took minutes.
		var per_seg := maxi(2, int(ceil(p1.distance_to(p2) * SAMPLES_PER_METRE)))
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

func _extend_ends(pts: PackedVector2Array) -> PackedVector2Array:
	## Add straight tangent run-up and runoff. They are added BEFORE the vertical constraints run, so
	## the grade limiter and the vertical-curve constraint smooth the join automatically instead of
	## leaving a kink where the flat start area meets a sloping road - which is the same trap that
	## made grade limiting alone worse than useless.
	var n := pts.size()
	if n < 2:
		return pts
	# MATCH THE ROAD'S OWN SAMPLE SPACING. A fixed 4 m step against the road's ~1.65 m samples puts
	# a 2.4x spacing jump at each join, and the vertical smoother - like every stencil of its kind -
	# assumes uniform spacing, so it cannot settle there. Measured with a fixed step: peak d2y/ds2
	# 0.0512 against 0.0122 with matched spacing, i.e. 4.7 g of wheel acceleration at 108 km/h
	# instead of 1.1 g, from nothing but two joins. Same trap as the spline's phantom endpoints.
	var step := _polyline_length(pts) / maxf(float(n - 1), 1.0)
	var head := (pts[0] - pts[1]).normalized()             # points BACK from the start
	var tail := (pts[n - 1] - pts[n - 2]).normalized()     # points ON past the finish
	# THE RUN-UP AND RUNOFF REACH THE EDGE OF THE MAP (driver, 2026-09-01). The tunnel that joins the
	# areas has to meet a ROAD, not a hillside: photographed on one seed, the mouth sat behind a rise
	# with no way to it, because the road stopped ~70 m short of the boundary and a flat pad was
	# expected to bridge terrain it could not cut. Carrying the road itself to the edge solves it at
	# the root - the stage area's corridor blend already grades terrain down to its own road surface,
	# so the approach becomes a proper cutting for free and the pad shrinks to a few metres.
	#
	# The spine is untouched, so the TIMED stage is identical; only the approach lengthens.
	var half_a: float = def.area_size * 0.5
	var run_m: float = maxf(def.start_runup_m, _dist_to_edge(pts[0], head, half_a) + 1.0)
	var off_m: float = maxf(def.finish_runoff_m, _dist_to_edge(pts[n - 1], tail, half_a) + 1.0)
	var pre := int(ceil(run_m / step))
	var post := int(ceil(off_m / step))
	var out := PackedVector2Array()
	for i in range(pre, 0, -1):
		out.append(pts[0] + head * (float(i) * step))
	out.append_array(pts)
	for i in range(1, post + 1):
		out.append(pts[n - 1] + tail * (float(i) * step))
	timed_start_s = float(pre) * step
	timed_end_s = timed_start_s + _polyline_length(pts)
	# Say so when the constraint set beat the length target, instead of silently shipping a short
	# stage. Length is a soft target; minimum radius, maximum grade and the area's own edges are
	# hard, and where they conflict the constraints win - which is correct, but must not be silent.
	var achieved := timed_end_s - timed_start_s
	if absf(achieved - def.length_m) > def.length_m * 0.05:
		push_warning("StageGen: timed length %.0f m vs target %.0f m - the constraint set is binding (min radius %.1f m, usable spine limited by run-up %.0f m + runoff %.0f m + corridor clearance)"
				% [achieved, def.length_m, def.min_radius_m(), def.start_runup_m, def.finish_runoff_m])
	_pre_n = pre
	_post_n = post
	return out

func _dist_to_edge(p: Vector2, dir: Vector2, half: float) -> float:
	## How far from `p` along `dir` before leaving the area box. Solved, not walked.
	var t := INF
	if absf(dir.x) > 1e-6:
		t = minf(t, ((def.origin.x + (half if dir.x > 0.0 else -half)) - p.x) / dir.x)
	if absf(dir.y) > 1e-6:
		t = minf(t, ((def.origin.z + (half if dir.y > 0.0 else -half)) - p.y) / dir.y)
	return maxf(t, 0.0) if t < 1e17 else 0.0

func _build_centreline(pts_in: PackedVector2Array) -> void:
	var pts := _extend_ends(pts_in)
	var n := pts.size()
	var world := PackedVector3Array(); world.resize(n)
	var hw := PackedFloat32Array(); hw.resize(n)
	for i in range(n):
		var p := pts[i]
		world[i] = Vector3(p.x, def.elevation_at(p.x, p.y), p.y)
		hw[i] = def.width_m * 0.5
	# A start area and a runoff pad are FLAT in reality - they are built platforms, not road that
	# happens to follow the hillside. Holding them level at the elevation of the line they serve also
	# keeps terrain roughness out of the two joins, which is where the vertical profile is most
	# fragile. The grade and vertical-curve limiters below then smooth the join into the road.
	#
	# THE APPROACH CLIMBS TO DAYLIGHT. Holding it dead level was right when it was 45 m of launch
	# pad, and wrong once D5 stretched it to the map edge: the road's ends sit in a CUTTING - 5 to
	# 7 m deep on most seeds, measured - so a level approach carried that trench all the way to the
	# boundary and the tunnel mouth ended up at the bottom of it. The driver saw exactly that:
	# "the height of the tunnel is not even close to the map - so its completely under it".
	# Ramping the approach out to the natural ground it meets at the edge is what a real road does
	# where it leaves a cutting for a portal, and it puts the mouth at surface level, which is what
	# lets the transition pad be level rather than a wall.
	# Grade-limited, so it stays a road: over a 70 m approach at max_grade 12% this can lift ~8 m,
	# which covers the cuttings the generator actually produces.
	if _pre_n > 0 and n > _pre_n:
		var y0: float = world[_pre_n].y
		var pe: Vector3 = world[0]
		var target0: float = float(def.elevation_at(pe.x, pe.z))
		var run_len: float = float(_pre_n) * _polyline_length(pts) / maxf(float(n - 1), 1.0)
		var lift0: float = clampf(target0 - y0, -def.max_grade * run_len, def.max_grade * run_len)
		for k in range(_pre_n):
			var f0: float = 1.0 - float(k) / float(_pre_n)      # 1 at the outer end, 0 at the gate
			world[k] = Vector3(world[k].x, y0 + lift0 * f0 * f0 * (3.0 - 2.0 * f0), world[k].z)
	if _post_n > 0 and n > _post_n:
		var y1: float = world[n - 1 - _post_n].y
		var pf: Vector3 = world[n - 1]
		var target1: float = float(def.elevation_at(pf.x, pf.z))
		var off_len: float = float(_post_n) * _polyline_length(pts) / maxf(float(n - 1), 1.0)
		var lift1: float = clampf(target1 - y1, -def.max_grade * off_len, def.max_grade * off_len)
		for k in range(n - _post_n, n):
			var f1: float = float(k - (n - _post_n)) / float(_post_n)
			world[k] = Vector3(world[k].x, y1 + lift1 * f1 * f1 * (3.0 - 2.0 * f1), world[k].z)
	# CURVE WIDENING. Roads are built wider through tight bends because a long vehicle's rear wheels
	# cut inside its front ones, so its swept path is wider than the vehicle: W = L^2/(2R). That is
	# also exactly the runoff room a hairpin wants. Applied symmetrically, from the LOCAL curvature,
	# so the road opens up through every bend and opens most through the tightest one.
	for i in range(n):
		var im := maxi(i - 1, 0)
		var ip := mini(i + 1, n - 1)
		var u0 := Vector2(world[i].x - world[im].x, world[i].z - world[im].z)
		var v0 := Vector2(world[ip].x - world[i].x, world[ip].z - world[i].z)
		var k := 0.0
		if u0.length() > 1e-5 and v0.length() > 1e-5:
			var dphi := atan2(u0.x * v0.y - u0.y * v0.x, u0.dot(v0))
			k = absf(dphi) / maxf((u0.length() + v0.length()) * 0.5, 0.01)
		var tight: float = clampf(k / maxf(def.max_curvature(), 1e-5), 0.0, 1.0)
		# The pinch/open profile is SUPPRESSED where the road is tight. A road narrows on straights
		# and open bends; it does not narrow at a hairpin. Measured before this: the pinch happened
		# to bottom out exactly at the hairpin and cancelled the whole widening, so a corner that
		# should have opened to 9.9 m came out at 7.8 m.
		var t := float(i) / maxf(float(n - 1), 1.0)
		var pinch := (0.5 + 0.5 * sin(t * TAU * 2.3 + float(def.seed % 17))) * (1.0 - tight)
		hw[i] = def.width_m * 0.5 * (1.0 - def.width_var * pinch) \
				+ def.curve_widening_m(k) * 0.5              # half the total widening per side
	world = _limit_grade(world)                              # cut and fill: the VERTICAL constraint
	# AND THE APPROACH WIDENS toward the map edge. A funnel is what a real road does where it meets a
	# junction or a tunnel portal, and it is what makes the mouth findable and enterable at speed
	# rather than a slot you have to hit exactly. Applied after the curve widening and the pinch so
	# neither overwrites it.
	var flare: float = def.width_m * 0.5 + def.approach_flare_m
	for k in range(_pre_n):
		var u: float = 1.0 - float(k) / float(maxi(_pre_n, 1))     # 1 at the map edge, 0 at the road
		hw[k] = maxf(hw[k], lerpf(hw[k], flare, u * u))
	for k in range(n - _post_n, n):
		var u2: float = float(k - (n - _post_n)) / float(maxi(_post_n, 1))
		hw[k] = maxf(hw[k], lerpf(hw[k], flare, u2 * u2))
	centreline = Centreline.from_points(world, hw, false)     # OPEN: a stage is a route, not a lap
	_build_bank_curvature()

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

var _bank_k: PackedFloat32Array = PackedFloat32Array()
var _bank_ds := 1.0

func bank_curvature_at(s_in: float) -> float:
	## Curvature for SUPERELEVATION, smoothed over the length a real road takes to roll into a
	## corner. The raw per-sample curvature cannot be used for this: it is a numerical second
	## difference over ~1.6 m of a relaxed spline, and it was measured swinging 0.023 1/m over 2 m
	## of road - 70% of the whole design range. Multiplied by the lateral lever arm that produced a
	## 0.56 m height step between neighbouring terrain samples, which is what "jagged edges where
	## the ground meets the track" was.
	##
	## The smoothing window is DERIVED, not picked: superelevation is developed over a transition
	## whose conventional length is the distance covered in about two seconds at the design speed.
	if _bank_k.is_empty():
		return 0.0
	var i := clampi(int(round(s_in / maxf(_bank_ds, 0.01))), 0, _bank_k.size() - 1)
	return _bank_k[i]

func _build_bank_curvature() -> void:
	var cl := centreline
	var n := cl.sample_count()
	if n < 3:
		return
	_bank_ds = cl.length() / maxf(float(n - 1), 1.0)
	var raw := PackedFloat32Array(); raw.resize(n)
	for i in range(n):
		raw[i] = float(cl.point_at(float(i) * _bank_ds)["curvature"])
	var window_m: float = (def.design_speed_kmh / 3.6) * 2.0     # superelevation runoff length
	var half_w := maxi(1, int(round(window_m * 0.5 / maxf(_bank_ds, 0.01))))
	_bank_k = PackedFloat32Array(); _bank_k.resize(n)
	for i in range(n):
		var acc := 0.0
		var cnt := 0
		for j in range(i - half_w, i + half_w + 1):
			if j < 0 or j >= n:
				continue
			acc += raw[j]
			cnt += 1
		_bank_k[i] = acc / maxf(float(cnt), 1.0)

func control_polygon() -> PackedVector2Array:
	return _control

func relax_passes_used() -> int:
	return _relax_used

func worst_curvature() -> float:
	return _worst_curvature
