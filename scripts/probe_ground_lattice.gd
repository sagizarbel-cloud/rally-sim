extends Node
## D1 probes 1 + 2 — the GOLDEN GROUND LATTICE.
##
## This is the one probe Arc D does NOT throw away. D1's whole success condition is that the
## ground classification does not move, and D5 reuses this same lattice to prove the calibration
## bed rebuilds bit-identically after an area transition
## (docs/PLAN-stages-ground-map.md §5 Phase D1 probe 1, §5 Phase D5).
##
## It is deliberately NOT wired into world.gd. To run it, add this to the END of world.gd
## `_ready()` and delete the block again afterwards:
##
##     if OS.get_environment("RS_LATTICE_OUT") != "":
##         var p: Node = load("res://scripts/probe_ground_lattice.gd").new()
##         p.stage = stage
##         p.fx = get_node_or_null("SurfaceEffects")
##         add_child(p)
##
## Then: RS_LATTICE_OUT=/abs/path.txt godot --headless --path . --quit-after 600
##
## The lattice is a pure function of the stage's exported geometry and contains no RNG, so two
## runs of the same build must produce a byte-identical file. Compare with `shasum -a 256`.
##
## Probe 1 (golden equality) is the `grip` column. Probe 2 (consumer agreement) is the three
## columns after it: each independent surface decision in the project, recorded side by side so a
## disagreement is visible rather than theoretical.

var stage                       # RallyStage
var fx                          # scripts/effects.gd, for its own tarmac threshold (may be null)

# Sample counts chosen to span all four surfaces and BOTH circuit shoulders finely, since the
# shoulders are where a classification refactor would actually break. Fixed, not tuned.
const GRID_N := 61              # uniform grid over the terrain square
const GRID_HALF := 360.0
const CIRCUIT_ANGLES := 24      # radial sweeps across each circuit edge
const EDGE_REACH := 14.0        # metres either side of a centreline
const EDGE_STEP := 1.0
const PATCH_ANGLES := 12
const PATCH_REACH := 100.0      # past patch_radius 75 + center_blend 18
const PATCH_STEP := 1.0

func _ready() -> void:
	var out := OS.get_environment("RS_LATTICE_OUT")
	if out == "":
		return
	var pts := _lattice()
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		push_error("PROBE: cannot open %s" % out)
		get_tree().quit()
		return

	# Column header names the SOURCE of each decision, so a future session reading the golden file
	# knows which call site each column is holding to account.
	f.store_line("# D1 golden ground lattice - one line per sample, deterministic order.")
	f.store_line("# grip=stage.grip_at | tarmac=stage.is_tarmac_at | fxasph=effects.gd grip>asphalt_grip")
	f.store_line("# sndasph=sound.gd (g-1.0)/0.25 | patchf=stage.deformable_patch_factor | colour=stage._surface_color")
	f.store_line("# x z grip tarmac fxasph sndasph patchf r g b")

	var fx_thresh := 1.2                                  # effects.gd asphalt_grip default
	if fx != null and fx.get("asphalt_grip") != null:
		fx_thresh = float(fx.asphalt_grip)

	# Agreement tally (probe 2). Counted, not assumed - a disagreement must be reported with a
	# number and a worked example, per §5's "record it, don't silently fix it".
	var n_disagree_fx := 0
	var n_disagree_snd := 0
	var n_disagree_patch := 0
	var ex_fx := ""
	var ex_snd := ""
	var ex_patch := ""
	var counts := {}                                      # grip value -> how many samples

	for p in pts:
		var x: float = p.x
		var z: float = p.y
		var grip: float = stage.grip_at(x, z)
		var tarmac: bool = stage.is_tarmac_at(x, z)
		var fxasph: bool = grip > fx_thresh
		var sndasph: float = clampf((grip - 1.0) / 0.25, 0.0, 1.0)
		var patchf: float = stage.deformable_patch_factor(x, z)
		var col: Color = stage._surface_color(x, z)

		f.store_line("%.17g %.17g %.17g %d %d %.17g %.17g %.17g %.17g %.17g"
				% [x, z, grip, int(tarmac), int(fxasph), sndasph, patchf, col.r, col.g, col.b])

		counts[grip] = int(counts.get(grip, 0)) + 1

		# Consumer agreement: does every independent surface decision classify this point the same?
		# tarmac (the road_class seam) is the reference, because it is the only one written as an
		# explicit surface test rather than a grip threshold.
		if fxasph != tarmac:
			n_disagree_fx += 1
			if ex_fx == "":
				ex_fx = "(%.1f, %.1f) grip=%.4f tarmac=%s fx=%s" % [x, z, grip, tarmac, fxasph]
		# sound's split is CONTINUOUS by design, so only its endpoints can be compared: a
		# non-tarmac point reading anything above 0 means the tyre audio hears asphalt off-tarmac.
		if not tarmac and sndasph > 0.0:
			n_disagree_snd += 1
			if ex_snd == "":
				ex_snd = "(%.1f, %.1f) grip=%.4f sndasph=%.3f" % [x, z, grip, sndasph]
		# The centre patch is classified by grip_at with a EUCLIDEAN radius test and by
		# deformable_patch_factor with a CHEBYSHEV one. Where they disagree, the ground is
		# "deformable" to the roughness field but not "patch" to grip, or vice versa.
		var grip_says_patch := grip == float(stage.dirt_grip) and _euclid_patch(x, z)
		var factor_says_patch := patchf < 1.0
		if grip_says_patch != factor_says_patch:
			n_disagree_patch += 1
			if ex_patch == "":
				ex_patch = "(%.1f, %.1f) grip=%.4f patchf=%.3f" % [x, z, grip, patchf]

	f.close()

	print("PROBE lattice: %d points -> %s" % [pts.size(), out])
	var keys := counts.keys()
	keys.sort()
	for k in keys:
		print("PROBE   grip %.4f : %d samples" % [float(k), int(counts[k])])
	print("PROBE agreement: effects-vs-tarmac %d disagree %s" % [n_disagree_fx, ex_fx])
	print("PROBE agreement: sound-vs-tarmac   %d disagree %s" % [n_disagree_snd, ex_snd])
	print("PROBE agreement: patch euclid-vs-cheb %d disagree %s" % [n_disagree_patch, ex_patch])
	print("PROBE DONE")
	get_tree().quit()

func _euclid_patch(x: float, z: float) -> bool:
	# grip_at's own patch test, restated so the probe can tell PATCH from rally-loop DIRT (both
	# return dirt_grip, so the grip value alone cannot distinguish them).
	var dx: float = x - stage.road_center.x
	var dz: float = z - stage.road_center.z
	return sqrt(dx * dx + dz * dz) < float(stage.patch_radius)

func _lattice() -> PackedVector2Array:
	var pts := PackedVector2Array()

	# A - uniform grid over the terrain square: grass, both circuits, the patch, in bulk.
	var step := (GRID_HALF * 2.0) / float(GRID_N - 1)
	for i in range(GRID_N):
		for j in range(GRID_N):
			pts.append(Vector2(-GRID_HALF + float(i) * step, -GRID_HALF + float(j) * step))

	# B - radial sweeps across BOTH circuit shoulders, where classification boundaries live.
	for k in range(CIRCUIT_ANGLES):
		var th := TAU * float(k) / float(CIRCUIT_ANGLES)
		var ct := cos(th)
		var st := sin(th)
		for which in range(2):
			var r0: float = stage._road(th) if which == 0 else stage._asphalt_r(th)
			var d := -EDGE_REACH
			while d <= EDGE_REACH + 1e-9:
				var r := r0 + d
				pts.append(Vector2(stage.road_center.x + r * ct, stage.road_center.z + r * st))
				d += EDGE_STEP

	# C - the drag strip: down its length, and across it where it is clear of the ring.
	var x := 280.0
	while x <= stage.strip_x1 + 5.0:
		pts.append(Vector2(x, 0.0))
		x += 20.0
	for xs in [1000.0, 2000.0]:
		var z := -20.0
		while z <= 20.0 + 1e-9:
			pts.append(Vector2(xs, z))
			z += 1.0

	# D - the centre deformable patch, out past its blend, on both distance metrics.
	for k in range(PATCH_ANGLES):
		var th2 := TAU * float(k) / float(PATCH_ANGLES)
		var r2 := 0.0
		while r2 <= PATCH_REACH + 1e-9:
			pts.append(Vector2(stage.road_center.x + r2 * cos(th2), stage.road_center.z + r2 * sin(th2)))
			r2 += PATCH_STEP

	return pts
