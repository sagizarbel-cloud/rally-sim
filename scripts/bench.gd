extends Node
## GPU COST BENCHMARK - measures what each rendering system costs, on the real machine, with
## nobody driving. Launch:   Godot --path . -- --bench            (add --bench-quick for a short run)
##
## Why it exists (2026-11-18). Godot 4.4 on Metal reports 0 for GPU time, so the only number the
## game can see is uncapped fps - and a drive mixes route, speed, time of day, thermal state and
## which settings were on when, which is what muddied the 2026-11-17 comparisons. This replays ONE
## fixed path through SHAKEDOWN's forest (car frozen and carried along the centreline at a fixed
## speed, chase camera, noon) once per configuration, changing ONE thing each time, and reports
## each configuration's frame time against the baseline. The difference IS that system's cost.
## The baseline runs first AND last: if the two disagree, the machine heated up during the run and
## the deltas in between are suspect (a fanless MacBook Air throttles under sustained load).
##
## It changes nothing outside itself: every configuration is undone before the next one.

const SPEED := 25.0          # m/s along the centreline, ~90 km/h: streaming at a realistic rate
const S_OFFSET := 220.0      # metres past the timed start - inside the forest, where fps fell
var settle_s := 4.0          # after each teleport: priming, streaming, shader compile settle
var measure_s := 15.0

var world: Node
var car: RigidBody3D
var area: Node
var tt: Node
var hud: Node

var _configs: Array = []     # [name, apply: Callable, undo: Callable]
var _ci := -1
var _phase := 0              # 0 = waiting to start, 1 = settling, 2 = measuring, 3 = done
var _t := 0.0
var _s := 0.0
var _s0 := 0.0
var _frames := PackedFloat32Array()
## Frame time is read from the wall clock between frames, NOT from `delta`. `delta` is SMOOTHED
## (application/run/delta_smoothing, on by default), which snaps it to the display's refresh period
## whenever frames run near it: the 2026-11-24 4.6.3 bench reported 16.67 ms exactly on six rows,
## and a refresh-snapped number cannot say whether a frame took 15 ms or 17.
var _last_us := 0
var _cpu := PackedFloat32Array()
var _prims := 0.0
var _draws := 0.0
var _n_info := 0
var _results: Array = []
var _start_wait := 2.0
var _forest_mode := ""       # "", "noshadow", "hidden" - applied to tree nodes as they stream in
var _flat_sky: ProceduralSkyMaterial
var _sky_saved: Material
var _vp_rid: RID
var _glow_saved: Array = []
var _budget_saved := 1.0
const HOLD_MAX_S := 25.0

func _ready() -> void:
	process_priority = 1000
	if OS.get_cmdline_user_args().has("--bench-quick"):
		settle_s = 3.0
		measure_s = 6.0
	get_tree().node_added.connect(_on_node_added)
	_vp_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)
	_build_configs()
	# --bench-rows=a,b keeps only the rows whose names start with one of the given prefixes (plus
	# their order): short A/B runs of a few rows, e.g. engine settings that need a restart
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bench-rows="):
			var keep: Array = Array(a.substr(13).split(","))
			_configs = _configs.filter(func(c): return keep.any(func(k): return str(c[0]).begins_with(str(k))))

func _build_configs() -> void:
	var nop := func(): pass
	_configs = [
		["baseline", nop, nop],
		["no sun shadows",
			func(): world._sun.shadow_enabled = false,
			func(): world._sun.shadow_enabled = true],
		# DIAGNOSTIC rows, not proposals: they split the 2.8 ms of "no sun shadows" into drawing the
		# shadow map (atlas size, splits, range) and reading it per pixel (filter, blur), which
		# decides whether baking the shadows can pay for itself.
		["shadow map 2048 (diag)",
			func(): RenderingServer.directional_shadow_atlas_set_size(2048, true),
			func(): RenderingServer.directional_shadow_atlas_set_size(
				int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size", 4096)), true)],
		["shadow 1 split (diag)",
			func(): world._sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL,
			func(): world._sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS],
		["shadow range 40 m (diag)",
			func(): car.set("gfx_shadow_m", 40.0),
			func(): car.set("gfx_shadow_m", 100.0)],
		["shadow hard filter (diag)",
			func(): RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_HARD),
			func(): RenderingServer.directional_soft_shadow_filter_set_quality(
				int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 2)) as RenderingServer.ShadowQuality)],
		["trees cast no shadow",
			func(): _set_forest("noshadow"),
			func(): _set_forest("")],
		["no trees at all",
			func(): _set_forest("hidden"),
			func(): _set_forest("")],
		["trees without sway",
			func(): _set_sway(0.0),
			func(): _set_sway(-1.0)],
		["plain sky (Godot's built-in)",
			func(): _swap_sky(true),
			func(): _swap_sky(false)],
		# ENGINE-COST diagnostics (2026-11-24): Godot 4.6.3 drew ~1.5 ms more per frame than 4.4 on
		# the same scene, growing with the pixel count - these switch off per-pixel stages one at a
		# time so the two engines can be compared stage by stage.
		["tonemap linear (diag)",
			func(): world._env.tonemap_mode = Environment.TONE_MAPPER_LINEAR,
			func(): world._env.tonemap_mode = Environment.TONE_MAPPER_FILMIC],
		["no sky reflections (diag)",
			func(): world._env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED,
			func(): world._env.reflected_light_source = Environment.REFLECTION_SOURCE_BG],
		["no fog",
			func(): world._env.fog_enabled = false,
			func(): world._env.fog_enabled = true],
		["+ SSAO",
			func():
				car.set("gfx_high", true)
				world._apply_gfx(true)
				world._env.glow_enabled = false,
			func():
				car.set("gfx_high", false)
				world._apply_gfx(false)],
		["+ glow",
			func(): world._env.glow_enabled = true,
			func(): world._env.glow_enabled = false],
		["+ glow, levels 4-7 only (diag)",
			func():
				world._env.glow_enabled = true
				_glow_saved = []
				for i in range(1, 8):
					_glow_saved.append(world._env.get_glow_level(i - 1))
					world._env.set_glow_level(i - 1, 1.0 if i >= 4 else 0.0),
			func():
				world._env.glow_enabled = false
				for i in range(7):
					world._env.set_glow_level(i, _glow_saved[i])],
		["3D at 1600 lines", func(): _set_lines(1600), func(): _set_lines(0)],
		["3D at 1080 lines", func(): _set_lines(1080), func(): _set_lines(0)],
		["baseline (again: thermal check)", nop, nop],
		# Re-baking rows LAST: a re-bake rebuilds the ground from scratch, so what follows is not the
		# same resident set as the rows above. The thermal check above compares like with like; the
		# baseline below re-measures LIVE after the re-bakes, for the shadow rows to compare against.
		["shadows HYBRID (live 40 m + baked)",
			func(): car.set("gfx_shadow_mode", 1),
			func(): car.set("gfx_shadow_mode", 0), "rebake"],
		["shadows BAKED (no shadow map)",
			func(): car.set("gfx_shadow_mode", 2),
			func(): car.set("gfx_shadow_mode", 0), "rebake"],
		["baseline (after re-bakes: compare shadow rows to this)", nop, nop],
	]

func _physics_process(delta: float) -> void:
	if _phase == 3:
		return
	if _phase == 0:
		_start_wait -= delta
		if _start_wait > 0.0:
			return
		_begin()
		return
	if _phase == 4:
		_place(_s0)                # parked while the ground re-bakes; see _next_config()
		return
	_s += SPEED * delta
	_place(_s)

func _process(delta: float) -> void:
	if _phase == 4:
		_t += delta
		var busy: bool = area.chunks._needs_prime or int(area.chunks.stats()["queued"]) > 0 or not area.chunks._job.is_empty()
		if _t >= HOLD_MAX_S or (_t >= 1.0 and not busy):
			car.set("stage_chunk_budget_ms", _budget_saved)
			_phase = 1
			_t = 0.0
		return
	if _phase == 1:
		_t += delta
		if _t >= settle_s:
			_phase = 2
			_t = 0.0
			_frames.clear()
			_last_us = 0
			_cpu.clear()
			_prims = 0.0
			_draws = 0.0
			_n_info = 0
	elif _phase == 2:
		_t += delta
		var now := Time.get_ticks_usec()
		if _last_us > 0:
			_frames.append(float(now - _last_us) / 1000.0)
		_last_us = now
		_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid) + Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		_prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		_draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		_n_info += 1
		if _t >= measure_s:
			_finish_config()

func _begin() -> void:
	car = world._car
	area = world._stage_area
	tt = world._time_trial
	tt._switch_circuit(3)
	car.freeze = true
	world._tod = 0
	world._apply_tod(0)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# macOS can recreate the window on the switch to fullscreen; ask again once it has happened,
	# and record what the window really ended up with (the report prints it)
	(func() -> void: DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)).call_deferred()
	_s0 = float(area.gen.timed_start_s) + S_OFFSET
	print("BENCH start: renderer=%s  window=%s  stage seed path s=%.0f..%.0f m" % [
		ProjectSettings.get_setting("rendering/renderer/rendering_method"), str(get_tree().root.size),
		_s0, _s0 + SPEED * (settle_s + measure_s)])
	_next_config()

func _next_config() -> void:
	_ci += 1
	if _ci >= _configs.size():
		_report()
		return
	(_configs[_ci][1] as Callable).call()
	_s = _s0
	_place(_s)
	_phase = 1
	_t = 0.0
	# A row that switches the shadow mode re-bakes the whole stage ground - and so does the row after
	# it, which switches back. Those rows first HOLD the car parked at the start of the path, with a
	# raised build budget, until the ground is rebuilt; then the usual moving settle and measurement.
	# Every row therefore measures the same stretch of road from the same moving start.
	var rebakes: bool = _configs[_ci].size() > 3 or (_ci > 0 and _configs[_ci - 1].size() > 3)
	if rebakes:
		_budget_saved = float(car.get("stage_chunk_budget_ms"))
		car.set("stage_chunk_budget_ms", 8.0)
		_phase = 4

func _finish_config() -> void:
	var f := _frames.duplicate()
	f.sort()
	var c := _cpu.duplicate()
	c.sort()
	var n := f.size()
	var med: float = f[n / 2]
	var p95: float = f[int(n * 0.95)]
	var p5: float = f[int(n * 0.05)]
	var mean := 0.0
	for x in f:
		mean += x
	mean /= float(n)
	var r := {"name": _configs[_ci][0], "frames": n, "median_ms": med, "p95_ms": p95, "p5_ms": p5, "min_ms": f[0],
		"avg_fps": 1000.0 / mean, "cpu_ms": c[c.size() / 2],
		"prims_k": _prims / float(maxi(_n_info, 1)) / 1000.0, "draws": _draws / float(maxi(_n_info, 1)),
		"render": str(_render_size())}
	_results.append(r)
	print("BENCH %-32s median %6.2f ms  p5 %6.2f  p95 %6.2f ms  avg %5.1f fps  cpu %5.2f ms  %5.0fk tris  %4.0f draws  %s" % [
		r["name"], med, p5, p95, r["avg_fps"], r["cpu_ms"], r["prims_k"], r["draws"], r["render"]])
	(_configs[_ci][2] as Callable).call()
	_next_config()

func _report() -> void:
	_phase = 3
	var base: float = _results[0]["median_ms"]
	var lines := PackedStringArray()
	lines.append("Rally Sim GPU benchmark  %s" % Time.get_datetime_string_from_system())
	lines.append("renderer=%s  window=%s  path: SHAKEDOWN s=%.0f.. at %.0f m/s, noon, chase cam, uncapped" % [
		ProjectSettings.get_setting("rendering/renderer/rendering_method"), str(get_tree().root.size), _s0, SPEED])
	lines.append("engine=%s  vsync_mode=%d (0 = disabled)  max_fps=%d  frame time = wall clock between frames" % [
		Engine.get_version_info()["string"], DisplayServer.window_get_vsync_mode(), Engine.max_fps])
	lines.append("%-32s %9s %9s %9s %8s %9s %8s %7s %s" % ["config", "median", "p5", "p95", "avg fps", "vs base", "cpu", "tris", "draws"])
	for r in _results:
		lines.append("%-32s %7.2fms %7.2fms %7.2fms %8.1f %+8.2fms %6.2fms %6.0fk %5.0f  %s" % [
			r["name"], r["median_ms"], r["p5_ms"], r["p95_ms"], r["avg_fps"], float(r["median_ms"]) - base,
			r["cpu_ms"], r["prims_k"], r["draws"], r["render"]])
	var again: Dictionary = _results[-1]
	for r in _results:
		if str(r["name"]).begins_with("baseline (again"):
			again = r
	var drift: float = float(again["median_ms"]) - base
	lines.append("thermal drift (last baseline - first): %+.2f ms%s" % [drift,
		"  <- the machine slowed during the run; treat small deltas as noise" if absf(drift) > 0.5 else ""])
	var txt := "\n".join(lines)
	print(txt)
	var path := "user://bench-%s.txt" % Time.get_datetime_string_from_system().replace(":", "-")
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa != null:
		fa.store_string(txt + "\n")
		fa.close()
		print("BENCH written to ", ProjectSettings.globalize_path(path))
	if not OS.get_cmdline_user_args().has("--bench-stay"):
		get_tree().quit()

# ---------------------------------------------------------------- helpers

func _place(s: float) -> void:
	var cl = area.gen.centreline
	var p: Dictionary = cl.point_at(clampf(s, 0.0, cl.length()))
	var pos: Vector3 = p["pos"]
	var h: Vector2 = p["heading"]
	var o := Vector3(pos.x, float(area.height_at(pos.x, pos.z)) + 0.9, pos.z)
	var fwd := Vector3(h.x, 0.0, h.y).normalized()
	car.global_transform = Transform3D(Basis(), o).looking_at(o + fwd, Vector3.UP)
	car.linear_velocity = fwd * SPEED
	car.angular_velocity = Vector3.ZERO

func _render_size() -> Vector2i:
	var vp := get_tree().root
	return Vector2i(int(round(vp.size.x * vp.scaling_3d_scale)), int(round(vp.size.y * vp.scaling_3d_scale)))

func _set_lines(lines: int) -> void:
	var vp := get_tree().root
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0 if lines <= 0 else clampf(float(lines) / float(vp.size.y), 0.25, 1.0)

func _on_node_added(n: Node) -> void:
	if _forest_mode != "" and n is GeometryInstance3D and str(n.name).begins_with("Trees"):
		_apply_forest_to(n as GeometryInstance3D)

func _apply_forest_to(g: GeometryInstance3D) -> void:
	# Only the "TreesShadow" silhouettes cast shadows (see StageForest.attach), so hiding them is
	# exactly "trees cast no shadow" with the visible trees untouched.
	if _forest_mode == "hidden":
		g.visible = false
	elif _forest_mode == "noshadow":
		g.visible = str(g.name) != "TreesShadow"
	else:
		g.visible = true

func _set_forest(mode: String) -> void:
	_forest_mode = mode
	for g in _trees():
		_apply_forest_to(g)

func _trees() -> Array:
	var out: Array = []
	var stack: Array = [area]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D and str(n.name).begins_with("Trees"):
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out

var _sway_saved: Variant = null
var _sway_off := false
func _set_sway(v: float) -> void:
	# One ShaderMaterial is shared by every tree (StageForest._mat), so one uniform switches it off.
	var f = area.chunks.forest
	if f == null or f._mat == null:
		return
	if v >= 0.0:
		_sway_saved = f._mat.get_shader_parameter("sway")     # null = the shader's own default
		_sway_off = true
		f._mat.set_shader_parameter("sway", v)
	elif _sway_off:
		f._mat.set_shader_parameter("sway", _sway_saved)
		_sway_off = false

func _swap_sky(flat: bool) -> void:
	var sky: Sky = world._env.sky
	if flat:
		if _flat_sky == null:
			_flat_sky = ProceduralSkyMaterial.new()
		_sky_saved = sky.sky_material
		sky.sky_material = _flat_sky
	elif _sky_saved != null:
		sky.sky_material = _sky_saved
