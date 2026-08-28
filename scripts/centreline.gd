extends RefCounted
class_name Centreline
## C1.0 — arc-length-parameterised centreline abstraction (Phase C1.0 of
## docs/PLAN-drivetrain-suspension.md, moved forward from Arc D's D2 on 2026-08-13 so it lands
## before anything, including C1's own washboard term, depends on the definition of `s`).
##
## Splines are not naturally arc-length parameterised, so this builds a dense cumulative-distance
## table and inverts it by binary search - that table IS the `s` axis, the same one wear.gd and
## pace_notes.gd already build for themselves by sampling _road(th)/_asphalt_r(th). C1 expresses
## the existing polar roads through this shared interface with NO geometry change; Arc D later
## adds open (non-loop) roads on top without moving anything C1 tuned.

var _pts: PackedVector3Array        # sampled centreline points, world space
var _s: PackedFloat32Array          # cumulative arc length at each sample; _s[0] == 0
var _seglen: PackedFloat32Array     # length of segment i -> i+1 (wraps for the last sample)
var _heading: PackedVector2Array    # unit tangent (XZ) at each sample
var _curvature: PackedFloat32Array  # signed curvature at each sample (1/m)
var _halfwidth: PackedFloat32Array
var _length := 0.0
var _loop := true
var _n := 0

# nearest_point is called per wheel per physics frame - bin samples into a coarse uniform grid
# keyed by world position so each query only searches a handful of candidates, not thousands.
# D2: set only by from_polar(). The legacy map's roads are r = f(theta) sampled uniformly in
# THETA, and wear.gd has always indexed its field by round(theta/TAU * n). Recording that here lets
# sample_index_at() reproduce that mapping bit-for-bit on the calibration bed (plan §1.1: the
# existing map is preserved untouched) while a generated, non-polar stage takes the general path.
var _polar := false
var _polar_center := Vector3.ZERO
var _polar_r: PackedFloat32Array = PackedFloat32Array()   # the r = f(theta) each sample was built from

var _grid: Dictionary = {}
var _cell_size := 20.0
var _min_x := 0.0
var _min_z := 0.0
var _max_ring := 8

static func from_polar(center: Vector3, radius_fn: Callable, halfwidth_fn: Callable,
		height_fn: Callable, samples: int) -> Centreline:
	var cl := Centreline.new()
	cl._loop = true
	cl._polar = true
	cl._polar_center = center
	cl._n = samples
	cl._pts = PackedVector3Array(); cl._pts.resize(samples)
	cl._halfwidth = PackedFloat32Array(); cl._halfwidth.resize(samples)
	cl._polar_r = PackedFloat32Array(); cl._polar_r.resize(samples)
	for i in range(samples):
		var th := TAU * float(i) / float(samples)
		var r: float = radius_fn.call(th)
		cl._polar_r[i] = r
		var p := center + Vector3(cos(th), 0.0, sin(th)) * r
		if height_fn.is_valid():
			p.y = height_fn.call(p.x, p.z)
		cl._pts[i] = p
		cl._halfwidth[i] = halfwidth_fn.call(th) if halfwidth_fn.is_valid() else 0.0
	cl._finish_build()
	return cl

static func from_points(pts: PackedVector3Array, halfwidths: PackedFloat32Array,
		loop: bool) -> Centreline:
	## D2: the general constructor. from_polar() is the legacy map's shape; a point-to-point stage
	## is a list of points that does NOT wrap, and every wrap-around below is now conditional on
	## _loop so the same class serves both topologies.
	var cl := Centreline.new()
	cl._loop = loop
	cl._n = pts.size()
	cl._pts = pts
	cl._halfwidth = halfwidths
	cl._finish_build()
	return cl

# ---------------------------------------------------------------- sample access
# D2 consumers (pace_notes, wear) keep their OWN sample density and their own arc maths, and take
# only the GEOMETRY from here by striding. That is what makes the re-parameterisation exact: they
# read the same points they used to compute from stage._road(theta), so their output is unchanged,
# but they no longer know the road is polar - which is the whole point, because D3 replaces it.

func sample_count() -> int:
	return _n

func point_index(i: int) -> Vector3:
	return _pts[i]

func halfwidth_index(i: int) -> float:
	return _halfwidth[i]

func s_index(i: int) -> float:
	return _s[i]

func polar_radius_index(i: int) -> float:
	## The radius this sample was BUILT from, handed back verbatim. wear.gd needs r (not a point)
	## because its cell mapping is a signed RADIAL offset, and recovering r from the point would
	## round-trip through cos/sin and could shift a cell boundary by an ulp - which would move
	## C1's washboard mask. Only meaningful on a polar-built centreline; -1 otherwise.
	return _polar_r[i] if _polar and i < _polar_r.size() else -1.0

func _finish_build() -> void:
	_seglen = PackedFloat32Array(); _seglen.resize(_n)
	_s = PackedFloat32Array(); _s.resize(_n)
	_heading = PackedVector2Array(); _heading.resize(_n)
	var s := 0.0
	for i in range(_n):
		_s[i] = s
		# An OPEN centreline has no segment leaving its last sample: the road ends there. Giving it
		# a zero-length segment (rather than one wrapping to the start) is what stops a point-to-point
		# run from silently teleporting its arc length back to 0 at the finish.
		if i == _n - 1 and not _loop:
			_seglen[i] = 0.0
			_heading[i] = _heading[i - 1] if _n > 1 else Vector2(1, 0)
			continue
		var a := _pts[i]
		var b := _pts[(i + 1) % _n]
		var seg := Vector2(b.x - a.x, b.z - a.z)
		_seglen[i] = seg.length()
		_heading[i] = seg.normalized() if _seglen[i] > 1e-6 else Vector2(1, 0)
		s += _seglen[i]
	_length = s
	_curvature = PackedFloat32Array(); _curvature.resize(_n)
	for i in range(_n):
		if not _loop and (i == 0 or i == _n - 1):
			_curvature[i] = 0.0            # open ends have no incoming/outgoing pair to difference
			continue
		var h0 := _heading[(i - 1 + _n) % _n]
		var h1 := _heading[i]
		var dphi := atan2(h0.x * h1.y - h0.y * h1.x, h0.dot(h1))
		var denom := maxf((_seglen[(i - 1 + _n) % _n] + _seglen[i]) * 0.5, 0.01)
		_curvature[i] = dphi / denom
	_build_grid()

func length() -> float:
	return _length

func is_loop() -> bool:
	return _loop

func point_at(s_in: float) -> Dictionary:
	# A loop wraps; an open road ENDS. Clamping is what makes "past the finish" a real place rather
	# than a position back at the start line.
	var s := fposmod(s_in, _length) if _loop else clampf(s_in, 0.0, _length)
	var i := _find_segment(s)
	var j := i + 1 if i + 1 < _n else (0 if _loop else i)
	var t := 0.0 if _seglen[i] < 1e-6 else clampf((s - _s[i]) / _seglen[i], 0.0, 1.0)
	var pos: Vector3 = _pts[i].lerp(_pts[j], t)
	var heading: Vector2 = _heading[i].lerp(_heading[j], t)
	if heading.length_squared() > 1e-9:
		heading = heading.normalized()
	else:
		heading = _heading[i]
	var curvature: float = lerpf(_curvature[i], _curvature[j], t)
	var width: float = lerpf(_halfwidth[i], _halfwidth[j], t) * 2.0
	return {"pos": pos, "heading": heading, "curvature": curvature, "width": width}

func _find_segment(s: float) -> int:
	# binary search: largest i such that _s[i] <= s (the samples are built in strictly
	# non-decreasing arc-length order, so this always lands in-bounds)
	var lo := 0
	var hi := _n - 1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if _s[mid] <= s:
			lo = mid
		else:
			hi = mid - 1
	return lo

func _build_grid() -> void:
	_grid.clear()
	var minx := _pts[0].x; var maxx := _pts[0].x
	var minz := _pts[0].z; var maxz := _pts[0].z
	for p in _pts:
		minx = minf(minx, p.x); maxx = maxf(maxx, p.x)
		minz = minf(minz, p.z); maxz = maxf(maxz, p.z)
	var avg_step := _length / maxf(float(_n), 1.0)
	_cell_size = maxf(avg_step * 8.0, 1.0)   # a handful of samples per cell, not thousands
	_min_x = minx; _min_z = minz
	# DERIVED search cap, not a picked one: the largest ring that could still contain a sample.
	# A hard-coded bound is exactly how the _mf_peak_u bisection silently mis-placed a curve peak
	# (see docs/PLAN-drivetrain-suspension.md §9 B4), so this follows the grid's real extent.
	_max_ring = int(ceil(maxf(maxx - minx, maxz - minz) / _cell_size)) + 2
	for i in range(_n):
		var key := _key(_pts[i].x, _pts[i].z)
		if not _grid.has(key):
			_grid[key] = PackedInt32Array()
		_grid[key].append(i)

func _key(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor((x - _min_x) / _cell_size)), int(floor((z - _min_z) / _cell_size)))

func _nearest_sample(x: float, z: float) -> int:
	## The nearest sample INDEX, and it is provably the nearest.
	##
	## This used to scan a fixed 3x3 block of grid cells, which only guarantees a hit within ONE
	## cell (~2.5 m on the rally loop) - while the car drives 4 m off the centreline through
	## corners and the roughness field queries out to the 7 m shoulder. Past that radius it
	## silently returned a farther sample, and WHICH one depended on the cell size, i.e. on the
	## sample count. Measured on C1's rally-loop centreline before the fix: correct on the centre
	## line and at 2 m, but WRONG at 9.85% of road-edge (4 m) positions, worst case 3.72 m of arc
	## length - 6.2 washboard wavelengths. Washboard is masked to corners and braking zones, which
	## is precisely where a car is off-centre, so the ripple train was being scrambled exactly
	## where it lives. See CHANGELOG.md 2026-08-28.
	##
	## Now the ring expands until the answer is PROVABLE: once the best candidate is nearer than
	## R cells, no unscanned cell can hold anything closer, so we can stop. On-road queries still
	## finish on the first ring, so the common path costs what it did before.
	var ck := _key(x, z)
	var best_i := -1
	var best_d2 := INF
	var r := 0
	while r <= _max_ring:
		for dxi in range(-r, r + 1):
			for dzi in range(-r, r + 1):
				if r > 0 and maxi(absi(dxi), absi(dzi)) != r:
					continue                      # interior already scanned by a smaller ring
				var key := Vector2i(ck.x + dxi, ck.y + dzi)
				if not _grid.has(key):
					continue
				for idx in _grid[key]:
					var d2 := Vector2(_pts[idx].x - x, _pts[idx].z - z).length_squared()
					if d2 < best_d2:
						best_d2 = d2; best_i = idx
		# Exact stop bound: everything still unscanned lies OUTSIDE the square of cells already
		# swept, so nothing out there can be nearer than this point's distance to that square's
		# edge. Using the true edge distance rather than a conservative r*cell_size lets an
		# ordinary on-road query finish on the first ring, which is what keeps the cost flat.
		var lo_x := _min_x + float(ck.x - r) * _cell_size
		var hi_x := _min_x + float(ck.x + r + 1) * _cell_size
		var lo_z := _min_z + float(ck.y - r) * _cell_size
		var hi_z := _min_z + float(ck.y + r + 1) * _cell_size
		var safe := minf(minf(x - lo_x, hi_x - x), minf(z - lo_z, hi_z - z))
		if best_i >= 0 and safe > 0.0 and best_d2 <= safe * safe:
			return best_i
		r += 1
	if best_i < 0:                                    # query is off the grid entirely
		for i in range(_n):
			var d2b := Vector2(_pts[i].x - x, _pts[i].z - z).length_squared()
			if d2b < best_d2:
				best_d2 = d2b; best_i = i
	return best_i

func sample_index_at(x: float, z: float) -> int:
	## Which SAMPLE does this world position belong to? Distinct from nearest_point(), which also
	## projects onto the segment and costs far more - this is the cheap query wear.gd needs per
	## grip lookup (D1 measured 52.8 classifier calls/tick; a full nearest_point there would be
	## many times the cost of the whole ground map).
	if _polar:
		# EXACT legacy mapping, preserved deliberately. Changing it would move every wear cell and
		# therefore C1's washboard mask, which is §6.2's "single most likely way Arc D silently
		# breaks Arc C" - and C1's feel was only just accepted.
		var i := int(round(atan2(z - _polar_center.z, x - _polar_center.x) / TAU * float(_n)))
		return ((i % _n) + _n) % _n
	return _nearest_sample(x, z)

func nearest_point(x: float, z: float) -> Dictionary:
	var best_i := _nearest_sample(x, z)
	var best_d2: float = Vector2(_pts[best_i].x - x, _pts[best_i].z - z).length_squared()
	# refine against the two segments touching the nearest sample: project onto each, keep the
	# closer one, and read s/lateral/heading off that projection rather than the raw sample
	var best_s := _s[best_i]
	var best_lat := sqrt(best_d2)
	var best_heading := _heading[best_i]
	var best_width := _halfwidth[best_i] * 2.0
	var bd2 := best_d2
	var cand: Array[int] = []
	if best_i > 0 or _loop:
		cand.append((best_i - 1 + _n) % _n)
	if best_i < _n - 1 or _loop:
		cand.append(best_i)
	for i: int in cand:
		var j := (i + 1) % _n
		var a := _pts[i]; var b := _pts[j]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ap := Vector2(x - a.x, z - a.z)
		var len2 := ab.length_squared()
		var t := 0.0 if len2 < 1e-9 else clampf(ap.dot(ab) / len2, 0.0, 1.0)
		var proj := Vector2(a.x, a.z) + ab * t
		var d2 := Vector2(x, z).distance_squared_to(proj)
		if d2 < bd2:
			bd2 = d2
			best_s = _s[i] + _seglen[i] * t
			if _loop:
				best_s = fposmod(best_s, _length)
			best_heading = ab.normalized() if len2 > 1e-9 else _heading[i]
			best_width = lerpf(_halfwidth[i], _halfwidth[j], t) * 2.0
			var side := ab.x * ap.y - ab.y * ap.x
			best_lat = sqrt(d2) * (1.0 if side < 0.0 else -1.0)
	return {"s": best_s, "lateral": best_lat, "heading": best_heading,
		"curvature": _curvature[best_i], "width": best_width}
