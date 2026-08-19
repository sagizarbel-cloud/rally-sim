extends Node
## TEMPORARY probe: does an unloaded dug tile now render its own ruts, and is undug ground untouched?

func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var patch: Node = get_tree().root.find_child("ReactivePatch", true, false)
	var bed: float = patch.bed_height
	var hs: float = patch.height_scale
	var maxsink: float = patch.max_sinkage
	var tn: int = patch.get("_tn")
	var flat_vis: Dictionary = patch.get("_flat_vis")
	var flat_mat: ShaderMaterial = patch.get("_flat_mat")
	var dirt: Color = patch.dirt_color
	var rut: Color = patch.rut_color
	var berm: Color = patch.berm_color

	print("PROBE step=%d  visual nodes/side=%d (tile has %d)  dug quad subdiv=%d -> %d tris" % [
		patch.get("_fstep"), patch.get("_fvn"), tn,
		patch.get("_flat_quad_dug").subdivide_width,
		(patch.get("_flat_quad_dug").subdivide_width + 1) * (patch.get("_flat_quad_dug").subdivide_depth + 1) * 2])

	# --- dig a rut AND a berm into one tile, exactly where a wheel would ---
	var key := Vector2i(6, 6)
	patch._ensure_tile(key.x, key.y)
	var t = patch._tiles[key]
	var rut_h := bed - 0.105
	var berm_h := bed + 0.006
	for j in range(28, 34):
		for i in range(tn):
			patch._set_h(t, j * tn + i, i, j, rut_h)
	for j in [26, 27, 34, 35]:
		for i in range(tn):
			patch._set_h(t, j * tn + i, i, j, berm_h)
	# read what the LOADED tile actually draws (the quantised texture, not the ideal height)
	var lh_rut: float = t.img.get_pixel(10, 30).r * hs
	var lh_berm: float = t.img.get_pixel(10, 26).r * hs
	print("PROBE loaded tile draws: rut %.4f m -> %s   berm %.4f m -> %s" % [
		lh_rut, _alb(dirt, rut, berm, _depth(bed, lh_rut, maxsink), _rise(bed, lh_rut, patch.rise_vis)),
		lh_berm, _alb(dirt, rut, berm, _depth(bed, lh_berm, maxsink), _rise(bed, lh_berm, patch.rise_vis))])

	# --- unload it, then read what the UNLOADED square will actually draw ---
	patch._unload_far(Vector3(9000, 0, 9000))   # _persist flushes the dirty texture before handing it over
	var mi: MeshInstance3D = flat_vis[key]
	var m: ShaderMaterial = mi.material_override
	print("PROBE after unload: own material=%s  tessellated mesh=%s  visible=%s" % [
		m != flat_mat, mi.mesh == patch.get("_flat_quad_dug"), mi.visible])
	var tex: Texture2D = m.get_shader_parameter("height_tex")
	var r = patch.get("_saved")[key]
	# NB read the CPU-side Image: ImageTexture.get_image() does not round-trip under --headless
	# (dummy renderer), while the shader samples the GPU copy that tex.update(img) uploaded.
	var im: Image = r.img
	print("PROBE handover: material's texture IS the tile's own texture=%s" % [tex == r.tex])
	var rt := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	var probe_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	probe_img.fill(Color(0.7, 0, 0, 1))
	rt.update(probe_img)
	print("PROBE (headless texture round-trip check: update() reads back %.3f, expected 0.700)" % [rt.get_image().get_pixel(0, 0).r])
	var h_rut: float = im.get_pixel(10, 30).r * hs
	var h_berm: float = im.get_pixel(10, 26).r * hs
	var h_undug: float = im.get_pixel(10, 5).r * hs
	print("PROBE unloaded square reads: rut %.4f m  berm %.4f m  untouched %.4f m (bed %.4f)" % [
		h_rut, h_berm, h_undug, bed])
	print("PROBE unloaded albedo: rut %s   berm %s" % [
		_alb(dirt, rut, berm, _depth(bed, h_rut, maxsink), _rise(bed, h_rut, patch.rise_vis)),
		_alb(dirt, rut, berm, _depth(bed, h_berm, maxsink), _rise(bed, h_berm, patch.rise_vis))])
	print("PROBE material texel=%.5f cellw=%.4f (live tile: %.5f / %.4f)" % [
		m.get_shader_parameter("texel"), m.get_shader_parameter("cellw"),
		1.0 / float(tn), patch.get("_cs")])

	# --- undug ground must be untouched: still the ONE shared pristine material + 2-triangle quad ---
	var shared := 0
	var own := 0
	var tris := 0
	for k in flat_vis:
		var q: MeshInstance3D = flat_vis[k]
		if q.material_override == flat_mat:
			shared += 1
		else:
			own += 1
		var pm: PlaneMesh = q.mesh
		tris += (pm.subdivide_width + 1) * (pm.subdivide_depth + 1) * 2
	print("PROBE field: %d squares on the shared pristine material, %d with their own, %d triangles total" % [
		shared, own, tris])

	# --- physics must be untouched: reload and compare heights + collider ---
	patch._ensure_tile(key.x, key.y)
	var t2 = patch._tiles[key]
	var same := true
	for n in range(tn * tn):
		if absf(t2.heights[n] - t.heights[n]) > 1e-6:
			same = false
			break
	print("PROBE reload: heights identical=%s  collider map_data matches=%s  dug flag=%s" % [
		same, t2.shape.map_data == t2.heights, t2.dug])
	print("PROBE reload shares the persisted texture=%s (no re-upload)" % [t2.tex == tex])
	get_tree().quit()

func _depth(bed: float, h: float, maxsink: float) -> float:
	return clampf((bed - h - 0.015) / maxsink, 0.0, 1.0)

func _rise(bed: float, h: float, risescale: float) -> float:
	return clampf((h - bed - 0.0015) / maxf(risescale, 0.001), 0.0, 1.0)

func _alb(dirt: Color, rut: Color, bright: Color, depth: float, rise: float) -> String:
	var c := dirt.lerp(rut, depth).lerp(bright, rise * 0.9)
	return "(%.3f,%.3f,%.3f) luma %.3f" % [c.r, c.g, c.b, 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b]
