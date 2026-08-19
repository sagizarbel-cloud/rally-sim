extends Node
## TEMPORARY probe: A/B the render cost of the centre patch with a fully-rutted track corridor.
## Carves the dirt-circle corridor exactly as a few laps would, unloads every tile, parks the car
## on the patch and reports the same monitors the [J] readout shows.

const LAPS_PTS := 700

func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var patch: Node = get_tree().root.find_child("ReactivePatch", true, false)
	var car: Node3D = get_tree().root.find_child("Vehicle", true, false)
	if patch == null:
		print("PERF: no ReactivePatch"); get_tree().quit(); return

	var bed: float = patch.bed_height
	var tn: int = patch.get("_tn")
	var cs: float = patch.get("_cs")

	# knobs so one build can be A/B'd:  -- vis=N  (mesh cells on a dug square)   shadow=off
	var vis := -1
	var shadow := true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("vis="):
			vis = int(arg.substr(4))
		elif arg == "shadow=off":
			shadow = false
	var dq: PlaneMesh = patch.get("_flat_quad_dug")
	if dq != null and vis >= 1:
		dq.subdivide_width = vis - 1
		dq.subdivide_depth = vis - 1
	if not shadow:
		for mi2 in patch.get("_flat_vis").values():
			mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	print("PERF config: vis=%s shadow=%s" % [vis if vis >= 1 else "default", shadow])

	# --- carve the corridor: two wheel tracks round the wobbly ring, as driving does ---
	for k in range(LAPS_PTS):
		var a := TAU * float(k) / float(LAPS_PTS)
		var rr := 40.0 + 10.0 * sin(3.0 * a)
		for lat: float in [-0.8, 0.8]:
			var wx: float = cos(a) * (rr + lat)
			var wz: float = sin(a) * (rr + lat)
			var ti = patch._tile_index(wx, wz)
			patch._ensure_tile(ti.x, ti.y)
			var t = patch._tiles.get(Vector2i(ti.x, ti.y))
			if t == null:
				continue
			for dj in range(-3, 4):
				for di in range(-3, 4):
					var nr := sqrt(float(di * di + dj * dj)) / 2.0
					if nr > 1.8:
						continue
					var px: float = wx + float(di) * cs
					var pz: float = wz + float(dj) * cs
					var tt = patch._tile_at(px, pz)
					if tt == null:
						continue
					var lii := int(round((px - (tt.center.x - patch.get("_half_t"))) / cs))
					var ljj := int(round((pz - (tt.center.z - patch.get("_half_t"))) / cs))
					if lii < 0 or ljj < 0 or lii >= tn or ljj >= tn:
						continue
					var h := bed
					if nr <= 1.0:
						h = bed - 0.105 * (1.0 - smoothstep(0.0, 1.0, nr))
					else:
						h = bed + 0.006 * ((1.8 - nr) / 0.8)
					patch._set_h(tt, ljj * tn + lii, lii, ljj, h)
	var dug := 0
	for t in patch._tiles.values():
		if t.dug:
			dug += 1
	print("PERF carved: %d tiles live, %d marked dug" % [patch._tiles.size(), dug])

	# --- unload them all (persists ruts + swaps in whatever unloaded visual the build uses) ---
	patch._unload_far(Vector3(9000, 0, 9000))
	print("PERF after unload: live tiles=%d  saved=%d" % [patch._tiles.size(), patch.get("_saved").size()])

	# --- static cost of the unloaded field ---
	var quads: Dictionary = patch.get("_flat_vis")
	var mats := {}
	var tris := 0
	for mi in quads.values():
		if not mi.visible:
			continue
		mats[mi.material_override.get_instance_id()] = true
		var pm: PlaneMesh = mi.mesh
		tris += (pm.subdivide_width + 1) * (pm.subdivide_depth + 1) * 2
	print("PERF unloaded field: %d visible quads, %d distinct materials, %d triangles" % [quads.size(), mats.size(), tris])

	# --- park the car on the patch and let it render ---
	if car != null:
		car.global_position = Vector3(52.0, 1.4, 0.0)
		car.linear_velocity = Vector3.ZERO
		car.angular_velocity = Vector3.ZERO
		car.freeze = true                               # pin it: the live-tile set must be identical run to run
	await get_tree().process_frame
	await get_tree().process_frame
	var fps := 0.0; var proc := 0.0; var phys := 0.0; var dc := 0.0; var prim := 0.0; var n := 0
	for f in range(300):
		await get_tree().process_frame
		if f < 120:
			continue                                    # warm-up
		fps += Performance.get_monitor(Performance.TIME_FPS)
		proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		dc += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		prim += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		n += 1
	print("PERF [J] avg over %d frames -> FPS %.1f   process %.3f ms   physics %.3f ms   draw calls %.0f   primitives %.0f" % [
		n, fps / n, proc / n, phys / n, dc / n, prim / n])
	print("PERF live tiles at rest: %d" % patch._tiles.size())
	get_tree().quit()
