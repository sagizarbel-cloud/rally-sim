extends SceneTree
## ENGINE-MIGRATION BASELINES (docs/PROMPT-godot-46-migration.md, step 0) - 2026-11-23.
##
## One test per process, so every test starts from the same cold state. The same script runs
## unchanged on Godot 4.4 and 4.6; step 3 of the migration is a re-run and a diff, not a rewrite.
## Nothing here is wired into the game. Physics tests run headless with a fixed step:
##
##   GODOT --headless --path . --fixed-fps 120 --script res://tools/baseline/capture.gd
##   env: BL_TEST = drag | pogo | skid | lap | stream | lattice | shots
##        BL_OUT  = absolute output directory
##        BL_CIRCUIT = 0 | 1 | 2 (lap only: DIRT CIRCLE, RALLY LOOP, ASPHALT RING)
##   shots needs a renderer: run it without --headless (xvfb in the cloud, a window on the Mac).
##
## The autopilot in `lap` and `stream` is a TEST HARNESS, not a driver: pure pursuit on the
## circuit's own centreline and a speed target from its curvature. Its lap times are only good for
## comparing one engine build against another, never as a measure of the car.

const SETTLE := 240                     ## ticks parked before a test starts (2 s at 120 Hz)

var test := ""
var out_dir := ""
var main: Node
var car: RigidBody3D
var stage: Node
var tt: Node
var area: Node
var tick := 0
var t_run := -1                         ## tick the test proper started
var rows := PackedStringArray()
var summary := {}
var phase := 0
var _shots_left: Array = []
var _shot_name := ""
var _shot_wait := 0
var _cam: Camera3D

func _find(n: Node, pred: Callable) -> Node:
	if pred.call(n):
		return n
	for c in n.get_children():
		var r = _find(c, pred)
		if r != null:
			return r
	return null

func _initialize() -> void:
	test = OS.get_environment("BL_TEST")
	out_dir = OS.get_environment("BL_OUT")
	if test == "lattice":
		OS.set_environment("RS_LATTICE_OUT", out_dir.path_join("lattice.txt"))
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	if test == "shots":
		RenderingServer.frame_post_draw.connect(_post_draw)

# ------------------------------------------------------------------ helpers

func _in(action: String, v: float) -> void:
	if v > 0.001:
		Input.action_press(action, clampf(v, 0.0, 1.0))
	else:
		Input.action_release(action)

func _release_all() -> void:
	for a in ["throttle", "brake", "handbrake", "steer_left", "steer_right", "shift_up", "shift_down", "clutch"]:
		if InputMap.has_action(a):
			Input.action_release(a)

func _place(xf: Transform3D) -> void:
	car.spawn_transform = xf
	car.respawn()

func _strip_xf(dx: float) -> Transform3D:
	var x: float = float(stage.get("strip_x0")) + dx
	var y: float = float(stage.get("_strip_elev")) + 1.2
	var p := Vector3(x, y, 0.0)
	return Transform3D(Basis(), p).looking_at(p + Vector3.RIGHT, Vector3.UP)

func _fz() -> Array:
	var out := []
	for w in car.get("_wheels"):
		out.append(w.Fz)
	return out

func _omega() -> Array:
	var out := []
	for w in car.get("_wheels"):
		out.append(w.omega)
	return out

func _row(extra: Array = []) -> void:
	var p := car.global_position
	var v := car.linear_velocity
	var r := [float(tick - t_run) / 120.0, p.x, p.y, p.z, v.x, v.y, v.z, v.length() * 3.6,
		int(car.get("_gear")), float(car.get("_engine_rpm"))]
	r.append_array(_fz())
	r.append_array(_omega())
	r.append_array(extra)
	var s := PackedStringArray()
	for x in r:
		s.append(("%.6f" % x) if x is float else str(x))
	rows.append(",".join(s))

const HEAD := "t,x,y,z,vx,vy,vz,kmh,gear,rpm,fz0,fz1,fz2,fz3,w0,w1,w2,w3"

var _last_shift := -100000
func _shift_logic(allow_down := false) -> void:
	# tap a shift for one tick: up near the redline, down when the engine bogs. A press and a
	# release in the SAME tick is not a "just pressed", so a tap is released on the next tick and
	# no new one is made until then.
	var red: float = float(car.get("redline_rpm"))
	var rpm: float = float(car.get("_engine_rpm"))
	var g: int = int(car.get("_gear"))
	if Input.is_action_pressed("shift_up") or Input.is_action_pressed("shift_down"):
		Input.action_release("shift_up")
		Input.action_release("shift_down")
		return
	if float(car.get("_shift_t")) > 0.0 or tick - _last_shift < 96:     # 0.8 s between shifts
		return
	if rpm > red * 0.93 and g < (car.get("gear_ratios") as Array).size():
		Input.action_press("shift_up")
		_last_shift = tick
	elif allow_down and rpm < red * 0.42 and g > 1:
		Input.action_press("shift_down")
		_last_shift = tick

func _pursue(cl, ahead_extra: float, a_lat: float, vmax: float) -> void:
	var p := car.global_position
	var v := car.linear_velocity.length()
	var np: Dictionary = cl.nearest_point(p.x, p.z)
	var s: float = np["s"]
	var look := clampf(6.0 + 0.45 * v, 8.0, 30.0) + ahead_extra
	var tgt: Vector3 = cl.point_at(s + look)["pos"]
	var b := car.global_transform.basis
	var fwd := Vector2(-b.z.x, -b.z.z).normalized()
	var left := Vector2(fwd.y, -fwd.x)
	var d := Vector2(tgt.x - p.x, tgt.z - p.z).normalized()
	var ang := atan2(d.dot(left), d.dot(fwd))
	var st := clampf(ang * 2.5, -1.0, 1.0)
	_in("steer_left", st)
	_in("steer_right", -st)
	var kmax := 0.0
	var k := 10.0
	while k <= 70.0:
		kmax = maxf(kmax, absf(float(cl.point_at(s + k)["curvature"])))
		k += 5.0
	var vt := minf(vmax, sqrt(a_lat / maxf(kmax, 1e-4)))
	_in("throttle", clampf((vt - v) * 0.5, 0.0, 1.0))
	_in("brake", clampf((v - vt - 1.0) * 0.3, 0.0, 1.0))
	_shift_logic(true)

func _write(name: String, head: String) -> void:
	var f := FileAccess.open(out_dir.path_join(name), FileAccess.WRITE)
	f.store_line(head)
	for r in rows:
		f.store_line(r)
	f.close()
	rows.clear()

func _finish() -> bool:
	summary["engine"] = Engine.get_version_info()["string"]
	var f := FileAccess.open(out_dir.path_join("%s_summary.json" % _tag()), FileAccess.WRITE)
	f.store_string(JSON.stringify(summary, "  ", true))
	f.close()
	_release_all()
	print("BASELINE ", _tag(), " ", JSON.stringify(summary))
	return true

func _tag() -> String:
	if test == "lap":
		return "lap%s" % OS.get_environment("BL_CIRCUIT")
	return test

# ------------------------------------------------------------------ main loop

func _physics_process(_delta: float) -> bool:
	tick += 1
	if tick == 3:
		car = _find(main, func(n): return n is RigidBody3D and n.name == "Vehicle")
		stage = _find(main, func(n): return n.get("strip_x0") != null)
		tt = _find(main, func(n): return n.has_method("_switch_circuit"))
		area = _find(main, func(n): return n is StageArea)
		if test == "lattice":
			var p: Node = load("res://scripts/probe_ground_lattice.gd").new()
			p.stage = stage
			p.fx = _find(main, func(n): return n.name == "SurfaceEffects")
			main.add_child(p)
		return false
	if tick < 3 or test == "lattice":
		return tick > 2000
	match test:
		"drag": return _t_drag()
		"pogo": return _t_pogo()
		"skid": return _t_skid()
		"lap": return _t_lap()
		"stream": return _t_stream()
		"shots": return _t_shots()
	push_error("BL_TEST unknown: " + test)
	return true

## Standing start on the drag strip, full throttle through the gears for 30 s, then 25 s of coast.
func _t_drag() -> bool:
	if tick == 5:
		_place(_strip_xf(40.0))
		return false
	if tick < 5 + SETTLE:
		return false
	if t_run < 0:
		t_run = tick
	var t := float(tick - t_run) / 120.0
	if t < 30.0:
		_in("throttle", 1.0)
		_shift_logic()
	else:
		_in("throttle", 0.0)
		Input.action_release("shift_up")
	_row()
	var kmh := car.linear_velocity.length() * 3.6
	for mark in [100, 160, 200]:
		var key := "t_0_%d" % mark
		if kmh >= mark and not summary.has(key):
			summary[key] = t
	for dm in [402.0, 1000.0]:
		var key2 := "t_%dm" % int(dm)
		if car.global_position.x - (float(stage.get("strip_x0")) + 40.0) >= dm and not summary.has(key2):
			summary[key2] = t
	if is_equal_approx(t, 30.0) or (t > 30.0 and not summary.has("kmh_at_30s")):
		summary["kmh_at_30s"] = kmh
	if t >= 55.0 or car.global_position.x > float(stage.get("strip_x1")) - 60.0:
		summary["kmh_end"] = kmh
		summary["x_end"] = car.global_position.x
		_write("drag.csv", HEAD)
		return _finish()
	return false

## The pogo statistic: coast with no input at each speed, % of ticks where the four wheels carry
## less than 15% of the car's static weight. Wheels are spun up to road speed and the box is in
## neutral, so the engine plays no part.
const POGO_KMH := [198.0, 299.0, 468.0, 489.6]
const POGO_S := 4.0
var _pogo_i := 0
var _pogo_low := 0
var _pogo_n := 0
var _pogo_min := 1e9
var _pogo_sum := 0.0
func _t_pogo() -> bool:
	if tick == 5:
		_place(_strip_xf(100.0))
		return false
	if tick < 5 + SETTLE:
		return false
	if t_run < 0:
		t_run = tick
		var v: float = POGO_KMH[_pogo_i] / 3.6
		car.set("_gear", 0)
		car.linear_velocity = Vector3.RIGHT * v
		for w in car.get("_wheels"):
			w.omega = v / float(car.get("wheel_radius"))
		_pogo_low = 0; _pogo_n = 0; _pogo_min = 1e9; _pogo_sum = 0.0
		return false
	var tot := 0.0
	for f in _fz():
		tot += f
	var wstat: float = car.mass * 9.8
	_pogo_n += 1
	_pogo_sum += tot
	_pogo_min = minf(_pogo_min, tot)
	if tot < 0.15 * wstat:
		_pogo_low += 1
	_row([tot / wstat])
	if tick - t_run >= int(POGO_S * 120.0):
		var key := "%.1f" % POGO_KMH[_pogo_i]
		summary[key] = {"pct_low": 100.0 * float(_pogo_low) / float(_pogo_n),
			"min_load_frac": _pogo_min / wstat, "mean_load_frac": _pogo_sum / float(_pogo_n) / wstat}
		_write("pogo_%s.csv" % key, HEAD + ",load_frac")
		_pogo_i += 1
		if _pogo_i >= POGO_KMH.size():
			return _finish()
		_place(_strip_xf(100.0))
		t_run = -1
		tick = 5          # re-settle for the next speed
	return false

## Constant steer, constant throttle on the flat asphalt runoff pad at the end of the strip.
func _t_skid() -> bool:
	if tick == 5:
		var x1: float = float(stage.get("strip_x1"))
		var r: float = float(stage.get("runoff_r")) if stage.get("runoff_r") != null else 60.0
		var y: float = float(stage.get("_strip_elev")) + 1.2
		var p := Vector3(x1, y, r * 0.55)
		_place(Transform3D(Basis(), p).looking_at(p + Vector3.RIGHT, Vector3.UP))
		summary["pad_r"] = r
		return false
	if tick < 5 + SETTLE:
		return false
	if t_run < 0:
		t_run = tick
	var t := float(tick - t_run) / 120.0
	_in("steer_left", 0.45)
	_in("throttle", 0.0 if t < 1.0 else 0.32)
	_shift_logic()
	_row()
	if t >= 30.0:
		summary["kmh_end"] = car.linear_velocity.length() * 3.6
		summary["yaw_rate_end"] = car.angular_velocity.y
		summary["pos_end"] = [car.global_position.x, car.global_position.z]
		_write("skid.csv", HEAD)
		return _finish()
	return false

## Two flying laps behind the harness autopilot; lap and sector times from time_trial itself.
var _laps := 0
var _sector := -1
var _stuck := 0.0
func _t_lap() -> bool:
	var which := int(OS.get_environment("BL_CIRCUIT"))
	if tick == 5:
		tt._switch_circuit(which)
		return false
	if tick < 5 + SETTLE:
		return false
	if t_run < 0:
		t_run = tick
		summary["laps"] = []
		summary["sectors"] = []
	var cl = tt.centrelines[which]
	# the same modest target on all three: at 7.5 m/s^2 the harness ran wide off the ASPHALT RING's
	# east side, past the edge of the legacy terrain (it is a harness, not a driver)
	_pursue(cl, 0.0, 5.5, 42.0)
	_row([float(tt.get("_lap_t")), int(tt.get("_cur_sector"))])
	var sec := int(tt.get("_cur_sector"))
	if sec != _sector:
		(summary["sectors"] as Array).append([float(tick - t_run) / 120.0, sec, float(tt.get("_lap_t"))])
		# a lap ends where the sector wraps back to 0 (two laps can have the SAME time, so watching
		# `_last` for a change misses one)
		if sec == 0 and _sector > 0:
			var last: Array = tt.get("_last")
			_laps += 1
			(summary["laps"] as Array).append(float(last[which]))
		_sector = sec
	if car.linear_velocity.length() < 1.0:
		_stuck += 1.0 / 120.0
	else:
		_stuck = 0.0
	var t := float(tick - t_run) / 120.0
	var np: Dictionary = cl.nearest_point(car.global_position.x, car.global_position.z)
	var off := absf(float(np["lateral"])) > 25.0
	if _laps >= 3 or t > 420.0 or _stuck > 6.0 or off:
		summary["stuck"] = _stuck > 6.0
		summary["left_road"] = off
		summary["t_end"] = t
		_write("lap%d.csv" % which, HEAD + ",lap_t,sector")
		return _finish()
	return false

## SHAKEDOWN's streamer: what is resident after arriving, and after 60 s of driving the stage.
func _t_stream() -> bool:
	if tick == 5:
		tt._switch_circuit(3)
		return false
	if tick == 5 + 600:
		summary["after_arrive"] = _stats()
		t_run = tick
		return false
	if t_run < 0:
		return false
	_pursue(area.gen.centreline, 0.0, 5.5, 40.0)
	if tick - t_run >= 60 * 120:
		summary["after_60s"] = _stats()
		summary["pos"] = [car.global_position.x, car.global_position.z]
		return _finish()
	return false

func _stats() -> Dictionary:
	var st: Dictionary = area.chunks.stats()
	var keep := {}
	for k in ["live", "peak", "built", "budget", "r_solid", "r_detail", "r_view", "span", "colliders", "cached"]:
		if st.has(k):
			keep[k] = st[k]
	return keep

# ------------------------------------------------------------------ screenshots

func _t_shots() -> bool:
	if tick == 5:
		car.freeze = true
		_shots_left = _shot_list()
		return false
	if _shot_wait > 0:
		_shot_wait -= 1
		return false
	if _shot_name != "":
		return false            # waiting for the draw
	if _shots_left.is_empty():
		return _finish()
	var s: Dictionary = _shots_left.pop_front()
	if s.has("circuit"):
		tt._switch_circuit(int(s["circuit"]))
		car.freeze = true
	if s.has("shadow"):
		car.set("gfx_shadow_mode", int(s["shadow"]))
	if _cam == null:
		_cam = Camera3D.new()
		_cam.far = 4000.0
		root.add_child(_cam)
	var eye: Vector3 = s["eye"].call() if s["eye"] is Callable else s["eye"]
	var at: Vector3 = s["at"].call() if s["at"] is Callable else s["at"]
	_cam.look_at_from_position(eye, at, Vector3.UP if absf((at - eye).normalized().y) < 0.99 else Vector3.FORWARD)
	_cam.current = true
	_shot_wait = int(s.get("wait", 240))
	_shot_name = s["name"]
	_shot_armed = false
	return false

var _shot_armed := false
func _post_draw() -> void:
	if _shot_name == "" or _shot_wait > 0:
		return
	if not _shot_armed:
		_shot_armed = true          # one more frame so the camera's first frame is not the capture
		return
	root.get_texture().get_image().save_png(out_dir.path_join(_shot_name + ".png"))
	summary[_shot_name] = "ok"
	_shot_name = ""

func _shot_list() -> Array:
	var sp: Transform3D = stage.get_spawn_for(1)
	var c: Vector3 = stage.get("road_center") if stage.get("road_center") != null else Vector3.ZERO
	var list := [
		{"name": "bed_spawn", "eye": sp.origin + Vector3(0, 6, 0) - sp.basis.z * -10.0, "at": sp.origin - sp.basis.z * 25.0},
		{"name": "bed_overhead", "eye": c + Vector3(0, 420, 1), "at": c},
	]
	# SHAKEDOWN: the corridor from a fixed point on its centreline, in LIVE and BAKED, and a chunk
	# seam (a multiple of the chunk span) from above and from below.
	var cam_on_stage := func(s_m: float, up: float, back: float) -> Callable:
		return func() -> Vector3:
			var q: Dictionary = area.gen.centreline.point_at(s_m)
			var pp: Vector3 = q["pos"]
			var h: Vector2 = q["heading"]
			return Vector3(pp.x - h.x * back, area.height_at(pp.x, pp.z) + up, pp.z - h.y * back)
	var look_on_stage := func(s_m: float) -> Callable:
		return func() -> Vector3:
			var q: Dictionary = area.gen.centreline.point_at(s_m)
			var pp: Vector3 = q["pos"]
			return Vector3(pp.x, area.height_at(pp.x, pp.z), pp.z)
	list.append({"name": "stage_live", "circuit": 3, "shadow": 0, "wait": 720,
		"eye": cam_on_stage.call(400.0, 7.0, 12.0), "at": look_on_stage.call(440.0)})
	list.append({"name": "stage_baked", "shadow": 2, "wait": 900,
		"eye": cam_on_stage.call(400.0, 7.0, 12.0), "at": look_on_stage.call(440.0)})
	list.append({"name": "stage_hybrid", "shadow": 1, "wait": 900,
		"eye": cam_on_stage.call(400.0, 7.0, 12.0), "at": look_on_stage.call(440.0)})
	var seam := func(up: float) -> Callable:
		return func() -> Vector3:
			var q: Dictionary = area.gen.centreline.point_at(400.0)
			var pp: Vector3 = q["pos"]
			var span: float = float(area.chunks.span)
			var sx := roundf(pp.x / span) * span
			var sz := roundf(pp.z / span) * span
			return Vector3(sx + 0.5, area.height_at(sx, sz) + up, sz + 0.5)
	var seam_at := func(up: float) -> Callable:
		return func() -> Vector3:
			var e: Vector3 = seam.call(up).call()
			return e + Vector3(0.01, -signf(up) * 10.0, 0.0)
	list.append({"name": "seam_above", "shadow": 0, "wait": 360, "eye": seam.call(30.0), "at": seam_at.call(30.0)})
	list.append({"name": "seam_below", "wait": 120, "eye": seam.call(-4.0), "at": seam_at.call(-4.0)})
	# the stage's start: the transition pad and the tunnel mouth, from the stage side
	list.append({"name": "stage_start", "wait": 240, "eye": cam_on_stage.call(0.0, 4.0, -25.0), "at": look_on_stage.call(-20.0)})
	return list
