extends Node
## C1.1-C1.4 - surface roughness the wheels actually feel (docs/PLAN-drivetrain-suspension.md,
## Phase C1). A procedural roughness FIELD sampled per wheel at the contact point, not baked
## geometry: costs no mesh/collider resolution, reaches wavelengths far below any practical grid,
## and is keyed to world position so it is repeatable (a bump is the same bump every lap).
##
## Two physical terms:
## - Broadband: an ISO 8608 displacement PSD Gd(n) = Gd(n0)*(n/n0)^-w realised as octave-spaced
##   noise layers, one coefficient per surface (road_class_gravel / road_class_tarmac).
## - Washboard: a coherent transverse ripple train on gravel corners/braking zones,
##   washboard_amp * sin(2*PI*s/washboard_lambda), s = distance along the ROAD CENTRELINE
##   (Centreline, C1.0) - not theta, so Arc D's D2 can redefine s without moving these ridges,
##   see docs/PLAN-stages-ground-map.md §6.2.
## Tarmac gets its own discrete detail instead: expansion joints + occasional patch repairs.
##
## C1.2: a tyre bridges anything shorter than its contact patch, so the raw field is filtered by
## sampling contact_patch_len along the wheel's heading and combining with a peak-biased weighted
## mean before it reaches the suspension - this is the difference between texture and buzz.

var stage                 # RallyStage - surface tests + _height()
var wear                  # Wear node - shares its corner/braking-zone mask as the washboard mask
var centreline_gravel: Centreline   # rally loop, C1.0 - the `s` axis for washboard phase

@export var road_class_gravel := 128.0   # ISO 8608 Gd(n0), 1e-6 m^3 units (~class D, "poor")
@export var road_class_tarmac := 4.0     # ISO 8608 Gd(n0), 1e-6 m^3 units (~class A/B, "good")
@export var washboard_amp := 0.02        # m, washboard ridge depth (published range up to ~0.05 m)
@export var washboard_lambda := 0.6      # m, washboard wavelength (published range 0.3-1.0 m)
@export var joint_spacing := 6.0         # m, tarmac expansion-joint interval
@export var joint_amp := 0.006           # m, expansion-joint bump height
@export var patch_amp := 0.012           # m, occasional tarmac patch-repair height
@export var patch_rate := 0.12           # fraction of tarmac area that reads as a patched repair
@export var contact_patch_len := 0.20    # m, tyre contact patch length -> enveloping footprint
@export var patch_samples := 9           # samples spanning the contact patch (perf/quality, not feel)

const N0 := 0.1            # cycles/m, ISO 8608 reference spatial frequency
const WAVINESS := 2.0       # ISO 8608 w exponent
const N_OCTAVES := 5         # bands [n0,2n0]..[16n0,32n0] = 0.1-3.2 cycles/m, 10 m down to 0.31 m
# C1.2: the enveloping weight floor. A plain mean over the patch already does most of the real
# work here - it is a low-pass filter, so a feature much narrower than the patch (fine gravel
# grain) is heavily diluted by the many samples that miss it, while a feature spanning most of the
# patch (washboard) keeps nearly all its samples near the peak and survives almost intact. The
# floor only adds the "rides OVER a crest, does not sink into every trough" bias on top: raising a
# sample's weight toward 1.0 as its value approaches the patch's own peak, never below this floor.
const ENVELOPE_FLOOR := 0.5

var _oct_noise: Array = []
var _oct_norm: PackedFloat32Array   # measured RMS of each octave, so the ISO amplitudes land true
var _patch_noise: FastNoiseLite

func _ready() -> void:
	_build_noise()

func _build_noise() -> void:
	_oct_noise.clear()
	for i in range(N_OCTAVES):
		var n := FastNoiseLite.new()
		n.seed = 4100 + i * 733
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = N0 * pow(2.0, i)          # cycles/m for this octave
		_oct_noise.append(n)
	# FastNoiseLite does NOT emit unit-variance noise (simplex RMS is nearer 0.3 than 1.0), but the
	# ISO amplitude maths below assumes it does - so the whole broadband spectrum came out several
	# times quieter than the road class it claimed. Measure each layer's real RMS once and divide it
	# out, so road_class_* delivers the variance ISO 8608 actually specifies instead of an arbitrary
	# fraction of it. Measured, not hand-corrected: swap the noise type and this re-derives itself.
	_oct_norm.resize(N_OCTAVES)
	for i in range(N_OCTAVES):
		_oct_norm[i] = _measure_rms(_oct_noise[i])
	_patch_noise = FastNoiseLite.new()
	_patch_noise.seed = 9001
	_patch_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_patch_noise.frequency = 0.03                # broad patches, tens of metres across

# ---------------------------------------------------------------- ISO 8608 broadband

func _measure_rms(n: FastNoiseLite) -> float:
	var period := 1.0 / maxf(n.frequency, 1e-6)
	var acc := 0.0
	var m := 512
	for i in range(m):
		# irrational strides so the samples never land on the noise lattice and under-read
		var t := float(i) * period * 0.7548776662
		var v := n.get_noise_2d(t, t * 0.6180339887)
		acc += v * v
	return maxf(sqrt(acc / float(m)), 1e-4)

func _octave_rms(gd_n0_1e6: float, n: float) -> float:
	# EXACT rms of the octave band [n, 2n] under Gd(x) = Gd(n0)*(x/n0)^-w:
	#   variance = Gd(n0) * n0^w * n^(1-w) * (2^(1-w) - 1) / (1 - w)
	# The obvious rectangle rule (Gd(n) * n) samples the PSD at the band's LOW edge, and on a
	# spectrum falling as n^-2 that overstates every octave by exactly 2x in variance - sqrt(2) in
	# amplitude. ISO 8608 fixes w = 2, so the 1-w denominator is safe.
	var gd0 := gd_n0_1e6 * 1e-6
	return sqrt(gd0 * pow(N0, WAVINESS) * pow(n, 1.0 - WAVINESS)
		* (pow(2.0, 1.0 - WAVINESS) - 1.0) / (1.0 - WAVINESS))

func _broadband(x: float, z: float, gd_n0_1e6: float) -> float:
	var h := 0.0
	for i in range(N_OCTAVES):
		var n := N0 * pow(2.0, i)
		# normalise the layer to unit RMS, then scale by the band's exact rms: independent octaves
		# add in quadrature, so the total lands on the ISO variance for the whole spectrum
		h += _oct_noise[i].get_noise_2d(x, z) * _octave_rms(gd_n0_1e6, n) / _oct_norm[i]
	return h

# ---------------------------------------------------------------- road class + per-surface detail

func road_class_at(x: float, z: float) -> float:
	# D1: body replaced with the ground-map lookup C1 left this seam for (§6.1) - no call site
	# changed. The two coefficients above are still OURS: the map classifies the position and reads
	# them back off this node (world.gd wires it as road_class_source), so the Tab sliders stay live
	# and there is still exactly one place each number lives.
	return stage.ground_map.road_class_at(x, z)

func _washboard(x: float, z: float) -> float:
	if centreline_gravel == null or wear == null or not wear.is_tracked(x, z):
		return 0.0
	var np := centreline_gravel.nearest_point(x, z)
	return washboard_amp * sin(TAU * np["s"] / maxf(washboard_lambda, 0.05))

func _tarmac_joints(x: float, z: float, s: float) -> float:
	var phase := fposmod(s, joint_spacing) / joint_spacing
	var d := minf(phase, 1.0 - phase)                        # wrap distance to the nearest joint
	var width := 0.06 / joint_spacing                        # a joint is a few cm of real gap
	var t := clampf(1.0 - d / maxf(width, 1e-4), 0.0, 1.0)
	var joint := joint_amp * t * t
	var pv := _patch_noise.get_noise_2d(x, z)                 # 0.5 = neutral; high = a patched repair
	var thresh := 1.0 - 2.0 * clampf(patch_rate, 0.0, 1.0)
	var patch := patch_amp * clampf((pv - thresh) / maxf(1.0 - thresh, 1e-3), 0.0, 1.0)
	return joint + patch

func _raw(x: float, z: float) -> float:
	var gd := road_class_at(x, z)
	var h := _broadband(x, z, gd)
	if gd == road_class_tarmac:
		# asphalt centreline `s`: no washboard on tarmac, so a straight arc-length estimate off the
		# ring's own radius is plenty accurate for a discrete-feature phase like the expansion joints
		h += _tarmac_joints(x, z, _tarmac_s(x, z))
	else:
		h += _washboard(x, z)
	return h * stage.deformable_patch_factor(x, z)

var _asphalt_s_scale := 1.0   # set by set_asphalt(), converts atan2 angle to metres of arc length

func set_asphalt(radius_hint: float) -> void:
	_asphalt_s_scale = radius_hint

func _tarmac_s(x: float, z: float) -> float:
	var center: Vector3 = stage.road_center
	var dx: float = x - center.x
	var dz: float = z - center.z
	return atan2(dz, dx) * _asphalt_s_scale

# ---------------------------------------------------------------- C1.2 enveloping filter

func _envelope_profile(vals: PackedFloat32Array) -> float:
	# weighted mean, biased toward the peak: a tyre rides OVER a crest, it does not sink into
	# every trough. The bias is scale-invariant (normalised by the patch's own spread) so it works
	# the same on a 2 mm gravel grain and a 5 cm washboard ridge without a magic absolute constant.
	# The attenuation itself comes from the MEAN over the patch (a low-pass filter: a feature much
	# narrower than the patch is diluted by every sample that misses it) - the floor only biases
	# that mean toward whichever samples are closest to the patch's own peak.
	var n := vals.size()
	if n == 0:
		return 0.0
	var maxv := vals[0]; var minv := vals[0]
	for i in range(1, n):
		maxv = maxf(maxv, vals[i]); minv = minf(minv, vals[i])
	var spread := maxf(maxv - minv, 1e-5)
	var num := 0.0; var den := 0.0
	for i in range(n):
		var w := ENVELOPE_FLOOR + (1.0 - ENVELOPE_FLOOR) * (vals[i] - minv) / spread
		num += vals[i] * w; den += w
	return num / maxf(den, 1e-6)

func sample_profile(x: float, z: float, heading: Vector2, swept: float) -> Vector2:
	## Returns (enveloped height, slope along the heading) from ONE set of field samples.
	##
	## `swept` is how far the wheel travels during this physics tick, and it EXTENDS the footprint:
	## the tyre does not touch a single 0.2 m patch during a tick, it sweeps a strip of
	## `contact_patch_len + speed*dt`. Averaging over that strip is both the physically honest
	## footprint AND the correct anti-aliasing filter, which matters because the field is sampled
	## once per tick and that interval is a DISTANCE that grows with speed: a 0.6 m washboard gets
	## 8.6 samples/wavelength at 30 km/h but only 2.59 at 100 and 1.73 at 150 — past Nyquist, where
	## a fixed-width footprint would alias the ripple into low-frequency garbage instead of fading
	## it. With the swept footprint the transmission rolls off as a sinc and simply gets quieter
	## with speed, which is what a real tyre does and what the maths can actually represent.
	##
	## The SLOPE is a least-squares fit through the same samples, so it costs no extra field
	## evaluations, and it is filtered identically to the height it belongs to. Multiplied by
	## ground speed it gives the road's own vertical velocity — the term the damper needs.
	var hd := heading
	if hd.length_squared() < 1e-6:
		hd = Vector2(1.0, 0.0)
	else:
		hd = hd.normalized()
	var n := maxi(patch_samples, 1)
	# The footprint is the CONTACT PATCH - a physical, speed-independent property. The swept
	# distance is NOT part of it: a real tyre on a 0.6 m ripple follows that ripple at any speed,
	# because 0.6 m is three times its contact length. Folding the sweep in unconditionally (as the
	# first cut did) low-passed the road by SPEED and cost 74% of the ridge at 100 km/h - it applied
	# a numerical fix as if it were physics, and the feature disappeared exactly where it matters.
	# Sampling once per tick IS a real limit, but only past Nyquist: one wavelength needs two
	# samples, so filtering starts only when a tick travels more than half a wavelength (~130 km/h
	# at 120 Hz on 0.6 m corrugation) - above that the samples cannot describe the ripple and are
	# filtered rather than allowed to alias into low-frequency garbage. Below it, nothing is touched.
	var over := maxf(swept - washboard_lambda * 0.5, 0.0)
	var half := maxf(contact_patch_len + over, 0.01) * 0.5
	var vals := PackedFloat32Array(); vals.resize(n)
	var sdv := 0.0
	var sdd := 0.0
	for i in range(n):
		var t := 0.0 if n <= 1 else (float(i) / float(n - 1)) * 2.0 - 1.0
		var d := t * half
		vals[i] = _raw(x + hd.x * d, z + hd.y * d)
		# offsets are symmetric about 0, so the regression needs no mean subtraction
		sdv += d * vals[i]
		sdd += d * d
	return Vector2(_envelope_profile(vals), 0.0 if sdd < 1e-9 else sdv / sdd)

func sample_enveloped(x: float, z: float, heading: Vector2) -> float:
	# static footprint (no sweep) - kept for callers that only want the height
	return sample_profile(x, z, heading, 0.0).x
