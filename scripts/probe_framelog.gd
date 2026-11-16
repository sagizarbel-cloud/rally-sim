extends Node
## TEMPORARY - D4's hiccup item, measured instead of eyeballed. Delete this file together with its
## block in world.gd when the item closes.
##
## v2 (2026-11-16). v1 logged ONE number per frame - the engine's `delta` - and three drives of it
## could say WHEN a frame was long but never WHERE the time went. Reading those logs closely also
## turned up three faults, two in the instrument and one in how a run was started:
##   * `delta` is CLAMPED at 8 physics steps (66.7 ms): a 70 ms stall and a 300 ms stall logged the
##     same number.
##   * `Performance.TIME_PHYSICS_PROCESS` is the worst tick of the LAST SECOND, republished once a
##     second. It was being read as a per-frame figure.
##   * A window opened BEHIND another app is not vsynced. Run 3 free-ran at ~137 fps for its first
##     28 s, and the long frames in that stretch were the window being brought forward. They were
##     read as "the game hitches early in a session", which they were not.
##
## So v2 cuts every frame into the sections the engine actually executes, on the wall clock:
##
##   |- idle scripts -|- pre -|-------- draw --------|- post -|--- physics ticks ---|
##   ^ _process starts        ^ frame_pre_draw       ^ frame_post_draw              ^ next _process
##
##   physics  every tick of the iteration: scripts, then the Jolt step. The scripts are split PER
##            SYSTEM by marker nodes slotted between the world's children, so the streamer, the
##            car and the effects are separate columns instead of one total.
##   idle     the same per-system split for _process.
##   draw     RenderingServer's whole frame: culling, command building, any pipeline compiled on
##            first use, and the present - which is where a vsynced game WAITS. The viewport's own
##            measured CPU and GPU times sit beside it, to tell working from waiting.
##   post     the frame limiter, the OS event pump, audio: whatever runs between two iterations.
##
## Beside the sections: the five pipeline-compilation counters (a shader compiled mid-drive is a
## hitch no CPU timer explains); a fixed calibration loop timed every frame (if the SAME loop takes
## three times as long, the processor itself got slower - thermal throttling, or the thread parked
## on an efficiency core); whether the window has focus; and every key or pad button as an event
## line, so a stall can be matched to "that was [B]" instead of guessed at.
##
## Never in a headless run, and never the same file twice: the compile gate runs the game headless
## for 60 frames, and v1's fixed path let it truncate a whole measured drive (run 2 was lost so).
##
## Run: just start the game and drive; quit normally. The log lands in the game's user data folder
## as framelog-<timestamp>.csv, or at RS_FRAMELOG=/abs/path.csv when that is set.

class Mark extends Node:
	## A timestamp between two systems. Nodes of equal priority are processed in tree order, parent
	## before child, so a marker placed straight after system X runs after X and all of X's subtree.
	var sink: Node
	var slot := 0
	func _physics_process(_d: float) -> void:
		sink.mark_phys(slot)
	func _process(_d: float) -> void:
		sink.mark_idle(slot)

const EARLY := -1000000
const LATE := 1000000
const CAL_N := 2000                  # iterations of the calibration loop (~60 us on this machine)

var area
var car

var _f: FileAccess
var _armed := false
var _names: PackedStringArray = []
var _ph: PackedInt64Array = []       # per-system physics script time this iteration, us
var _id: PackedInt64Array = []       # per-system idle script time, us
var _last := 0                       # wall clock at the previous marker
var _want := 0                       # next marker slot expected (order check)
var _order_bad := 0
var _ticks := 0
var _phys_begin := 0
var _tick_begin := 0
var _tick_max := 0
var _step_sum := 0
var _step_max := 0
var _idle_begin := 0
var _idle_end := 0
var _pre_draw := 0
var _post_draw := 0
var _log_us := 0
var _rows := 0
var _worst := 0
var _worst_at := 0.0
var _t_first := 0.0
var _t_last := 0.0
var _vp: RID
var _mir: RID
var _has_mir := false
var _fx
var _fx_n := 0
var _fx_live := 0
var _frame := 0
var _mode := -1
var _stage_was := -1
var _tts_was := false
var _prev_built := 0
var _prev_scans := 0
var _prev_scan_us := 0
var _prev_fin_us := 0
var _prev_bands := 0
var _slow_at := 0
var _nodes := 0
var _objects := 0
var _mem_mb := 0
var _vram_mb := 0
# SELF-TEST, so a fix can be measured before the driver is asked to spend a drive on it:
#   RS_FRAMELOG_STAGE=1   park the car on SHAKEDOWN's start two seconds in (what [B] does)
#   RS_FRAMELOG_STALL=40  block the main thread for 40 ms every 4 s, to watch the RECOVERY
var _auto_stage := OS.get_environment("RS_FRAMELOG_STAGE") == "1"
var _stall_ms := OS.get_environment("RS_FRAMELOG_STALL").to_int()
var _stall_next := 0

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		queue_free()
		return
	var out := OS.get_environment("RS_FRAMELOG")
	if out == "":
		var stamp := Time.get_datetime_string_from_system().replace(":", "-")
		out = OS.get_user_data_dir() + "/framelog-%s.csv" % stamp
	_f = FileAccess.open(out, FileAccess.WRITE)
	if _f == null:
		push_error("FRAMELOG: cannot open %s" % out)
		queue_free()
		return
	# First in both loops whatever its place in the tree: it opens each tick and each frame.
	process_priority = EARLY
	process_physics_priority = EARLY
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	# Deferred: the world is still inside its own _ready() and its children are not all in yet.
	_install.call_deferred()

func _install() -> void:
	var root := get_parent()
	var kids := root.get_children()
	_add_mark(root, -1, "world")         # index 0: after the root's own callback, before its children
	for k in kids:
		if k == self:
			continue
		if _fx == null and _script_base(k) == "effects":
			_fx = k
		if _subtree_processes(k):
			_add_mark(root, k.get_index(), _label(k))
	var tail := Mark.new()               # last in both loops: closes the scripts, opens the engine's part
	tail.sink = self
	tail.slot = _names.size()
	tail.process_priority = LATE
	tail.process_physics_priority = LATE
	add_child(tail)
	_names.append("rest")
	_ph.resize(_names.size())
	_ph.fill(0)
	_id.resize(_names.size())
	_id.fill(0)
	var sub := _find_subviewport(root)
	if sub != null:
		_mir = sub.get_viewport_rid()
		_has_mir = true
		RenderingServer.viewport_set_measure_render_time(_mir, true)
	_write_header()
	_armed = true

func _add_mark(root: Node, after_index: int, label: String) -> void:
	var m := Mark.new()
	m.sink = self
	m.slot = _names.size()
	m.name = "FrameLogMark%d" % m.slot
	root.add_child(m)
	root.move_child(m, after_index + 1)
	var l := label
	if _names.has(l):
		l = "%s%d" % [label, m.slot]
	_names.append(l)

func _script_base(n: Node) -> String:
	var s: Script = n.get_script()
	if s == null:
		return ""
	return s.resource_path.get_file().get_basename()

func _processes(n: Node) -> bool:
	return n.get_script() != null and (n.has_method("_physics_process") or n.has_method("_process"))

func _subtree_processes(n: Node) -> bool:
	if _processes(n):
		return true
	for c in n.get_children():
		if _subtree_processes(c):
			return true
	return false

func _label(n: Node) -> String:
	# Named after the first script in the subtree that processes: "hud", not "@CanvasLayer@12".
	if _processes(n):
		return _script_base(n)
	for c in n.get_children():
		if _subtree_processes(c):
			return _label(c)
	return String(n.name)

func _find_subviewport(n: Node) -> SubViewport:
	if n is SubViewport:
		return n
	for c in n.get_children():
		var r := _find_subviewport(c)
		if r != null:
			return r
	return null

func _write_header() -> void:
	var win := DisplayServer.window_get_size()
	var scr := DisplayServer.screen_get_size()
	_f.store_line("# framelog v2 | Godot %s | %s / %s | %s" % [
			str(Engine.get_version_info()["string"]), RenderingServer.get_current_rendering_driver_name(),
			RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_name()])
	_f.store_line("# screen %dx%d @ %.1f Hz | window %dx%d mode %d | vsync mode %d | max_fps %d | physics %d Hz, max %d steps/frame" % [
			scr.x, scr.y, DisplayServer.screen_get_refresh_rate(), win.x, win.y, DisplayServer.window_get_mode(),
			DisplayServer.window_get_vsync_mode(), Engine.max_fps, Engine.physics_ticks_per_second,
			Engine.max_physics_steps_per_frame])
	_f.store_line("# systems: %s" % ",".join(_names))
	var cols := PackedStringArray(["t_s", "dt_us", "ticks", "phys_us", "tick_max_us", "step_sum_us", "step_max_us",
			"idle_us", "pre_us", "draw_us", "post_us", "cal_us", "log_us", "setup_us", "vp_cpu_us", "vp_gpu_us",
			"mir_cpu_us", "mir_gpu_us", "pc_canvas", "pc_mesh", "pc_surface", "pc_draw", "pc_spec", "draws", "prims",
			"objs", "built", "scans", "scan_us", "finalise_us", "band_marks", "r_solid", "live", "cached", "speed_kmh", "on_stage", "focus", "fx_n", "fx_live", "nodes",
			"objects", "mem_mb", "vram_mb"])
	for n in _names:
		cols.append("p_" + n)
	for n in _names:
		cols.append("i_" + n)
	_f.store_line(",".join(cols))

# --- the markers call in here ---------------------------------------------------------------

func mark_phys(slot: int) -> void:
	var now := Time.get_ticks_usec()
	_ph[slot] += now - _last
	_last = now
	if slot != _want:
		_order_bad += 1
	_want = slot + 1

func mark_idle(slot: int) -> void:
	var now := Time.get_ticks_usec()
	_id[slot] += now - _last
	_last = now
	_idle_end = now                      # the tail marker is the last to write this

func _on_pre_draw() -> void:
	_pre_draw = Time.get_ticks_usec()

func _on_post_draw() -> void:
	_post_draw = Time.get_ticks_usec()

func _close_tick(now: int) -> void:
	# Everything since the tail marker is the physics SERVER's share of the tick: the Jolt step.
	var step := now - _last
	_step_sum += step
	if step > _step_max:
		_step_max = step
	var tick := now - _tick_begin
	if tick > _tick_max:
		_tick_max = tick

func _physics_process(_d: float) -> void:
	if not _armed:
		return
	var now := Time.get_ticks_usec()
	if _ticks == 0:
		_phys_begin = now
	else:
		_close_tick(now)
	_tick_begin = now
	_ticks += 1
	_want = 0
	_last = Time.get_ticks_usec()

func _process(_d: float) -> void:
	if not _armed:
		return
	var now := Time.get_ticks_usec()
	if _ticks > 0:
		_close_tick(now)
	if _idle_begin != 0:
		_write_row(now)
	_idle_begin = now
	_ticks = 0
	_tick_max = 0
	_step_sum = 0
	_step_max = 0
	_ph.fill(0)
	_id.fill(0)
	_frame += 1
	_poll_state(now)
	_self_test(now)
	_last = Time.get_ticks_usec()
	_log_us = _last - now                # this probe's own cost, reported in the NEXT row

func _calibrate() -> int:
	var t0 := Time.get_ticks_usec()
	var a := 0
	for i in CAL_N:
		a += i & 7
	return Time.get_ticks_usec() - t0

func _write_row(now: int) -> void:
	# One row = one interval between two _process starts: the idle and draw of the iteration that
	# just ended, then the physics ticks of the one that has just begun.
	var dt := now - _idle_begin
	var idle := maxi(_idle_end - _idle_begin, 0)
	var next_begin := _phys_begin if _ticks > 0 else now
	var pre := 0
	var draw := 0
	var post := 0
	if _pre_draw >= _idle_end and _post_draw >= _pre_draw and _idle_end >= _idle_begin:
		pre = _pre_draw - _idle_end
		draw = _post_draw - _pre_draw
		post = next_begin - _post_draw
	else:
		post = next_begin - maxi(_idle_end, _idle_begin)     # nothing was drawn in that iteration
	var phys := (now - _phys_begin) if _ticks > 0 else 0

	var built := 0
	var live := 0
	var cached := 0
	var scans := 0
	var scan_us := 0
	var fin_us := 0
	var bands := 0
	var r_solid := 0
	if area != null and area.chunks != null:
		var st: Dictionary = area.chunks.stats()
		var b: int = int(st["built"])
		built = b - _prev_built
		_prev_built = b
		live = int(st["live"])
		cached = int(st["cached"])
		if st.has("scans"):
			var sc: int = int(st["scans"])
			scans = sc - _prev_scans
			_prev_scans = sc
		if st.has("scan_us"):
			scan_us = int(st["scan_us"]) - _prev_scan_us
			_prev_scan_us = int(st["scan_us"])
			fin_us = int(st["finalise_us"]) - _prev_fin_us
			_prev_fin_us = int(st["finalise_us"])
			bands = int(st["band_marks"]) - _prev_bands
			_prev_bands = int(st["band_marks"])
			r_solid = int(float(st["r_solid"]))
	var spd := 0.0
	if car != null:
		var v: Vector3 = car.linear_velocity
		spd = Vector2(v.x, v.z).length() * 3.6       # HORIZONTAL speed; see §0's probe hygiene

	var t_s := float(now) / 1e6
	if _rows == 0:
		_t_first = t_s
	_t_last = t_s
	if _rows > 60 and dt > _worst:                   # the first second is startup, not driving
		_worst = dt
		_worst_at = t_s

	var row := PackedStringArray()
	row.append("%.4f" % t_s)
	row.append(str(dt))
	row.append(str(_ticks))
	row.append(str(phys))
	row.append(str(_tick_max))
	row.append(str(_step_sum))
	row.append(str(_step_max))
	row.append(str(idle))
	row.append(str(pre))
	row.append(str(draw))
	row.append(str(post))
	row.append(str(_calibrate()))
	row.append(str(_log_us))
	row.append(str(int(RenderingServer.get_frame_setup_time_cpu() * 1000.0)))
	row.append(str(int(RenderingServer.viewport_get_measured_render_time_cpu(_vp) * 1000.0)))
	row.append(str(int(RenderingServer.viewport_get_measured_render_time_gpu(_vp) * 1000.0)))
	if _has_mir:
		row.append(str(int(RenderingServer.viewport_get_measured_render_time_cpu(_mir) * 1000.0)))
		row.append(str(int(RenderingServer.viewport_get_measured_render_time_gpu(_mir) * 1000.0)))
	else:
		row.append("0")
		row.append("0")
	row.append(str(int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS))))
	row.append(str(int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH))))
	row.append(str(int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE))))
	row.append(str(int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW))))
	row.append(str(int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION))))
	row.append(str(int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))))
	row.append(str(int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))))
	row.append(str(int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))))
	row.append(str(built))
	row.append(str(scans))
	row.append(str(scan_us))
	row.append(str(fin_us))
	row.append(str(bands))
	row.append(str(r_solid))
	row.append(str(live))
	row.append(str(cached))
	row.append("%.1f" % spd)
	row.append("1" if live > 0 else "0")
	row.append("1" if DisplayServer.window_is_focused() else "0")
	row.append(str(_fx_n))
	row.append(str(_fx_live))
	row.append(str(_nodes))
	row.append(str(_objects))
	row.append(str(_mem_mb))
	row.append(str(_vram_mb))
	for x in _ph:
		row.append(str(x))
	for x in _id:
		row.append(str(x))
	_f.store_line(",".join(row))
	_rows += 1

func _poll_state(now: int) -> void:
	# Things that change rarely, sampled rarely, and written as EVENT lines when they flip.
	if _frame % 6 == 0:
		var n := 0
		var livep := 0.0
		if _fx != null:
			var em: Dictionary = _fx._em
			for layer in em:
				for p in em[layer]:
					var q: GPUParticles3D = p
					if q.emitting:
						n += 1
						livep += float(q.amount) * q.amount_ratio
		_fx_n = n
		_fx_live = int(livep)
		var speaking := DisplayServer.tts_is_speaking()
		if speaking != _tts_was:
			_tts_was = speaking
			_evt("TTS", "start" if speaking else "stop")
	var mode := DisplayServer.window_get_mode()
	if mode != _mode:
		_mode = mode
		var win := DisplayServer.window_get_size()
		_evt("WINMODE", "%d %dx%d" % [mode, win.x, win.y])
	var on_stage := 0
	if area != null and area.chunks != null and int(area.chunks.stats()["live"]) > 0:
		on_stage = 1
	if on_stage != _stage_was:
		_stage_was = on_stage
		_evt("AREA", "stage" if on_stage == 1 else "legacy")
	if now - _slow_at > 1000000:
		_slow_at = now
		_nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		_objects = int(Performance.get_monitor(Performance.OBJECT_COUNT))
		_mem_mb = int(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0)
		_vram_mb = int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0)

func _self_test(now: int) -> void:
	if _auto_stage and _rows == 120 and area != null and car != null:
		car.spawn_transform = area.spawn_transform()
		car.respawn()
		_evt("TEST", "teleport_to_stage")
	if _stall_ms > 0 and _rows > 0:
		if _stall_next == 0:
			# With the car parked on the stage the first stall lands 2 s after the teleport, i.e.
			# INSIDE the far-field fill; the later ones land once there is nothing left to build.
			_stall_next = now + (4500000 if _auto_stage else 12000000)
		elif now >= _stall_next:
			_stall_next = now + 4000000
			_evt("TEST", "stall %d ms" % _stall_ms)
			var until := Time.get_ticks_usec() + _stall_ms * 1000
			while Time.get_ticks_usec() < until:
				pass

# --- events ---------------------------------------------------------------------------------

func _evt(kind: String, detail: String) -> void:
	if _f == null or not _armed:
		return
	_f.store_line("#EVT,%.4f,%s,%s" % [float(Time.get_ticks_usec()) / 1e6, kind, detail])

func _input(e: InputEvent) -> void:
	if e is InputEventKey:
		var k := e as InputEventKey
		if k.pressed and not k.echo:
			_evt("KEY", OS.get_keycode_string(k.physical_keycode if k.keycode == 0 else k.keycode))
	elif e is InputEventJoypadButton:
		var j := e as InputEventJoypadButton
		if j.pressed:
			_evt("PAD", str(j.button_index))

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_IN:
			_evt("APP", "focus_in")
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_evt("APP", "focus_out")
		NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_evt("WIN", "focus_in")
		NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_evt("WIN", "focus_out")
		NOTIFICATION_APPLICATION_PAUSED:
			_evt("APP", "paused")
		NOTIFICATION_APPLICATION_RESUMED:
			_evt("APP", "resumed")
		NOTIFICATION_OS_MEMORY_WARNING:
			_evt("OS", "memory_warning")

func _exit_tree() -> void:
	if _f == null:
		return
	_f.store_line("# %d frames, %.1f s, worst frame %.2f ms at t=%.2f s, marker order violations %d"
			% [_rows, _t_last - _t_first, float(_worst) / 1000.0, _worst_at, _order_bad])
	_f.close()
	print("FRAMELOG: %d frames over %.1f s, worst %.2f ms at %.2f s"
			% [_rows, _t_last - _t_first, float(_worst) / 1000.0, _worst_at])
