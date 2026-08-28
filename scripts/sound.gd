extends Node
## Procedural engine + tyre audio (asset-free by default).
## ENGINE: loops a STEADY engine drone (res://audio/engine_idle_loop.wav) and pitch-shifts it by rpm.
##   base_rpm is the rpm at pitch 1.0; it's centred so idle and redline both stay in a clean pitch
##   range (a single steady sample can't be perfect at both ends -> multi-sample crossfade comes later).
##   Falls back to a procedural damped-pulse engine if the sample is missing.
## TYRES: a rolling rumble that is ALWAYS present while moving (louder when the wheels slip), plus a
##   tonal SQUEAL that only appears when sliding on asphalt. Split by surface grip.
## A low-pass on the car's audio bus muffles everything in the interior (cockpit/dash) views.

var car     # the vehicle
var world   # world.gd, for the current camera mode
var stage   # RallyStage, for the BASE surface type (dirt vs asphalt) independent of wear

@export var engine_base_rpm := 2400.0    # rpm at pitch 1.0. RAISE if the engine sounds too high-pitched, LOWER if too low
@export var engine_pitch_min := 0.40     # pitch floor (idle never muddier than this); ceiling derives from the car's redline
@export var engine_base_freq := 44.0     # procedural fallback: firing frequency (Hz) at pitch 1.0
@export var engine_decay := 5.0          # procedural: pulse decay (higher = tighter thrum)
@export var engine_res := 2.0            # procedural: resonance modes per firing
@export var engine_gain := 0.5
@export var tyre_gain := 0.22            # rolling rumble level (lowered - ground was too loud)
@export var squeal_gain := 0.5           # asphalt squeal level
@export var cabin_cutoff := 1100.0       # low-pass cutoff (Hz) inside the cabin -> muffled
@export var open_cutoff := 9000.0        # cutoff from outside views -> open

var _eng_wav: AudioStreamWAV             # steady engine drone, seamless loop
var _use_sample := false
var _engine: AudioStreamPlayer
var _roll: AudioStreamPlayer             # rolling rumble (gravelly)
var _squeal: AudioStreamPlayer           # asphalt tonal squeal
var _puncture: AudioStreamPlayer         # low flat-tyre flap/rumble when a tyre is punctured
var _lowpass: AudioEffectLowPassFilter

func _ready() -> void:
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "CarAudio")
	AudioServer.set_bus_send(idx, "Master")
	_lowpass = AudioEffectLowPassFilter.new()
	_lowpass.cutoff_hz = open_cutoff
	AudioServer.add_bus_effect(idx, _lowpass)

	_eng_wav = _load_wav_file("res://audio/engine_idle_loop.wav")   # steady drone, seamless loop (raw PCM parse)
	if _eng_wav != null:
		var frames := _eng_wav.data.size() / 2              # 16-bit mono frames
		_eng_wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		_eng_wav.loop_begin = 0
		_eng_wav.loop_end = frames                          # loop the whole prepared clip forever
		_use_sample = frames > 2000
	_engine = _player(_eng_wav if _use_sample else _make_engine(engine_base_freq, 22050, 48))
	_roll = _player(_make_noise(22050, 0.5, 0.6))
	_squeal = _player(_load_skid())
	_puncture = _player(_make_puncture(22050))

func _player(stream: AudioStream) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = "CarAudio"
	p.volume_db = -60.0
	add_child(p)
	p.play()
	return p

func _load_wav_file(path: String) -> AudioStreamWAV:
	# read a 16-bit PCM .wav straight off disk into an AudioStreamWAV (exact frames + rate, no re-encode)
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF":
		return null
	var rate := 22050
	var pcm := PackedByteArray()
	var i := 12
	while i + 8 <= bytes.size():
		var cid := bytes.slice(i, i + 4).get_string_from_ascii()
		var csize := bytes.decode_u32(i + 4)
		if cid == "fmt ":
			rate = bytes.decode_u32(i + 8 + 4)              # sampleRate field of the fmt chunk
		elif cid == "data":
			pcm = bytes.slice(i + 8, i + 8 + csize)
			break
		i += 8 + csize + (csize & 1)
	if pcm.is_empty():
		return null
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = pcm
	return w

func _load_skid() -> AudioStream:
	# drop a free tyre-skid recording at res://audio/tire_skid.(wav|ogg|mp3) for a real slide sound
	for path in ["res://audio/tire_skid.ogg", "res://audio/tire_skid.wav", "res://audio/tire_skid.mp3"]:
		if ResourceLoader.exists(path):
			var s: AudioStream = load(path)
			if s is AudioStreamWAV:
				s.loop_mode = AudioStreamWAV.LOOP_FORWARD
			elif s is AudioStreamOggVorbis or s is AudioStreamMP3:
				s.loop = true
			return s
	return _make_skid(22050)

func _process(_delta: float) -> void:
	if car == null or not car.has_method("get_engine"):
		return
	var e: Dictionary = car.get_engine()
	var rpm := float(e["rpm"])
	# steady drone pitched by rpm; scales all the way to the car's redline (whatever it's set to), then a
	# hair of headroom caps any wheelspin overshoot. Consistent, never silent.
	var base_rpm: float = maxf(engine_base_rpm, 1.0)
	var redline_pitch: float = float(car.redline_rpm) / base_rpm
	_engine.pitch_scale = clampf(rpm / base_rpm, engine_pitch_min, redline_pitch + 0.15)
	var throttle := Input.get_action_strength("throttle")
	var running := rpm > 200.0                    # A1: a stalled engine goes silent
	var eng_level := (0.35 + 0.65 * throttle) * engine_gain if running else 0.0
	_engine.volume_db = lerpf(_engine.volume_db, linear_to_db(clampf(eng_level, 0.001, 1.0)), 0.25)

	# surface + slip
	var speed: float = car.linear_velocity.length()
	var roll := clampf(speed / 25.0, 0.0, 1.0)               # rolling-noise ramp (full by ~90 km/h)
	var slip := 0.0
	for w in car.get_wheels():
		slip = maxf(slip, w.slip)
	var tv := clampf((slip - 0.25) / 1.4, 0.0, 1.0)
	# HOW MUCH ASPHALT does the tyre hear? 1 = tarmac (rolling rumble drops away, the squeal layer
	# comes in), 0 = gravel/grass. D1 found this was the last of four places deciding what the
	# ground is, and the only one still doing it with a grip threshold - which had drifted WRONG:
	# `(grip - 1.0) / 0.25` is exact only while dirt_grip is 1.0, and it is 1.1, so every gravel
	# point read 0.400. The rally loop was being mixed as 40% tarmac: the asphalt squeal played
	# under every gravel slide and the gravel rumble was cut 28%. Now it asks the authority.
	var asph := 0.0
	var use_map: bool = true
	if car != null and car.get("tyre_audio_surface") != null:
		use_map = bool(car.tyre_audio_surface)
	var gm = stage.ground_map if stage != null and stage.get("ground_map") != null else null
	if use_map and gm != null:
		asph = 1.0 if gm.audio_at(car.global_position.x, car.global_position.z) == &"asphalt" else 0.0
	else:
		var gsrc = stage if stage != null else car.surface_source
		if gsrc != null and gsrc.has_method("grip_at"):
			var g: float = gsrc.grip_at(car.global_position.x, car.global_position.z)
			asph = clampf((g - 1.0) / 0.25, 0.0, 1.0)        # the pre-fix behaviour, kept for the A/B

	# rolling rumble: always there while moving (quiet), louder with slip; quieter on smooth asphalt
	var roll_level := (0.3 * roll + 0.7 * tv) * (1.0 - 0.7 * asph)
	_roll.volume_db = lerpf(_roll.volume_db, linear_to_db(clampf(roll_level * tyre_gain, 0.001, 1.0)), 0.3)
	_roll.pitch_scale = 0.8 + 0.5 * clampf(roll + tv, 0.0, 1.0)
	# tyre slide on asphalt: level + pitch both driven by HOW MUCH the tyres slide (slip) -- not a
	# fixed whistle. A real recording (res://audio/tire_skid.*) gives the layered texture.
	var squeal_level := tv * asph
	_squeal.volume_db = lerpf(_squeal.volume_db, linear_to_db(clampf(squeal_level * squeal_gain, 0.001, 1.0)), 0.35)
	_squeal.pitch_scale = 0.85 + 0.5 * tv

	# flat tyre: low flap/rumble whenever a tyre is punctured, faster + louder with speed
	var punctured := false
	for w in car.get_wheels():
		if w.punctured:
			punctured = true
			break
	var punc_level := (clampf(0.3 + speed / 22.0, 0.0, 0.95) if punctured else 0.0)
	_puncture.volume_db = lerpf(_puncture.volume_db, linear_to_db(clampf(punc_level, 0.001, 1.0)), 0.2)
	_puncture.pitch_scale = 0.55 + clampf(speed / 11.0, 0.0, 2.2)   # flap faster as you speed up

	# interior views (cockpit=1, dash=2) muffled; exterior open
	var interior: bool = world != null and (world._cam_mode == 1 or world._cam_mode == 2)
	if _lowpass != null:
		_lowpass.cutoff_hz = lerpf(_lowpass.cutoff_hz, cabin_cutoff if interior else open_cutoff, 0.12)

func _make_engine(freq: float, rate: int, cycles: int) -> AudioStreamWAV:
	var period := int(round(float(rate) / freq))
	var total := period * cycles
	var data := PackedByteArray(); data.resize(total * 2)
	var lp := 0.0
	for i in range(total):
		var ph := float(i % period) / float(period)
		var env := exp(-ph * engine_decay)
		var s := env * sin(ph * TAU * engine_res) * 0.6
		s += env * sin(ph * TAU * engine_res * 2.0) * 0.2
		s += sin(ph * TAU) * 0.28
		s += (randf() * 2.0 - 1.0) * env * 0.06
		lp = lp * 0.6 + s * 0.4
		data.encode_s16(i * 2, int(clampf(lp * 0.7, -1.0, 1.0) * 12000.0))
	return _wav(data, rate, total)

func _make_skid(rate: int) -> AudioStreamWAV:
	# fallback rubber-scrub: bright filtered noise + a faint resonance + a slow amplitude wobble, so
	# it reads as textured scrub rather than a monotone whistle (a real recording replaces it).
	var total := int(rate * 0.9)
	var data := PackedByteArray(); data.resize(total * 2)
	var lp := 0.0
	var res := 0.0
	for i in range(total):
		var n := randf() * 2.0 - 1.0
		lp = lp * 0.35 + n * 0.65                            # bright, lightly-filtered noise
		res = res * 0.82 + (n - res) * 0.18                  # faint resonant peak -> a little "edge"
		var wob := 0.55 + 0.45 * sin(float(i) / float(rate) * TAU * 5.0)  # slow wobble = texture
		var s := (lp * 0.8 + res * 0.5) * wob
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 8500.0))
	return _wav(data, rate, total)

func _make_puncture(rate: int) -> AudioStreamWAV:
	# low flat-tyre flap: a low rumble tone amplitude-modulated by a slow flap, plus low-passed noise
	var total := rate                          # 1 s loop
	var data := PackedByteArray(); data.resize(total * 2)
	var lp := 0.0
	for i in range(total):
		var t := float(i) / float(rate)
		var flap := 0.35 + 0.65 * pow(clampf(sin(t * TAU * 5.0), 0.0, 1.0), 2.0)   # ~5 Hz flap pulses
		var tone := sin(t * TAU * 52.0) * 0.6 + sin(t * TAU * 78.0) * 0.28          # low rumble
		var n := randf() * 2.0 - 1.0
		lp = lp * 0.86 + n * 0.14                                                   # low-passed noise
		var s := (tone * 0.7 + lp * 0.7) * flap
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 9000.0))
	return _wav(data, rate, total)

func _make_noise(rate: int, seconds: float, lp_factor: float) -> AudioStreamWAV:
	var total := int(rate * seconds)
	var data := PackedByteArray(); data.resize(total * 2)
	var last := 0.0
	for i in range(total):
		last = last * lp_factor + (randf() * 2.0 - 1.0) * (1.0 - lp_factor)
		data.encode_s16(i * 2, int(clampf(last, -1.0, 1.0) * 9000.0))
	return _wav(data, rate, total)

func _wav(data: PackedByteArray, rate: int, total: int) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = total
	w.data = data
	return w
