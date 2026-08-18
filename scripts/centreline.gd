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
var _grid: Dictionary = {}
var _cell_size := 20.0
var _min_x := 0.0
var _min_z := 0.0
var _grid_span := 0          # grid extent in cells; bounds the outward ring search in nearest_point

static func from_polar(center: Vector3, radius_fn: Callable, halfwidth_fn: Callable,
		height_fn: Callable, samples: int) -> Centreline:
	var cl := Centreline.new()
	cl._loop = true
	cl._n = samples
	cl._pts = PackedVector3Array(); cl._pts.resize(samples)
	cl._halfwidth = PackedFloat32Array(); cl._halfwidth.resize(samples)
	for i in range(samples):
		var th := TAU * float(i) / float(samples)
		var r: float = radius_fn.call(th)
		var p := center + Vector3(cos(th), 0.0, sin(th)) * r
		if height_fn.is_valid():
			p.y = height_fn.call(p.x, p.z)
		cl._pts[i] = p
		cl._halfwidth[i] = halfwidth_fn.call(th) if halfwidth_fn.is_valid() else 0.0
	cl._finish_build()
	return cl

func _finish_build() -> void:
	_seglen = PackedFloat32Array(); _seglen.resize(_n)
	_s = PackedFloat32Array(); _s.resize(_n)
	_heading = PackedVector2Array(); _heading.resize(_n)
	var s := 0.0
	for i in range(_n):
		_s[i] = s
		var a := _pts[i]
		var b := _pts[(i + 1) % _n]
		var seg := Vector2(b.x - a.x, b.z - a.z)
		_seglen[i] = seg.length()
		_heading[i] = seg.normalized() if _seglen[i] > 1e-6 else Vector2(1, 0)
		s += _seglen[i]
	_length = s
	_curvature = PackedFloat32Array(); _curvature.resize(_n)
	for i in range(_n):
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
	var s := fposmod(s_in, _length)
	var i := _find_segment(s)
	var j := (i + 1) % _n
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
	_grid_span = int(ceil(maxf(maxx - minx, maxz - minz) / _cell_size)) + 1
	for i in range(_n):
		var key := _key(_pts[i].x, _pts[i].z)
		if not _grid.has(key):
			_grid[key] = PackedInt32Array()
		_grid[key].append(i)

func _key(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor((x - _min_x) / _cell_size)), int(floor((z - _min_z) / _cell_size)))

func nearest_point(x: float, z: float) -> Dictionary:
	var ck := _key(x, z)
	var best_i := -1
	var best_d2 := INF
	for dxi in range(-1, 2):
		for dzi in range(-1, 2):
			var key := Vector2i(ck.x + dxi, ck.y + dzi)
			if not _grid.has(key):
				continue
			for idx in _grid[key]:
				var d2 := Vector2(_pts[idx].x - x, _pts[idx].z - z).length_squared()
				if d2 < best_d2:
					best_d2 = d2; best_i = idx
	if best_i < 0:
		# Off-grid: the query sits further from the line than one ring of cells. This used to fall
		# straight through to a scan of every sample - O(n) per call. With the C1 washboard mask
		# broken (fixed in c8d2d18) that path ran 9 patch samples x 4 wheels x 120 Hz on grass and
		# was the frame drop. The mask now gates it, but a bounded search means no future caller
		# can reopen the same hole. Grow outward a ring at a time: the first ring holding any
		# sample also holds the nearest to within a cell, so one more ring after it is exact.
		var r := 2
		var found_at := -1
		while r <= _grid_span and (found_at < 0 or r <= found_at + 1):
			for dxi in range(-r, r + 1):
				var edge_x: bool = (dxi == -r or dxi == r)
				for dzi in range(-r, r + 1):
					if not edge_x and dzi != -r and dzi != r:
						continue        # perimeter only; the interior was searched already
					var key := Vector2i(ck.x + dxi, ck.y + dzi)
					if not _grid.has(key):
						continue
					for idx in _grid[key]:
						var d2 := Vector2(_pts[idx].x - x, _pts[idx].z - z).length_squared()
						if d2 < best_d2:
							best_d2 = d2; best_i = idx
			if best_i >= 0 and found_at < 0:
				found_at = r
			r += 1
	if best_i < 0:
		best_i = 0                              # empty grid; degenerate, but never unindexed
	# refine against the two segments touching the nearest sample: project onto each, keep the
	# closer one, and read s/lateral/heading off that projection rather than the raw sample
	var best_s := _s[best_i]
	var best_lat := sqrt(best_d2)
	var best_heading := _heading[best_i]
	var best_width := _halfwidth[best_i] * 2.0
	var bd2 := best_d2
	for i: int in [((best_i - 1 + _n) % _n), best_i]:
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
			best_s = fposmod(_s[i] + _seglen[i] * t, _length)
			best_heading = ab.normalized() if len2 > 1e-9 else _heading[i]
			best_width = lerpf(_halfwidth[i], _halfwidth[j], t) * 2.0
			var side := ab.x * ap.y - ab.y * ap.x
			best_lat = sqrt(d2) * (1.0 if side < 0.0 else -1.0)
	return {"s": best_s, "lateral": best_lat, "heading": best_heading,
		"curvature": _curvature[best_i], "width": best_width}
