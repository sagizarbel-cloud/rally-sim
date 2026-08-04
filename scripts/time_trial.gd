extends Node3D
## Time-trial ghost for THREE concentric circuits. They all share the finish ray at theta=0 (x>0);
## the RADIUS band selects which one you're timing:
##   0 = centre dirt circle (skid-pad in the deformable patch), 1 = dirt rally loop, 2 = asphalt ring.
## Toggle the active circuit with [B]; that also respawns you at its start. Each circuit keeps its own
## best lap + ghost. The ghost is time-synced to your current lap: if it's ahead, you're down on your best.
## Your best survives a respawn (R) so a crash doesn't cost you the ghost.

var car     # RigidBody3D
var stage   # RallyStage (for get_spawn_for on toggle)

@export var sample_hz := 30.0                          # transform samples/sec recorded along a lap
@export var ghost_color := Color(0.35, 0.8, 1.0, 0.34) # translucent cyan

# circuits: index 0/1/2. RMIN/RMAX are the finish-ray radius bands (disjoint, so a crossing is unambiguous)
const NAMES := ["DIRT CIRCLE", "RALLY LOOP", "ASPHALT RING"]
const RMIN := [8.0, 100.0, 255.0]
const RMAX := [92.0, 250.0, 365.0]
const SECTORS := 3                                     # M10: split each lap into 3 sectors (by angle)

var _active := 1                                       # matches the startup spawn (dirt rally loop)

# per-circuit best + last-lap time
var _best: Array = []                                  # 3x {t:PackedFloat32Array, p:PackedVector3Array, q:Array, time:float}
var _last := [0.0, 0.0, 0.0]

# active-lap state (only the active circuit is timed/recorded)
var _lap_t := 0.0
var _prev_theta := 0.0
var _started := false
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
	for i in range(3):
		_best.append({"t": PackedFloat32Array(), "p": PackedVector3Array(), "q": [], "time": 0.0})
		_best_sector.append([0.0, 0.0, 0.0])
	_build_ui()
	await get_tree().physics_frame     # let the wheels pose by suspension before we clone the ghost mesh
	await get_tree().physics_frame
	_build_ghost()

func active_info() -> Dictionary:
	# for the HUD to display the active circuit's timing
	return {
		"name": NAMES[_active],
		"lap": _lap_t if _started else 0.0,
		"last": _last[_active],
		"best": _best[_active]["time"],
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
		_switch_circuit((_active + 1) % 3)
		return
	if Input.is_action_just_pressed("reset"):
		_reset_lap(cp)                                  # keep every circuit's best; ghost survives

	var rho := sqrt(cp.x * cp.x + cp.z * cp.z)
	var theta := atan2(cp.z, cp.x)
	_lap_t += delta

	if _started:
		_accum += delta
		if _cur_t.is_empty() or _accum >= 1.0 / sample_hz:
			_accum = 0.0
			_cur_t.append(_lap_t)
			_cur_p.append(cp)
			_cur_q.append(car.global_transform.basis.get_rotation_quaternion())

	# finish-line crossing for the ACTIVE circuit's band. First crossing after spawn/reset starts timing
	# (no debounce); later crossings need >4 s to complete a lap.
	if rho > RMIN[_active] and rho < RMAX[_active] and _prev_theta < 0.0 and theta >= 0.0 and theta < 0.6:
		if not _started:
			_started = true
			_lap_t = 0.0
			_accum = 0.0
			_pb = 0
			_cur_sector = 0
			_sector_start_t = 0.0
			_clear_cur()
		elif _lap_t > 4.0:
			_record_sector(_cur_sector, _lap_t - _sector_start_t)   # final sector of the lap
			_finish_lap()
			_lap_t = 0.0
			_accum = 0.0
			_pb = 0
			_cur_sector = 0
			_sector_start_t = 0.0
			_clear_cur()
	_prev_theta = theta

	# mid-lap sector boundaries (crossing into sector 1 or 2; the theta=0 boundary is the finish above)
	if _started and rho > RMIN[_active] and rho < RMAX[_active]:
		var sec := int(fposmod(theta, TAU) / (TAU / float(SECTORS))) % SECTORS
		if sec == (_cur_sector + 1) % SECTORS and sec != 0:
			_record_sector(_cur_sector, _lap_t - _sector_start_t)
			_sector_start_t = _lap_t
			_cur_sector = sec

	_flash = maxf(0.0, _flash - delta)
	_update_ghost(cp, rho)

func _switch_circuit(which: int) -> void:
	_active = which
	if stage != null and car != null:
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
	_prev_theta = atan2(cp.z, cp.x)     # avoid a false crossing right after the teleport

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

func _update_ghost(cp: Vector3, rho: float) -> void:
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
	if rho > RMIN[_active] - 6.0 and rho < RMAX[_active] + 6.0:
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
