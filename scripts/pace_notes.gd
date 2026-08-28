extends CanvasLayer
## Co-driver pace notes for the dirt rally LOOP *and* the asphalt RING.
##
## Corners are detected per circuit from the road geometry (signed curvature + crests) and turned into
## rally notes (direction, severity 1=hairpin..6=flat, modifiers long/tightens/opens/crest/into). Each
## frame we pick whichever circuit you're actually driving (nearest centreline) and call ITS corners
## ahead of time -- spoken via OS text-to-speech + shown on-screen. Quiet when off both circuits.

var car          # RigidBody3D
var stage        # RallyStage (uses _road / _asphalt_r / _height / road_center)

@export var samples := 1440           # samples per circuit centreline
var centrelines: Array = []           # D2: 3x Centreline, set by world.gd (stage index order)
@export var curv_min_dirt := 0.011    # rally loop corner threshold (1/m ~ 90 m radius)
@export var curv_min_asph := 0.003    # asphalt ring threshold (big-radius street circuit -> gentler)
@export var asph_sev_scale := 0.30    # asphalt corners are big-radius but FAST -> scale radius down for severity
@export var merge_gap := 14.0         # merge same-direction corner fragments closer than this (m)
@export var link_gap := 26.0          # straight shorter than this -> corners are "into" each other
@export var lead_base := 30.0         # call a corner this many metres before it...
@export var lead_time := 1.7          # ...plus this many seconds of travel (faster = earlier call)
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

func _ready() -> void:
	layer = 6
	_build_ui()
	_init_tts()
	# D2: routes come from the shared Centreline per circuit, not from sampling theta here.
	# NOTE the index convention differs from stage/time_trial on purpose-was-not: this file used
	# 0=RALLY LOOP / 1=ASPHALT RING while stage._circuit_r uses 0=DIRT CIRCLE / 1=RALLY LOOP /
	# 2=ASPHALT RING. Taking centrelines by stage index removes that second convention.
	if centrelines.size() >= 3:
		_routes.append(_build_route(centrelines[1], "RALLY LOOP", curv_min_dirt, 1.0))
		_routes.append(_build_route(centrelines[2], "ASPHALT RING", curv_min_asph, asph_sev_scale))
	if debug_print:
		_dump()

# ---------------------------------------------------------------- build a circuit's route + notes

func _build_route(cl: Centreline, rname: String, cmin: float, sev_scale: float) -> Dictionary:
	# Take every stride-th centreline sample, which lands on exactly the positions this file used
	# to compute itself - so the corner list is unchanged - while the road's SHAPE is now somebody
	# else's problem. That is the whole re-parameterisation: _detect/_severity/_crest below are
	# untouched, and a point-to-point stage reaches them through the same door.
	var stride: int = maxi(1, cl.sample_count() / samples)
	var pts := PackedVector3Array(); pts.resize(samples)
	var elev := PackedFloat32Array(); elev.resize(samples)
	for i in range(samples):
		var p: Vector3 = cl.point_index(i * stride)
		pts[i] = p
		elev[i] = p.y
	var arc := PackedFloat32Array(); arc.resize(samples)
	var s := 0.0
	for i in range(samples):
		arc[i] = s
		var a := pts[i]
		var b := pts[(i + 1) % samples]
		s += Vector2(b.x - a.x, b.z - a.z).length()
	var corners := _detect(pts, arc, elev, s, cmin, sev_scale)
	return {"name": rname, "pts": pts, "arc": arc, "elev": elev, "total": s, "corners": corners}

func _heading_at(pts: PackedVector3Array, i: int) -> Vector2:
	var a := pts[i]
	var b := pts[(i + 1) % samples]
	return Vector2(b.x - a.x, b.z - a.z).normalized()

func _seg_len_at(pts: PackedVector3Array, i: int) -> float:
	var a := pts[i]
	var b := pts[(i + 1) % samples]
	return Vector2(b.x - a.x, b.z - a.z).length()

func _detect(pts: PackedVector3Array, arc: PackedFloat32Array, elev: PackedFloat32Array, total: float, cmin: float, sev_scale: float) -> Array:
	var kappa := PackedFloat32Array(); kappa.resize(samples)   # signed curvature rad/m
	var turn := PackedFloat32Array(); turn.resize(samples)     # signed heading change rad (+ = left)
	for i in range(samples):
		var h0 := _heading_at(pts, i)
		var h1 := _heading_at(pts, (i + 1) % samples)
		var cross := h0.y * h1.x - h0.x * h1.y
		var dot := clampf(h0.dot(h1), -1.0, 1.0)
		var dphi := atan2(cross, dot)
		turn[i] = dphi
		kappa[i] = dphi / maxf(_seg_len_at(pts, i), 0.01)

	var raw: Array = []
	var i := 0
	while i < samples:
		if absf(kappa[i]) >= cmin:
			var j := i
			var sign_i := signf(kappa[i])
			while j + 1 < samples and absf(kappa[j + 1]) >= cmin and signf(kappa[j + 1]) == sign_i:
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
	var lo := (a - 6 + samples) % samples
	var n := (b - a) + 12
	var maxh := -1e9
	var maxpos := -1
	var k := lo
	for s in range(n):
		if elev[k] > maxh:
			maxh = elev[k]
			maxpos = s
		k = (k + 1) % samples
	var h_start: float = elev[lo]
	var h_end: float = elev[(lo + n - 1) % samples]
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
	var best_d := 1e18
	var best_r := -1
	var best_j := 0
	for ri in range(_routes.size()):
		var rpts: PackedVector3Array = _routes[ri]["pts"]
		for i in range(samples):
			var d := Vector2(cp.x - rpts[i].x, cp.z - rpts[i].z).length_squared()
			if d < best_d:
				best_d = d
				best_r = ri
				best_j = i
	if best_r < 0:
		return
	if best_r != _active:                 # switched circuits -> re-arm its notes
		_active = best_r
		for c in _routes[best_r]["corners"]:
			c["spoken"] = false

	var on_route := sqrt(best_d) < on_route_dist
	var route: Dictionary = _routes[best_r]
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

	for c in corners:                     # re-arm corners we've clearly passed
		var rem: float = fposmod(c["s0"] - s_car, total)
		if rem > total * 0.6:
			c["spoken"] = false

	var nxt: Dictionary = {}
	var nxt_rem := 1e18
	for c in corners:
		var rem: float = fposmod(c["s0"] - s_car, total)
		if rem < nxt_rem:
			nxt_rem = rem
			nxt = c

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

func _build_ui() -> void:
	var box := VBoxContainer.new()
	box.anchor_left = 0.5; box.anchor_right = 0.5
	box.anchor_top = 1.0; box.anchor_bottom = 1.0
	box.offset_left = -260; box.offset_right = 260
	box.offset_top = -150; box.offset_bottom = -70
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(box)

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
	var col := Color(0.55, 0.8, 1.0) if nxt["dir"] > 0 else Color(1.0, 0.7, 0.45)   # blue=left, orange=right
	var arrow := "◄  " if nxt["dir"] > 0 else "  ►"
	_cur_label.add_theme_color_override("font_color", col if _hold > 0.0 else col.darkened(0.15))
	_cur_label.text = (arrow if nxt["dir"] > 0 else "") + nxt["display"] + ("" if nxt["dir"] > 0 else arrow)
	_next_label.text = "%d m" % int(round(rem))
