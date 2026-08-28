extends RefCounted
class_name GroundMap
## D1 — ONE AUTHORITY for what the ground IS at any world position
## (docs/PLAN-stages-ground-map.md §5 Phase D1).
##
## Before this existed, "what surface is this?" was decided independently in four places:
## stage.grip_at (polar distance tests), stage.is_tarmac_at (C1's road_class seam),
## effects.gd's tarmac gate (a grip threshold), and sound.gd's tyre-audio split (another grip
## threshold). Four sources that can disagree - and two of them DO, measured; see the D1 entry in
## CHANGELOG.md. Today that is mostly theoretical; the moment D6 drags gravel onto tarmac it stops
## being theoretical, because the tyre would grip one surface while the audio and particles played
## another.
##
## THE COMPOSITION IS THE POINT. The map is a stack of LAYERS, each a pure function of position,
## resolved in priority order: the first layer that claims a position owns it. That is what later
## lets a second area exist without touching the first (D5) and lets a surface transition be one
## new layer rather than four edited call sites (D6).
##
## D1 CHANGES NO BEHAVIOUR. Every value here is the legacy value, and the layer order below is
## grip_at's own historical test order, preserved deliberately - see _classify().

## The four surfaces. PATCH is the centre reactive-dirt skid-pad: it grips as dirt but terrain.gd
## owns real geometry there, which is why it is a surface in its own right rather than DIRT.
enum Surface { GRASS, DIRT, ASPHALT, PATCH }

const SURFACE_NAMES: Array[StringName] = [&"grass", &"dirt", &"asphalt", &"dirt"]

var stage                        # RallyStage - owns the geometry every layer is a function of

# D3: EXTRA AREAS, queried before the legacy map's own layers. This is the composition D1 was built
# for paying off - a second area exists by ADDING a layer, and not one line of stage.gd, sound.gd,
# effects.gd, roughness.gd or wear.gd changed to make the generated stage grip, sound and throw dust
# correctly. Each entry needs in_area(x, z) (a cheap box test, checked first so driving on the
# legacy map costs almost nothing) and on_road(x, z).
var areas: Array = []
var road_class_source            # scripts/roughness.gd - owns the ISO 8608 coefficients (see below)

# ISO 8608 fallbacks, used only if no road_class_source is wired. The LIVE values belong to the
# Roughness node: they are its exports, mirrored onto the car and re-synced every tick so the Tab
# sliders stay live (C1's follow-up). Duplicating them here as exports would recreate exactly the
# multiple-sources-of-truth problem this file exists to remove, so the map READS them instead.
const ROAD_CLASS_GRAVEL_FALLBACK := 128.0    # ISO 8608 Gd(n0) in 1e-6 m^3 units, as roughness.gd stores it
const ROAD_CLASS_TARMAC_FALLBACK := 4.0

func _init(stage_ref) -> void:
	stage = stage_ref

# ---------------------------------------------------------------- the layer stack

func _classify(x: float, z: float) -> int:
	# LAYER ORDER IS LOAD-BEARING AND IS grip_at's ORIGINAL ORDER, kept to the letter so D1 is a
	# refactor and not a feel change. §5 describes the stack conceptually as "base terrain, then
	# road corridors, then overrides"; the historical order tests the asphalt ring BEFORE the
	# centre patch, so that is what runs here. It is equivalent today (the ring at r~300 and the
	# patch at r<75 do not overlap, and where the ring and the drag strip DO overlap near x~285
	# they both resolve to ASPHALT), but the two orders stop being equivalent the moment D6 adds
	# an override that crosses a corridor - so this reads as an ordered list, and D6 changes the
	# ORDER here rather than editing any consumer.

	# 0. Generated areas (D3). Highest priority because they are somewhere else entirely - the box
	# test rejects every query on the legacy map before any centreline work happens.
	for a in areas:
		if not a.in_area(x, z):
			continue
		return Surface.DIRT if a.on_road(x, z) else Surface.GRASS

	# 1. Asphalt ring corridor.
	var ad: float = stage._asphalt_dist(x, z)
	if ad < float(stage.asphalt_width) * 0.5 + 1.0:
		return Surface.ASPHALT

	# 2. Drag strip + its runoff pad (an override on top of the base terrain).
	if bool(stage._on_drag_strip(x, z)):
		return Surface.ASPHALT

	# 3. Centre reactive-dirt patch. NOTE the EUCLIDEAN radius test: this is grip_at's own test,
	# and it is deliberately NOT the chebyshev one deformable_patch_factor uses. They disagree on
	# 392 of D1's 6608 lattice points - a pre-existing inconsistency, recorded in CHANGELOG.md and
	# left alone, because reconciling them would move both grip and roughness inside a refactor.
	var dx: float = x - stage.road_center.x
	var dz: float = z - stage.road_center.z
	if sqrt(dx * dx + dz * dz) < float(stage.patch_radius):
		return Surface.PATCH

	# 4. Rally loop corridor.
	if stage._road_t(x, z) > 0.4:
		return Surface.DIRT

	# 5. Base terrain.
	return Surface.GRASS

# ---------------------------------------------------------------- the sample

func sample(x: float, z: float) -> Dictionary:
	## The full authority: everything the ground is at one position. Consumers that need several
	## fields at once should call this; the hot single-field paths below skip the allocation.
	var s := _classify(x, z)
	return {
		"surface": s,
		"road_class": _road_class_for(s),
		"deformable": patch_factor(x, z) < 1.0,
		"grip": _grip_for(s),
		"colour": colour_at(x, z),
		"audio": SURFACE_NAMES[s],
	}

# Single-field accessors. These exist because sample() is called per wheel per physics tick (4 x
# 120 Hz) and by several consumers on top of that, and building a Dictionary for a caller that
# wanted one float is measurable at that rate - see probe 3 in the D1 CHANGELOG entry. They are
# the SAME classifier, so they cannot drift from sample().

func grip_at(x: float, z: float) -> float:
	return _grip_for(_classify(x, z))

func surface_at(x: float, z: float) -> int:
	return _classify(x, z)

func is_tarmac_at(x: float, z: float) -> bool:
	return _classify(x, z) == Surface.ASPHALT

func road_class_at(x: float, z: float) -> float:
	return _road_class_for(_classify(x, z))

func audio_at(x: float, z: float) -> StringName:
	return SURFACE_NAMES[_classify(x, z)]

# ---------------------------------------------------------------- per-surface properties

func _grip_for(s: int) -> float:
	# PATCH grips as dirt: the centre skid-pad has always returned dirt_grip, and terrain.gd's
	# ruts are what make it feel different, not a separate coefficient.
	match s:
		Surface.ASPHALT:
			return float(stage.asphalt_grip)
		Surface.DIRT, Surface.PATCH:
			return float(stage.dirt_grip)
		_:
			return float(stage.grass_grip)

func _road_class_for(s: int) -> float:
	var tarmac := s == Surface.ASPHALT
	if road_class_source != null:
		return float(road_class_source.road_class_tarmac if tarmac else road_class_source.road_class_gravel)
	return ROAD_CLASS_TARMAC_FALLBACK if tarmac else ROAD_CLASS_GRAVEL_FALLBACK

# ---------------------------------------------------------------- continuous fields
# Not every property of the ground is a class. These two are blends, and both are read by
# consumers that need the gradient rather than the classification, so they stay continuous.

func patch_factor(x: float, z: float) -> float:
	# 0 inside the centre reactive-dirt patch (terrain.gd owns real geometry there - a procedural
	# roughness field would double-count it), ramping to 1 over the same grass blend the patch
	# already uses. CHEBYSHEV distance, because the DeformableTerrain zone is a SQUARE tile grid
	# and this factor exists to match its extent. This is the body of what C1 wrote as
	# stage.deformable_patch_factor, moved here per §6.3, with the call site untouched.
	var dx: float = x - stage.road_center.x
	var dz: float = z - stage.road_center.z
	var cheb := maxf(absf(dx), absf(dz))
	return smoothstep(float(stage.patch_radius), float(stage.patch_radius) + float(stage.center_blend), cheb)

func colour_at(x: float, z: float) -> Color:
	# What the ground LOOKS like - the terrain mesh's vertex colour, and the colour effects.gd
	# lifts its dust from. A blend, not a class: the whole point is that the patch edge and the
	# road shoulder fade rather than step. Moved verbatim from stage._surface_color.
	var c: Color = Color(stage.grass_color).lerp(Color(stage.road_color), stage._road_t(x, z))
	c = c.lerp(Color(stage.patch_color), 1.0 - patch_factor(x, z))
	var ad: float = stage._asphalt_dist(x, z)
	var w := float(stage.asphalt_width) * 0.5
	var ta := 1.0 - smoothstep(w, w + 1.5, ad)                # crisp asphalt edge
	c = c.lerp(Color(stage.asphalt_color), ta)
	if x >= float(stage.strip_x0) and x <= float(stage.strip_x1):
		var hw := float(stage.strip_hw)
		var ts := 1.0 - smoothstep(hw, hw + 3.5, absf(z))
		c = c.lerp(Color(stage.asphalt_color), ts)
	return c
