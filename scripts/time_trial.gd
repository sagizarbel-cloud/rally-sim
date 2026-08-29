extends Node3D
## Time-trial ghost for THREE concentric circuits. They all share the finish ray at theta=0 (x>0);
## the RADIUS band selects which one you're timing:
##   0 = DIRT CIRCLE (skid-pad in the deformable patch), 1 = RALLY LOOP, 2 = ASPHALT RING.
## Toggle the active circuit with [B]; that also respawns you at its start. Each circuit keeps its own
## best lap + ghost. The ghost is time-synced to your current lap: if it's ahead, you're down on your best.
## Your best survives a respawn (R) so a crash doesn't cost you the ghost.

var car     # RigidBody3D
var stage   # RallyStage (for get_spawn_for on toggle)

@export var sample_hz := 30.0                          # transform samples/sec recorded along a lap
@export var ghost_color := Color(0.35, 0.8, 1.0, 0.34) # translucent cyan

# D3: SHAKEDOWN is the generated point-to-point stage - the first ROUTE in a project that until now
# had only closed circuits, and the first thing to actually exercise D2's open-road timing path
# (start once, splits in order, finish TERMINATES the run). The three circuits keep their canon.
const NAMES := ["DIRT CIRCLE", "RALLY LOOP", "ASPHALT RING", "SHAKEDOWN"]
const SECTORS := 3                                     # M10: split each run into 3 sectors

# D2: how far off a circuit's centreline you can be and still be considered ON it. This replaces
# the retired RMIN/RMAX finish-ray radius bands, which existed only because all three circuits
# crossed the SAME theta=0 ray and radius was the only thing telling them apart. Each circuit now
# has its own centreline and its own triggers, so there is no ambiguity left to resolve and this is
# just a sanity bound. The values are the legacy bands restated as a corridor half-width
# ((RMAX-RMIN)/2 per circuit), so a lap that timed before still times now.
# D3 replaces this with the stage's own corridor width.
const LAT_MAX := [42.0, 75.0, 55.0, 30.0]

var centrelines: Array = []                            # one Centreline per entry, set by world.gd
var area                                               # D3: StageArea for the generated stage

var _active := 1                                       # matches the startup spawn (the RALLY LOOP)

# per-circuit best + last-lap time
var _best: Array = []                                  # 3x {t:PackedFloat32Array, p:PackedVector3Array, q:Array, time:float}
var _last: Array = []                                  # per-entry last time; sized from NAMES in _ready

# active-lap state (only the active circuit is timed/recorded)
var _lap_t := 0.0
var _prev_s := 0.0
var _have_prev_s := false
var _started := false
var _trig: Array = []                                  # 3x [s_start, s_split1, s_split2] along the centreline
var _accum := 0.0
var _cur_t: PackedFloat32Array = PackedFloat32Array()
var _cur_p: PackedVector3Array = PackedVector3Array()
var _cur_q: Array = []
var _pb := 0

var _ghost: Node3D
var _flash := 0.0
var _flash_text := ""
var _flash_color := Color(1.0, 0.9, 0.4)
var _best_sector: Array = []                           # M10: [circuit][sector] best sector time
var _cur_sector := 0
var _sector_start_t := 0.0
var _delta_label: Label
var _msg_label: Label

func _ready() -> void:
	_last.resize(NAMES.size())
	for i in range(NAMES.size()):
		_last[i] = 0.0
		_best.append({"t": PackedFloat32Array(), "p": PackedVector3Array(), "q": [], "time": 0.0})
		_best_sector.append([0.0, 0.0, 0.0])
	_build_ui()
	await get_tree().physics_frame     # let the wheels pose by suspension before we clone the ghost mesh
	await get_tree().physics_frame
	_build_ghost()

func active_info() -> Dictionary:
	# for the HUD to display the active circuit's timing
	var loop := true
	if _active < centrelines.size() and centrelines[_active] != null:
		loop = bool((centrelines[_active] as Centreline).is_loop())
	return {
		"name": NAMES[_active],
		"lap": _lap_t if _started else 0.0,
		"last": _last[_active],
		"best": _best[_active]["time"],
		"loop": loop,          # D2: a closed circuit runs LAPS, a point-to-point stage is a RUN
	}

# ---------------------------------------------------------------- ghost mesh

func _build_ghost() -> void:
	_ghost = Node3D.new()
	_ghost.name = "Ghost"
	add_child(_ghost)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ghost_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if car != null:
		_clone_meshes(car, mat)
	_ghost.visible = false

func _clone_meshes(node: Node, mat: StandardMaterial3D) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).mesh != null:
			var src := child as MeshInstance3D
			var mi := MeshInstance3D.new()
			mi.mesh = src.mesh
			mi.transform = car.global_transform.affine_inverse() * src.global_transform
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_ghost.add_child(mi)
		_clone_meshes(child, mat)

# ---------------------------------------------------------------- lap timing + recording

func _physics_process(delta: float) -> void:
	if car == null:
		return
	var cp: Vector3 = car.global_position

	if Input.is_action_just_pressed("circuit_toggle"):
		_switch_circuit((_active + 1) % NAMES.size())
		return
	if Input.is_action_just_pressed("reset"):
		_reset_lap(cp)                                  # keep every circuit's best; ghost survives

	# D2: where am I ALONG this circuit? One query replaces the polar pair (rho, theta), and it is
	# the only thing the detector below knows about the road - which is what lets a point-to-point
	# stage use the same code (docs/PLAN-stages-ground-map.md §5 Phase D2).
	var cl: Centreline = centrelines[_active] if _active < centrelines.size() else null
	if cl == null:
		return
	var np := cl.nearest_point(cp.x, cp.z)
	var s: float = np["s"]
	var on_circuit: bool = absf(float(np["lateral"])) <= LAT_MAX[_active]
	_lap_t += delta

	if _started:
		_accum += delta
		if _cur_t.is_empty() or _accum >= 1.0 / sample_hz:
			_accum = 0.0
			_cur_t.append(_lap_t)
			_cur_p.append(cp)
			_cur_q.append(car.global_transform.basis.get_rotation_quaternion())

	# START / FINISH trigger. On a LOOP these are the same s and the run repeats (today's
	# behaviour). On an OPEN road the finish is the far end and the run TERMINATES there - see
	# _finish_trigger(). First crossing after spawn/reset starts timing (no debounce); later
	# crossings need >4 s to complete a lap.
	var loop := cl.is_loop()
	if on_circuit and not _started and _crossed(cl, s, _trig[_active][0]):
		_started = true
		_begin_run()
	if on_circuit and _started and _lap_t > 4.0 and _crossed(cl, s, _finish_trigger(cl)):
		_record_sector(_cur_sector, _lap_t - _sector_start_t)       # final sector of the run
		_finish_lap()
		if loop:
			_begin_run()                                            # a lap rolls straight into the next
		else:
			_started = false                                        # an open road ENDS - no wrap
			_lap_t = 0.0
	# mid-run split triggers (sectors 1 and 2; sector 0's boundary IS the start/finish above).
	# NOTE the ordering: this must run BEFORE _prev_s is advanced, because _crossed() compares this
	# tick's s against the PREVIOUS one. The old detector could sit after the theta update because
	# it read the current angle directly instead of a crossing.
	if _started and on_circuit:
		for k in range(1, SECTORS):
			if _crossed(cl, s, _trig[_active][k]) and _cur_sector == k - 1:
				_record_sector(_cur_sector, _lap_t - _sector_start_t)
				_sector_start_t = _lap_t
				_cur_sector = k

	_prev_s = s
	_have_prev_s = true

	_flash = maxf(0.0, _flash - delta)
	_update_ghost(cp, float(np["lateral"]))

# ---------------------------------------------------------------- arc-length triggers (D2)

func build_triggers() -> void:
	## Split positions are the arc lengths at the OLD theta-thirds, not equal thirds of the total.
	## That distinction is the whole reason sector times survive the rewrite: arc length is not
	## uniform in theta on a winding road, so equal-s thirds would silently move every split.
	## A generated point-to-point stage has no theta and gets equal-s splits instead.
	_trig.clear()
	for i in range(centrelines.size()):
		var cl: Centreline = centrelines[i]
		# A generated stage is TIMED between its gates, not end to end: the run-up before the start
		# line and the runoff past the finish are road you drive but not road you are scored on.
		var s0 := 0.0
		var s1 := cl.length()
		if not cl.is_loop() and area != null and i == 3:
			s0 = float(area.gen.timed_start_s)
			s1 = float(area.gen.timed_end_s)
		var t: Array = [s0]
		var n := cl.sample_count()
		for k in range(1, SECTORS):
			if cl.is_loop() and n % SECTORS == 0:
				t.append(cl.s_index(n * k / SECTORS))      # exact legacy boundary
			else:
				t.append(s0 + (s1 - s0) * float(k) / float(SECTORS))
		t.append(s1)                                       # index SECTORS = the finish trigger
		_trig.append(t)

func _finish_trigger(cl: Centreline) -> float:
	# A loop finishes where it starts; an open stage finishes at its finish GATE, which is before
	# the end of the road - the runoff past it is for slowing down, not for scoring.
	if cl.is_loop():
		return 0.0
	return float(_trig[_active][SECTORS])

func _crossed(cl: Centreline, s: float, trig: float) -> bool:
	## Did we pass this trigger, travelling FORWARD, between the last tick and this one?
	## Topology-agnostic by construction, which is the point - no wrap ray, no radius band.
	if not _have_prev_s:
		return false
	var L := cl.length()
	if not cl.is_loop():
		# An open road's s CLAMPS to [0, L], so nothing is ever at a negative s and a start trigger
		# at s = 0 could never be crossed from below. Entering the road IS the crossing: leaving
		# the clamp is what starts the run.
		if trig <= 0.0:
			return _prev_s <= 0.0 and s > 0.0
		return _prev_s < trig and s >= trig      # a real start line is crossed, not entered
	# On a loop, work in forward distance travelled since the last tick. The half-length guard
	# rejects a respawn/teleport (and any backwards motion) the way the old detector's
	# `theta < 0.6` window did.
	var d := fposmod(s - _prev_s, L)
	if d <= 0.0 or d > L * 0.5:
		return false
	var to_trig := fposmod(trig - _prev_s, L)
	return to_trig > 0.0 and to_trig <= d

func _begin_run() -> void:
	_lap_t = 0.0
	_accum = 0.0
	_pb = 0
	_cur_sector = 0
	_sector_start_t = 0.0
	_clear_cur()

func _switch_circuit(which: int) -> void:
	_active = which
	if car != null:
		if which == 3 and area != null:
			car.spawn_transform = area.spawn_transform()   # generated stage: on its start line
		elif stage != null:
			car.spawn_transform = stage.get_spawn_for(which)   # so [R] also respawns on this circuit
		if car.has_method("respawn"):
			car.respawn()
	_reset_lap(car.global_position)
	_flash = 2.5
	_flash_text = "▶ " + NAMES[which]
	_flash_color = Color(1.0, 0.9, 0.4)

func _reset_lap(cp: Vector3) -> void:
	_lap_t = 0.0
	_started = false
	_accum = 0.0
	_pb = 0
	_cur_sector = 0
	_sector_start_t = 0.0
	_clear_cur()
	# Seed the arc-length cursor from where we actually are, so the teleport itself is not read
	# as a forward crossing on the next tick.
	_have_prev_s = false
	if _active < centrelines.size() and centrelines[_active] != null:
		var cl: Centreline = centrelines[_active]
		_prev_s = float(cl.nearest_point(cp.x, cp.z)["s"])
		_have_prev_s = true

func _record_sector(s: int, t: float) -> void:
	if t < 1.0:
		return                                          # ignore spurious tiny sector times
	var best: float = _best_sector[_active][s]
	var improved := best <= 0.0 or t < best
	if improved:
		_best_sector[_active][s] = t
	_flash = 2.4
	if best <= 0.0:
		_flash_text = "S%d  %s" % [s + 1, _fmt(t)]
		_flash_color = Color(0.85, 0.85, 0.9)
	else:
		_flash_text = "S%d  %s  %+.2f" % [s + 1, _fmt(t), t - best]
		_flash_color = Color(0.6, 0.4, 1.0) if improved else Color(1.0, 0.55, 0.5)

func _finish_lap() -> void:
	var last := _lap_t
	_last[_active] = last
	var b: Dictionary = _best[_active]
	if b["time"] <= 0.0 or last < b["time"]:
		b["t"] = _cur_t.duplicate()
		b["p"] = _cur_p.duplicate()
		b["q"] = _cur_q.duplicate()
		b["time"] = last
		_flash = 3.5
		_flash_text = "NEW BEST  " + _fmt(last)
		_flash_color = Color(0.5, 1.0, 0.5)

func _clear_cur() -> void:
	_cur_t = PackedFloat32Array()
	_cur_p = PackedVector3Array()
	_cur_q = []

# ---------------------------------------------------------------- ghost playback + delta

func _update_ghost(cp: Vector3, lateral: float) -> void:
	if _ghost == null:
		return
	var b: Dictionary = _best[_active]
	var bt: PackedFloat32Array = b["t"]
	if bt.is_empty() or not _started:
		_ghost.visible = false
		_delta_label.text = ""
		_show_msg()
		return
	_ghost.visible = true

	var bp: PackedVector3Array = b["p"]
	var bq: Array = b["q"]
	var n := bt.size()
	var tt := _lap_t
	while _pb < n - 1 and bt[_pb + 1] < tt:
		_pb += 1
	_ghost.global_transform = _pose_at(tt, bt, bp, bq, n)

	# time delta vs the ghost at our current position (only meaningful while on the active circuit's band)
	if absf(lateral) <= LAT_MAX[_active] + 6.0:
		var ni := 0
		var bd := 1e18
		for i in range(n):
			var d: float = bp[i].distance_squared_to(cp)
			if d < bd:
				bd = d
				ni = i
		var d_here: float = _lap_t - bt[ni]
		_delta_label.text = "%+.2f" % d_here
		_delta_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5) if d_here <= 0.0 else Color(1.0, 0.55, 0.5))
	else:
		_delta_label.text = ""
	_show_msg()

func _pose_at(tt: float, bt: PackedFloat32Array, bp: PackedVector3Array, bq: Array, n: int) -> Transform3D:
	if tt <= bt[0]:
		return Transform3D(Basis(bq[0]), bp[0])
	if tt >= bt[n - 1]:
		return Transform3D(Basis(bq[n - 1]), bp[n - 1])
	var i := _pb
	var t0 := bt[i]
	var t1 := bt[i + 1]
	var f := clampf((tt - t0) / maxf(t1 - t0, 1e-4), 0.0, 1.0)
	var p := bp[i].lerp(bp[i + 1], f)
	var qa: Quaternion = bq[i]
	var qb: Quaternion = bq[i + 1]
	return Transform3D(Basis(qa.slerp(qb, f)), p)

# ---------------------------------------------------------------- UI (delta + transient message)

func _build_ui() -> void:
	var ui := CanvasLayer.new()
	ui.layer = 5
	add_child(ui)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(root)
	_delta_label = _mk_label(root, 34, 70)
	_msg_label = _mk_label(root, 22, 112)
	_msg_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))

func _mk_label(root: Control, font_size: int, top: int) -> Label:
	var l := Label.new()
	l.anchor_left = 0.5
	l.anchor_right = 0.5
	l.offset_left = -180
	l.offset_right = 180
	l.offset_top = top
	l.offset_bottom = top + font_size + 8
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	root.add_child(l)
	return l

func _show_msg() -> void:
	if _flash > 0.0:
		_msg_label.add_theme_color_override("font_color", _flash_color)
		_msg_label.text = _flash_text
	else:
		_msg_label.text = ""

func _fmt(t: float) -> String:
	var m := int(t) / 60
	var s := t - float(m * 60)
	return "%d:%06.3f" % [m, s]
