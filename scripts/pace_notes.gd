extends CanvasLayer
## Co-driver pace notes for the dirt rally LOOP *and* the asphalt RING.
##
## Corners are detected per circuit from the road geometry (signed curvature + crests) and turned into
## rally notes (direction, severity 1=hairpin..6=flat, modifiers long/tightens/opens/crest/into). Each
## frame we pick whichever circuit you're actually driving (nearest centreline) and call ITS corners
## ahead of time -- spoken via OS text-to-speech + shown on-screen. Quiet when off both circuits.

var car          # RigidBody3D
var stage        # RallyStage (uses _road / _asphalt_r / _height / road_center)
var stage_area   # D3: StageArea for the generated stage - read for its timed FINISH gate

@export var samples := 1440           # samples per circuit centreline
var centrelines: Array = []           # D2: one Centreline per circuit, set by world.gd (stage order)
# D3: a route no longer has to be `samples` points long, nor closed. The generated stage is an OPEN
# road with its own sample count, so detection reads these instead of the export and never wraps
# past an end that does not exist.
var _rn := 0
var _rloop := true
@export var curv_min_dirt := 0.011    # rally loop corner threshold (1/m ~ 90 m radius)
@export var curv_min_asph := 0.003    # asphalt ring threshold (big-radius street circuit -> gentler)
@export var asph_sev_scale := 0.30    # asphalt corners are big-radius but FAST -> scale radius down for severity
@export var merge_gap := 14.0         # merge same-direction corner fragments closer than this (m)
@export var link_gap := 26.0          # straight shorter than this -> corners are "into" each other
@export var lead_base := 24.0         # call a corner this many metres before it...
@export var lead_time := 1.35         # ...plus this many seconds of travel (faster = earlier call).
                                      # 30 m + 1.7 s called ~67 m ahead at 80 km/h, which drove as
                                      # too early; 24 + 1.35 is ~2.3 s of warning at that speed.
@export var on_route_dist := 45.0     # only call notes within this distance of a circuit centreline
@export var crest_prom := 0.7         # elevation bump (m) that counts as a crest
@export var speech_rate := 1.18       # co-drivers talk briskly
@export var debug_print := false      # print detected notes per circuit on startup (headless validation)

const _NUMW := ["", "one", "two", "three", "four", "five", "six"]

var _routes: Array = []                # each: {name, pts, arc, elev, total, corners}
var _active := -1

var _voice := ""
var _tts := false
var _cur_label: Label
var _next_label: Label
var _hold := 0.0
var _cur_col := Color(-1, -1, -1)       # the note colour currently applied; see _update_ui

func _ready() -> void:
	layer = 6
	_build_ui()
	_init_tts()
	rebuild_routes()

func rebuild_routes() -> void:
	## D3: also called when the SHAKEDOWN stage is regenerated from the Tab panel, so the co-driver
	## is never reading notes for a road that no longer exists.
	# D2: routes come from the shared Centreline per circuit, not from sampling theta here.
	# NOTE the index convention differs from stage/time_trial: this file used 0=RALLY LOOP /
	# 1=ASPHALT RING while stage._circuit_r uses 0=DIRT CIRCLE / 1=RALLY LOOP / 2=ASPHALT RING.
	# Taking centrelines by stage index removes that second convention.
	_routes.clear()
	if centrelines.size() >= 3:
		_routes.append(_build_route(centrelines[1], "RALLY LOOP", curv_min_dirt, 1.0))
		_routes.append(_build_route(centrelines[2], "ASPHALT RING", curv_min_asph, asph_sev_scale))
	# D3: the generated stage. It reaches corner detection through exactly the same door as the two
	# polar circuits, because D2 made _build_route take a Centreline - which is the whole reason
	# that phase existed. Its note list is the generator's real acceptance test (§3.6).
	if centrelines.size() >= 4 and centrelines[3] != null:
		# The stage is TIMED between its gates; the run-up and runoff are road you drive but are not
		# scored on. Pass the finish GATE so the co-driver calls the finish where the clock stops.
		var s_fin := -1.0
		if stage_area != null and stage_area.gen != null:
			s_fin = float(stage_area.gen.timed_end_s)
		_routes.append(_build_route(centrelines[3], "SHAKEDOWN", curv_min_dirt, 1.0, s_fin))
	_active = -1
	_build_nearest_grid()
	if debug_print:
		_dump()

# ---------------------------------------------------------------- nearest route point, exactly

# _process() needs the nearest point across EVERY route, every frame, and it used to get it by
# testing all of them - 4,494 points with the generated stage loaded, measured at 0.35-0.41 ms a
# frame, two thirds of all idle script time in the game. The points never move, so they are binned
# once into a uniform grid and the search walks outward ring by ring, exactly as
# Centreline._nearest_sample does, stopping only when the answer is PROVABLE.
#
# THE ANSWER IS THE SAME ONE, not a nearby one: same distance expression, same winner on an exact
# tie (the lowest route, then the lowest index - which is what a first-wins scan in route order
# gives), and the stop test carries a 1% margin so that 32-bit rounding in the distance can never
# let an unscanned point beat the winner. Far from every route the walk would cost more than the
# scan it replaces, so past a derived distance it IS that scan.
var _ng: Dictionary = {}              # cell -> PackedInt32Array of (route << 20 | index)
var _ng_cell := 16.0
var _ng_min_x := 0.0
var _ng_min_z := 0.0
var _ng_max_x := 0.0
var _ng_max_z := 0.0
var _ng_max_ring := 0
var _ng_brute := 0.0                  # beyond this distance from the routes the full scan is cheaper
var _ng_ring_limit := 0               # ...which is this many rings of cells
var _ng_last_d := 0.0                 # the last answer's distance, and where it was asked from:
var _ng_last_p := Vector3.ZERO        # the nearest point cannot come closer faster than the car moves
const NG_PROBE_COST := 5.6            # one cell probe costs this many point tests (measured, see below)
var _nb_d := 1e18                     # the three results of _nearest_route_point()
var _nb_r := -1
var _nb_j := 0

func _build_nearest_grid() -> void:
	_ng.clear()
	var n := 0
	var total_len := 0.0
	var first := true
	for route in _routes:
		var rpts: PackedVector3Array = route["pts"]
		n += rpts.size()
		total_len += float(route["total"])
		for p in rpts:
			if first:
				_ng_min_x = p.x; _ng_max_x = p.x; _ng_min_z = p.z; _ng_max_z = p.z
				first = false
			_ng_min_x = minf(_ng_min_x, p.x); _ng_max_x = maxf(_ng_max_x, p.x)
			_ng_min_z = minf(_ng_min_z, p.z); _ng_max_z = maxf(_ng_max_z, p.z)
	if n == 0:
		return
	# a handful of points per cell: eight times the mean spacing, the rule Centreline uses
	_ng_cell = maxf(total_len / float(n) * 8.0, 1.0)
	_ng_max_ring = int(ceil(maxf(_ng_max_x - _ng_min_x, _ng_max_z - _ng_min_z) / _ng_cell)) + 2
	# Reaching a distance d costs about 4*(d/cell)^2 cell probes and the full scan costs n point
	# tests, so the scan wins beyond the d where those meet. A probe is not a point test, though:
	# measured here, walking to 130 m took 143 us (about 320 probes) while the scan's ~4,500 point
	# tests took 354 us - one probe costs what NG_PROBE_COST point tests do. So
	# d = cell * sqrt(n / (4 * NG_PROBE_COST)), about 200 m on this map.
	_ng_brute = _ng_cell * sqrt(float(n) / (4.0 * NG_PROBE_COST))
	_ng_ring_limit = int(ceil(_ng_brute / _ng_cell))
	_ng_last_d = 0.0
	for ri in range(_routes.size()):
		var rpts2: PackedVector3Array = _routes[ri]["pts"]
		for i in range(rpts2.size()):
			var key := _ng_key(rpts2[i].x, rpts2[i].z)
			if not _ng.has(key):
				_ng[key] = PackedInt32Array()
			_ng[key].append((ri << 20) | i)

func _ng_key(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor((x - _ng_min_x) / _ng_cell)), int(floor((z - _ng_min_z) / _ng_cell)))

func _nearest_scan(cp: Vector3) -> void:
	# the original search: every point of every route, first winner kept
	for ri in range(_routes.size()):
		var rpts: PackedVector3Array = _routes[ri]["pts"]
		for i in range(rpts.size()):
			var d := Vector2(cp.x - rpts[i].x, cp.z - rpts[i].z).length_squared()
			if d < _nb_d:
				_nb_d = d
				_nb_r = ri
				_nb_j = i

func _nearest_route_point(cp: Vector3) -> void:
	## Sets _nb_d (squared distance), _nb_r (route) and _nb_j (point index) to the nearest route
	## point to `cp` - the same three values the full scan produces.
	_nb_d = 1e18
	_nb_r = -1
	_nb_j = 0
	if _ng.is_empty():
		_nearest_scan(cp)
		return
	# FAR FROM EVERY ROUTE THE SCAN IS THE CHEAPER WAY, and two things say "far" without searching:
	# the box round all the routes, and the last answer - the nearest point was _ng_last_d away when
	# asked from _ng_last_p, and it cannot be nearer now than that minus how far the car has moved.
	# Either way the answer is the scan's own, so which path runs changes the cost and nothing else.
	var dx_out: float = maxf(maxf(_ng_min_x - cp.x, cp.x - _ng_max_x), 0.0)
	var dz_out: float = maxf(maxf(_ng_min_z - cp.z, cp.z - _ng_max_z), 0.0)
	var moved: float = Vector2(cp.x - _ng_last_p.x, cp.z - _ng_last_p.z).length()
	if dx_out * dx_out + dz_out * dz_out > _ng_brute * _ng_brute or _ng_last_d - moved > _ng_brute:
		_nearest_scan(cp)
		_ng_last_d = sqrt(_nb_d)
		_ng_last_p = cp
		return
	var ck := _ng_key(cp.x, cp.z)
	var best_key := -1
	var proven := false
	var r := 0
	while r <= mini(_ng_max_ring, _ng_ring_limit):
		for dxi in range(-r, r + 1):
			var stride: int = 1 if (absi(dxi) == r or r == 0) else 2 * r
			var dzi := -r
			while dzi <= r:
				var key := Vector2i(ck.x + dxi, ck.y + dzi)
				dzi += stride
				if not _ng.has(key):
					continue
				for pk: int in _ng[key]:
					var rpts: PackedVector3Array = _routes[pk >> 20]["pts"]
					var q: Vector3 = rpts[pk & 0xFFFFF]
					var d := Vector2(cp.x - q.x, cp.z - q.z).length_squared()
					if d < _nb_d or (d == _nb_d and pk < best_key):
						_nb_d = d
						best_key = pk
		# everything unscanned lies outside the square of cells swept so far
		var lo_x := _ng_min_x + float(ck.x - r) * _ng_cell
		var hi_x := _ng_min_x + float(ck.x + r + 1) * _ng_cell
		var lo_z := _ng_min_z + float(ck.y - r) * _ng_cell
		var hi_z := _ng_min_z + float(ck.y + r + 1) * _ng_cell
		var safe := minf(minf(cp.x - lo_x, hi_x - cp.x), minf(cp.z - lo_z, hi_z - cp.z)) * 0.99
		if best_key >= 0 and safe > 0.0 and _nb_d <= safe * safe:
			proven = true
			break
		r += 1
	if not proven:
		# nothing within the walk's reach was provably the nearest: let the scan answer from scratch
		_nb_d = 1e18
		_nb_r = -1
		_nb_j = 0
		_nearest_scan(cp)
	else:
		_nb_r = best_key >> 20
		_nb_j = best_key & 0xFFFFF
	_ng_last_d = sqrt(_nb_d)
	_ng_last_p = cp

# ---------------------------------------------------------------- build a circuit's route + notes

func _build_route(cl: Centreline, rname: String, cmin: float, sev_scale: float, finish_s := -1.0) -> Dictionary:
	# Take every stride-th centreline sample, which lands on exactly the positions this file used
	# to compute itself - so the corner list is unchanged - while the road's SHAPE is now somebody
	# else's problem. That is the whole re-parameterisation: _detect/_severity/_crest below are
	# untouched, and a point-to-point stage reaches them through the same door.
	var stride: int = maxi(1, cl.sample_count() / samples)
	var count: int = cl.sample_count() / stride
	_rn = count
	_rloop = cl.is_loop()
	var pts := PackedVector3Array(); pts.resize(count)
	var elev := PackedFloat32Array(); elev.resize(count)
	for i in range(count):
		var p: Vector3 = cl.point_index(mini(i * stride, cl.sample_count() - 1))
		pts[i] = p
		elev[i] = p.y
	var arc := PackedFloat32Array(); arc.resize(count)
	var s := 0.0
	for i in range(count):
		arc[i] = s
		if i == count - 1 and not _rloop:
			break                          # an open road ends here; there is no closing segment
		var a := pts[i]
		var b := pts[_idx(i + 1)]
		s += Vector2(b.x - a.x, b.z - a.z).length()
	var corners := _detect(pts, arc, elev, s, cmin, sev_scale)
	if not _rloop:
		# A road book ends by calling the FINISH. On a closed circuit there is nothing to call - you
		# just come round again - but on a point-to-point stage the co-driver telling you the finish
		# is coming is the difference between committing and lifting. It is a call, not a corner:
		# no direction, no severity, so `dir` is 0 and the UI renders it without an arrow.
		#
		# DRIVE VERDICT 2026-08-30: "finish pace notes referring to the end of the road instead of
		# the finish line". This used to sit at arc[count - 1] - the far end of the RUNOFF, which is
		# `finish_runoff_m` (80 m) PAST the finish gate - so the co-driver called the finish long
		# after you had crossed it, and at a lead distance that put the call somewhere in the
		# slowing-down area. The gate is `StageGen.timed_end_s`: the same arc length `time_trial.gd`
		# stops the clock on and `stage_area.gd` builds the FINISH banner at. Caller passes it, so
		# the call, the clock and the banner now all refer to one place on the road.
		var s_end: float = arc[count - 1]
		var s_fin: float = s_end if finish_s < 0.0 else clampf(finish_s, 0.0, s_end)
		corners.append({"a": _index_at_s(arc, s_fin), "b": _index_at_s(arc, s_fin),
			"s0": s_fin, "s1": s_fin,
			"dir": 0, "sev": 0, "mods": [], "link": false, "spoken": false,
			"display": "FINISH", "speech_base": "finish"})
	# `loop` and `n` travel WITH the route. They used to live only in the members _rloop/_rn, which
	# are per-build scratch: the last route built wins, and _process then read another road's
	# topology through _idx. See _process for the measured damage that did.
	# `s0s`: every corner's start arc length again, as a packed array in the same order. _process
	# asks "how far ahead is each corner" every frame; reading a packed double is several times
	# cheaper than a Dictionary lookup, and a double holds the Dictionary's value exactly.
	var s0s := PackedFloat64Array(); s0s.resize(corners.size())
	for k in range(corners.size()):
		s0s[k] = float(corners[k]["s0"])
	return {"name": rname, "pts": pts, "arc": arc, "elev": elev, "total": s, "corners": corners,
		"s0s": s0s, "loop": _rloop, "n": count}

func _index_at_s(arc: PackedFloat32Array, s_target: float) -> int:
	## Nearest sample to an arc length. The gate is a distance along the road, not a sample index,
	## and the two only coincide by luck.
	var best := 0
	var bd := 1e18
	for i in range(arc.size()):
		var d: float = absf(arc[i] - s_target)
		if d < bd:
			bd = d
			best = i
	return best

func _idx(i: int) -> int:
	## Wrap on a closed circuit, CLAMP on an open stage. A point-to-point road has no sample after
	## its last one, and pretending otherwise invents a corner joining the finish to the start.
	if _rloop:
		return ((i % _rn) + _rn) % _rn
	return clampi(i, 0, _rn - 1)

func _heading_at(pts: PackedVector3Array, i: int) -> Vector2:
	var a := pts[i]
	var b := pts[_idx(i + 1)]
	return Vector2(b.x - a.x, b.z - a.z).normalized()

func _seg_len_at(pts: PackedVector3Array, i: int) -> float:
	var a := pts[i]
	var b := pts[_idx(i + 1)]
	return Vector2(b.x - a.x, b.z - a.z).length()

func _detect(pts: PackedVector3Array, arc: PackedFloat32Array, elev: PackedFloat32Array, total: float, cmin: float, sev_scale: float) -> Array:
	var kappa := PackedFloat32Array(); kappa.resize(_rn)   # signed curvature rad/m
	var turn := PackedFloat32Array(); turn.resize(_rn)     # signed heading change rad (+ = left)
	for i in range(_rn):
		var h0 := _heading_at(pts, i)
		var h1 := _heading_at(pts, _idx(i + 1))
		var cross := h0.y * h1.x - h0.x * h1.y
		var dot := clampf(h0.dot(h1), -1.0, 1.0)
		var dphi := atan2(cross, dot)
		turn[i] = dphi
		kappa[i] = dphi / maxf(_seg_len_at(pts, i), 0.01)

	var raw: Array = []
	var i := 0
	while i < _rn:
		if absf(kappa[i]) >= cmin:
			var j := i
			var sign_i := signf(kappa[i])
			while j + 1 < _rn and absf(kappa[j + 1]) >= cmin and signf(kappa[j + 1]) == sign_i:
				j += 1
			raw.append({"a": i, "b": j})
			i = j + 1
		else:
			i += 1

	var merged: Array = []
	for seg in raw:
		if merged.size() > 0:
			var prev: Dictionary = merged[-1]
			var gap: float = arc[seg["a"]] - arc[prev["b"]]
			var same_dir: bool = signf(turn[seg["a"]]) == signf(turn[prev["b"]])
			if gap < merge_gap and same_dir:
				prev["b"] = seg["b"]
				continue
		merged.append(seg.duplicate())

	var corners: Array = []
	for seg in merged:
		var a: int = seg["a"]
		var b: int = seg["b"]
		var total_turn := 0.0
		var peak := 0.0
		for k in range(a, b + 1):
			total_turn += turn[k]
			peak = maxf(peak, absf(kappa[k]))
		if absf(total_turn) < 0.20:
			continue
		var dir := 1 if total_turn > 0.0 else -1
		var rmin := 1.0 / maxf(peak, 1e-4)
		var sev := _severity(rmin * sev_scale)
		var length: float = arc[b] - arc[a]
		var mods: Array = []
		if length > 60.0:
			mods.append("long")
		var third := maxi((b - a) / 3, 1)
		var k_in := 0.0; var k_out := 0.0
		for k in range(a, a + third):
			k_in = maxf(k_in, absf(kappa[k]))
		for k in range(b - third + 1, b + 1):
			k_out = maxf(k_out, absf(kappa[k]))
		if k_out > k_in * 1.35:
			mods.append("tightens")
		elif k_in > k_out * 1.35:
			mods.append("opens")
		if _crest(elev, a, b):
			mods.append("crest")
		corners.append({"a": a, "b": b, "s0": arc[a], "s1": arc[b], "dir": dir, "sev": sev, "mods": mods, "link": false, "spoken": false})

	for ci in range(corners.size()):
		var cur: Dictionary = corners[ci]
		var prev: Dictionary = corners[(ci - 1 + corners.size()) % corners.size()]
		var gap: float = fposmod(cur["s0"] - prev["s1"], total)
		cur["link"] = gap < link_gap
		cur["display"] = _display_text(cur)
		cur["speech_base"] = _speech_base(cur)
	return corners

func _severity(radius: float) -> int:
	if radius < 12.0: return 0          # 0 = hairpin
	if radius < 22.0: return 1
	if radius < 35.0: return 2
	if radius < 55.0: return 3
	if radius < 85.0: return 4
	if radius < 130.0: return 5
	return 6

func _crest(elev: PackedFloat32Array, a: int, b: int) -> bool:
	var lo := _idx(a - 6)
	var n := (b - a) + 12
	var maxh := -1e9
	var maxpos := -1
	var k := lo
	for s in range(n):
		if elev[k] > maxh:
			maxh = elev[k]
			maxpos = s
		k = _idx(k + 1)
	var h_start: float = elev[lo]
	var h_end: float = elev[_idx(lo + n - 1)]
	var interior := maxpos > 1 and maxpos < n - 2
	return interior and (maxh - h_start) > crest_prom and (maxh - h_end) > crest_prom

# ---------------------------------------------------------------- note text

func _dir_word(d: int, caps: bool) -> String:
	if d > 0:
		return "LEFT" if caps else "left"
	return "RIGHT" if caps else "right"

func _sev_word(sev: int, caps: bool) -> String:
	if sev == 0:
		return "HAIRPIN" if caps else "hairpin"
	return str(sev) if caps else _NUMW[sev]

func _display_text(c: Dictionary) -> String:
	var t := _dir_word(c["dir"], true) + " " + _sev_word(c["sev"], true)
	for m in c["mods"]:
		t += " " + m
	return t

func _speech_base(c: Dictionary) -> String:
	var t := _dir_word(c["dir"], false) + " " + _sev_word(c["sev"], false)
	for m in c["mods"]:
		t += ", " + str(m)
	return t

func _round_dist(m: float) -> String:
	var step := 50.0 if m > 150.0 else (25.0 if m > 60.0 else 10.0)
	return str(int(round(m / step) * step))

func _dump() -> void:
	for route in _routes:
		var corners: Array = route["corners"]
		print("[PACE] %-8s loop=%.0f m  corners=%d  tts=%s" % [route["name"], route["total"], corners.size(), str(_tts)])
		for ci in range(corners.size()):
			var c: Dictionary = corners[ci]
			print("   %-26s (sev %d)" % [c["display"], c["sev"]])

# ---------------------------------------------------------------- runtime playback

func _process(delta: float) -> void:
	_hold = maxf(0.0, _hold - delta)
	if car == null or _routes.is_empty():
		return
	var cp: Vector3 = car.global_position

	# pick the circuit you're actually on: nearest centreline sample across all routes
	_nearest_route_point(cp)
	var best_d := _nb_d
	var best_r := _nb_r
	var best_j := _nb_j
	if best_r < 0:
		return
	if best_r != _active:                 # switched circuits -> re-arm its notes
		_active = best_r
		for c in _routes[best_r]["corners"]:
			c["spoken"] = false

	var on_route := sqrt(best_d) < on_route_dist
	var route: Dictionary = _routes[best_r]
	# Adopt THIS route's topology before anything calls _idx (via _heading_at below). _rn/_rloop are
	# written per route while building, so without this they hold whichever route was built LAST -
	# the open SHAKEDOWN stage, whose sample count is far short of a circuit's 1440. _idx then
	# CLAMPED every index past its end, so _heading_at read a heading between two unrelated points.
	# MEASURED before this line existed: 434/1440 samples of both the RALLY LOOP and the ASPHALT
	# RING (30.1%) got a wrong heading, worst case 180 deg, and all 434 drove `fwd` below the 0.25
	# gate - i.e. the co-driver went SILENT over 30% of both legacy circuits. It appeared the moment
	# D3 added a third route and nothing on the old map had changed.
	_rn = int(route["n"])
	_rloop = bool(route["loop"])
	var pts: PackedVector3Array = route["pts"]
	var arc: PackedFloat32Array = route["arc"]
	var total: float = route["total"]
	var corners: Array = route["corners"]
	if corners.is_empty():
		_update_ui({}, 0.0, false)
		return

	var jn := best_j
	var vel: Vector3 = car.linear_velocity
	var vflat := Vector2(vel.x, vel.z)
	var speed := vflat.length()
	var fwd := 0.0
	if speed > 0.5:
		fwd = vflat.normalized().dot(_heading_at(pts, jn))
	var s_car: float = arc[jn]

	# One pass over the corners does both jobs that used to take two: re-arm the ones clearly
	# passed, and find the nearest one ahead. Same distances, same order, so the same answers.
	var s0s: PackedFloat64Array = route["s0s"]
	var rearm: float = total * 0.6
	var nxt_k := -1
	var nxt_rem := 1e18
	for k in range(s0s.size()):
		var rem: float = fposmod(s0s[k] - s_car, total)
		if rem > rearm:                   # re-arm corners we've clearly passed
			corners[k]["spoken"] = false
		if rem < nxt_rem:
			nxt_rem = rem
			nxt_k = k
	var nxt: Dictionary = {}
	if nxt_k >= 0:
		nxt = corners[nxt_k]

	var driving := on_route and fwd > 0.25 and speed > 2.5
	if not nxt.is_empty() and driving:
		var lead := lead_base + speed * lead_time
		if nxt_rem <= lead and not nxt["spoken"]:
			nxt["spoken"] = true
			_hold = 3.0
			var speech: String = nxt["speech_base"]
			if nxt["link"]:
				speech = "into " + speech
			elif nxt_rem >= 25.0:
				speech = _round_dist(nxt_rem) + ", " + speech
			_say(speech)

	_update_ui(nxt, nxt_rem, driving)

# ---------------------------------------------------------------- TTS + UI

func _init_tts() -> void:
	var voices := DisplayServer.tts_get_voices_for_language("en")
	if voices.size() > 0:
		_voice = voices[0]
		_tts = true

func _say(text: String) -> void:
	if _tts:
		DisplayServer.tts_speak(text, _voice, 60, 1.0, speech_rate, 0, true)   # interrupt any prior call

var _box: VBoxContainer
## Where the notes sit, as a fraction of the screen height from the top (0 = top, 1 = bottom).
## Set from the HUD menu ([H]) and saved there. 0.85 is about where they always were.
var note_height := 0.85

func set_note_height(f: float) -> void:
	note_height = clampf(f, 0.05, 0.95)
	if _box != null:
		_box.anchor_top = note_height
		_box.anchor_bottom = note_height
		_box.offset_top = -40
		_box.offset_bottom = 40

func _build_ui() -> void:
	var box := VBoxContainer.new()
	box.anchor_left = 0.5; box.anchor_right = 0.5
	box.offset_left = -260; box.offset_right = 260
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(box)
	_box = box
	set_note_height(note_height)

	_cur_label = Label.new()
	_cur_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cur_label.add_theme_font_size_override("font_size", 40)
	_cur_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_cur_label.add_theme_constant_override("outline_size", 8)
	box.add_child(_cur_label)

	_next_label = Label.new()
	_next_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_next_label.add_theme_font_size_override("font_size", 20)
	_next_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_next_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_next_label.add_theme_constant_override("outline_size", 6)
	box.add_child(_next_label)

func _update_ui(nxt: Dictionary, rem: float, driving: bool) -> void:
	if nxt.is_empty() or not driving:
		_cur_label.text = ""
		_next_label.text = ""
		return
	var d: int = int(nxt["dir"])
	var col := Color(0.55, 0.8, 1.0) if d > 0 else Color(1.0, 0.7, 0.45)   # blue=left, orange=right
	if d == 0:
		col = Color(0.85, 1.0, 0.6)                                        # a call, not a corner
	var arrow := "◄  " if d > 0 else "  ►"
	# only when it CHANGES: a theme override re-notifies the label and re-shapes its text even when
	# the colour is the one it already has, and this runs every frame
	var shown: Color = col if _hold > 0.0 else col.darkened(0.15)
	if shown != _cur_col:
		_cur_col = shown
		_cur_label.add_theme_color_override("font_color", shown)
	if d == 0:
		_cur_label.text = String(nxt["display"])
	else:
		_cur_label.text = (arrow if d > 0 else "") + String(nxt["display"]) + ("" if d > 0 else arrow)
	_next_label.text = "%d m" % int(round(rem))
