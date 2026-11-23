extends Node3D
## M0 bootstrap. Builds the whole scene in code (robust + version-controllable):
## input map, lighting/sky, a flat ground plane, the vehicle, chase camera, and HUD.
## Later milestones swap the flat ground for terrain (M5) and a deformable patch (M3).

const GROUND_SIZE := 4000.0

var _chase_cam: Camera3D
var _cockpit_cam: Camera3D        # driver's-eye view (rigidly attached to the car)
var _dash_cam: Camera3D           # dash-mounted forward view (rigidly attached)
var _hood_cam: Camera3D           # bonnet view (rigidly attached to the car)
var _rear_cam: Camera3D           # rear-facing camera feeding the cockpit rear-view mirror overlay
var _mirror_layer: CanvasLayer    # the mirror panel; shown only in cockpit view
var _mirror_vp: SubViewport       # the mirror's own render of the world; see _apply_mirror()
var _status_layer: CanvasLayer    # bottom-right rev/speed/telltales; the OUTSIDE-view cluster
var _cam_mode := 0                # 0 = chase, 1 = cockpit, 2 = dash, 3 = bonnet
var _car                          # the vehicle (untyped so get_wheels() resolves dynamically)
var _stage                        # RallyStage, for the base surface type (skid marks are asphalt-only)
var _sun: DirectionalLight3D      # M10: the sun, cycled by time-of-day
var _env: Environment
var _sky_mat: ShaderMaterial      # Arc E: procedural sky WITH clouds (was ProceduralSkyMaterial)
var _tod := 0                     # time-of-day preset index
# --- Right-stick look. The LEFT stick steers, so looking around lives on the right one. The
# mapping is ABSOLUTE (stick deflection = view angle) rather than accumulating, so letting go
# re-centres the view by itself the way your head does - no drift, nothing to reset. Clicking
# the stick (R3) toggles a 180 deg look-back. ---
var _look_yaw := 0.0              # rad, smoothed
var _look_pitch := 0.0
var _look_back := false
var _rigid_cams: Array = []       # interior cams + the pitch they were mounted at
const LOOK_DEADZONE := 0.15
const LOOK_YAW_INTERIOR := 150.0  # deg: far enough to look over your shoulder
const LOOK_YAW_CHASE := 180.0     # deg: a full orbit of the car
const LOOK_PITCH_MAX := 22.0      # deg
const LOOK_TAU := 0.10            # s, view smoothing (a head doesn't snap)

const TOD := [
	{"name": "NOON",    "rot": Vector3(-72, -40, 0),  "col": Color(1.0, 0.98, 0.95), "energy": 1.25, "top": Color(0.34, 0.50, 0.86), "horizon": Color(0.72, 0.82, 0.95), "ambient": 0.95},
	{"name": "MORNING", "rot": Vector3(-28, -72, 0),  "col": Color(1.0, 0.90, 0.74), "energy": 1.05, "top": Color(0.40, 0.55, 0.85), "horizon": Color(0.86, 0.86, 0.84), "ambient": 0.85},
	{"name": "EVENING", "rot": Vector3(-13, -118, 0), "col": Color(1.0, 0.58, 0.32), "energy": 1.15, "top": Color(0.28, 0.32, 0.58), "horizon": Color(0.95, 0.58, 0.35), "ambient": 0.6},
	{"name": "NIGHT",   "rot": Vector3(-46, -30, 0),  "col": Color(0.55, 0.65, 0.95), "energy": 0.30, "top": Color(0.02, 0.03, 0.09), "horizon": Color(0.08, 0.11, 0.20), "ambient": 0.4},
]

var _circuit_cls: Array = []                  # D2/D3: one Centreline per timed circuit + the stage
var _time_trial
var _stage_area: StageArea = null            # D3: the generated SHAKEDOWN stage
var _area_manager: AreaManager = null        # D5: areas + the connecting tunnel

func _ready() -> void:
	Engine.max_fps = 144
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)    # smooth 60 on the built-in 60Hz panel (no tearing)
	_setup_input()
	_build_environment()
	var stage = _build_stage()                   # untyped so get_spawn() resolves dynamically
	_stage = stage
	var car: RigidBody3D = _build_car()
	_car = car
	car.surface_source = stage                   # per-surface traction (asphalt grips > dirt > grass)
	car.spawn_transform = stage.get_spawn()      # start on the road
	car.respawn()
	# D2: ONE centreline per circuit, built once and shared. 4320 samples is the common multiple
	# that lets each consumer keep its OWN density by striding - pace_notes 1440 (x3), wear 1080
	# (x4) - so they read exactly the points they used to compute from stage._road(theta) and their
	# output is unchanged, while none of them knows the road is polar any more. That last part is
	# the phase: D3 replaces the polar road and these consumers do not change.
	_circuit_cls = _build_circuit_centrelines(stage)
	_stage_area = _build_stage_area(stage)        # D3: the generated SHAKEDOWN stage, its own area
	_circuit_cls.append(_stage_area.gen.centreline)
	var wn := _build_wear(car, stage)             # M6: surface degradation wraps grip_at (corners + braking zones)
	_build_roughness(car, stage, wn)              # C1: procedural surface texture fed into the suspension raycast
	_build_cameras(car)
	_build_effects(car, stage)                   # M11: surface-aware dust, tyre smoke, fading marks
	var hud := _build_hud(car)
	_build_component_hud(car)
	_build_status_hud(car)
	_build_pacenotes(car, stage)
	var tt := _build_timetrial(car, stage)
	_time_trial = tt
	hud.time_trial = tt                          # HUD shows the active circuit's lap/last/best
	_build_tuning(car)
	_build_rearview(car)
	_build_reactive_patch(car, stage)
	_build_area_manager(car, stage)               # D5: the tunnel between the two areas
	_build_sound(car, stage)
	_warm_shaders()
	if OS.get_cmdline_user_args().has("--bench"):
		# GPU cost benchmark: replays a fixed forest path once per configuration and quits.
		var bench: Node = load("res://scripts/bench.gd").new()
		bench.name = "Bench"
		bench.world = self
		add_child(bench)

func _physics_process(delta: float) -> void:
	if _car == null:
		return
	_void_rescue()
	if Input.is_action_just_pressed("time_of_day"):
		_tod = (_tod + 1) % TOD.size()
		_apply_tod(_tod)
	if _rear_cam != null:                                 # rear-view: back by the rear window (behind the seats), looking out
		var rb: Transform3D = _car.global_transform
		_rear_cam.look_at_from_position(rb * Vector3(0, 0.82, 0.78), rb * Vector3(0, 0.5, 25.0), rb.basis.y)

	# M11: dust / smoke / skid marks moved to scripts/effects.gd, where they are driven by
	# contact-patch slip velocity and tyre temperature instead of a flat "is it spinning" test.

func _build_area_manager(car: Node3D, stage) -> AreaManager:
	## D5: owns which area the car is in and the tunnel that joins them. Built AFTER the stage area,
	## because its stage-side portal sits on that stage's start line.
	var am := AreaManager.new()
	am.name = "AreaManager"
	am.stage = stage
	am.stage_area = _stage_area
	am.car = car
	am.chase_camera = _chase_cam       # carried across the swap; it lerps and would otherwise sail
	add_child(am)
	am.build()
	# R is RESET, and after crossing it must put you back in the area you are actually in - not in
	# the one you started the session in. Reported as "the R spawn doesn't change when passing it".
	am.area_changed.connect(func(which: int):
		if which == AreaManager.Area.STAGE:
			car.spawn_transform = _stage_area.spawn_transform()
		else:
			car.spawn_transform = stage.get_spawn())
	_area_manager = am
	return am

func _build_effects(car: Node3D, stage) -> void:
	var fx: Node3D = load("res://scripts/effects.gd").new()
	fx.name = "SurfaceEffects"
	add_child(fx)
	fx.car = car
	fx.stage = stage
	# The [J] performance overlay reports the stage streamer's residency alongside draw calls and
	# primitives, because those are the numbers the chunk budget moves. Built after the stage area.
	fx.stage_area = _stage_area

func _build_sound(car: Node3D, stage) -> void:
	var snd: Node = load("res://scripts/sound.gd").new()
	snd.name = "Sound"
	add_child(snd)
	snd.car = car
	snd.world = self       # for the interior (cockpit/dash) muffle
	snd.stage = stage      # base surface type for the tyre-audio split (independent of wear)

func _build_pacenotes(car: Node3D, stage) -> void:
	var pn: CanvasLayer = load("res://scripts/pace_notes.gd").new()
	pn.name = "PaceNotes"
	pn.car = car
	pn.stage = stage        # still used for _height and the note trigger geometry
	pn.centrelines = _circuit_cls   # D2: routes are built from the shared centrelines
	pn.stage_area = _stage_area     # D3: the generated stage's FINISH gate (timed end, not road end)
	add_child(pn)

func _build_status_hud(car: Node3D) -> void:
	# bottom-right: rev arc + gear + speed + warning telltales. Shown in the views where the
	# in-cabin pod can't be read; the cockpit and dash views have the real instrument instead.
	_status_layer = CanvasLayer.new()
	_status_layer.name = "StatusHUD"
	_status_layer.layer = 3
	var sh: Control = load("res://scripts/status_hud.gd").new()
	sh.car = car
	_status_layer.add_child(sh)
	add_child(_status_layer)
	_status_layer.visible = not (_cam_mode == 1 or _cam_mode == 2)

func _build_component_hud(car: Node3D) -> void:
	var cl := CanvasLayer.new()
	cl.name = "ComponentHUD"
	cl.layer = 3
	var ch: Control = load("res://scripts/component_hud.gd").new()
	ch.car = car                 # top-down schematic: tyre + engine temps, punctures, wear
	cl.add_child(ch)
	add_child(cl)

const CIRCUIT_SAMPLES := 4320                 # LCM(1440 pace notes, 1080 wear), and divisible by 3 sectors

func _build_stage_area(stage) -> StageArea:
	## D3: generate a stage from parameters and build it as its own area. §1.1 - the legacy map is
	## untouched; this is purely additive. The ground map takes it as an extra LAYER, which is why
	## nothing in stage.gd, sound.gd, effects.gd, roughness.gd or wear.gd needed changing for the
	## car to grip, sound and throw dust correctly on a road none of them knew about.
	var sdef := StageDef.new()
	var g := StageGen.new(sdef)
	g.generate()
	var area := StageArea.new()
	area.name = "ShakedownStage"
	area.gen = g
	area.def = sdef
	add_child(area)
	stage.ground_map.areas.append(area)
	return area

func _wire_stage_area_live(area: StageArea, car: Node3D, tt: Node) -> void:
	# live stage-parameter edits: rebuild, then re-point everything that holds the old centreline
	area.attach_car(car)               # D4: also re-derives the streamer's lead from the car's speed
	area.regenerated.connect(func():
		_circuit_cls[3] = area.gen.centreline
		tt.centrelines = _circuit_cls
		tt.build_triggers()
		var pn := get_node_or_null("PaceNotes")
		if pn != null:
			pn.centrelines = _circuit_cls
			pn.rebuild_routes()
		# D5: the portals are placed FROM the road - position AND height - so a new seed needs them
		# placed again. Without this the tunnel keeps the geometry of whatever seed was live at
		# startup, which is why it lined up on one seed and was wrong on all the others.
		if _area_manager != null:
			_area_manager.rebuild()
		if tt._active == 3:
			car.spawn_transform = area.spawn_transform()
			car.respawn())

func _build_circuit_centrelines(stage) -> Array:
	var out: Array = []
	for which in range(3):
		var rfn := func(th): return stage._circuit_r(which, th)
		var hwfn := func(th): return stage._road_halfwidth(th)
		out.append(Centreline.from_polar(stage.road_center, rfn, hwfn,
			Callable(stage, "_height"), CIRCUIT_SAMPLES))
	return out

func _build_wear(car: Node3D, stage) -> Node:
	var wn: Node = load("res://scripts/wear.gd").new()
	wn.name = "Wear"
	wn.car = car
	wn.stage = stage
	wn.centreline = _circuit_cls[1] if _circuit_cls.size() > 1 else null   # D2: the RALLY LOOP
	add_child(wn)
	car.surface_source = wn   # grip queries now flow through wear (which wraps stage.grip_at)
	return wn

func _build_roughness(car: Node3D, stage, wn: Node) -> Node:
	# C1.0: express the existing polar rally loop as a Centreline - same points wear.gd/pace_notes.gd
	# already sample from _road(th), reached through the shared arc-length interface (no geometry
	# change). Only the rally loop needs one: it is the only surface with a washboard term.
	var hwfn := func(th): return stage._road_halfwidth(th)
	var cl := Centreline.from_polar(stage.road_center, Callable(stage, "_road"), hwfn,
		Callable(stage, "_height"), 4000)
	var rn: Node = load("res://scripts/roughness.gd").new()
	rn.name = "Roughness"
	rn.stage = stage
	rn.wear = wn
	rn.centreline_gravel = cl
	rn.set_asphalt(stage.asphalt_radius)
	# D1: the ground map classifies the position, this node owns the ISO 8608 coefficients. Wiring
	# it as the map's road_class_source keeps ONE home for each number while the classification
	# comes from the single authority (§6.1).
	stage.ground_map.road_class_source = rn
	add_child(rn)
	car.roughness_field = rn
	return rn

func _build_timetrial(car: Node3D, stage) -> Node3D:
	var tt: Node3D = load("res://scripts/time_trial.gd").new()
	tt.name = "TimeTrial"
	tt.car = car            # records the best lap + replays a ghost to chase
	tt.stage = stage        # for get_spawn_for() when toggling circuits
	tt.centrelines = _circuit_cls          # D2: laps/sectors are arc-length triggers now
	tt.area = _stage_area                  # D3: SHAKEDOWN spawns on its own start line
	tt.build_triggers()
	_wire_stage_area_live(_stage_area, car, tt)
	add_child(tt)
	return tt

func _build_reactive_patch(car: Node3D, stage) -> void:
	# small deformable dirt patch in the CENTRE (M3 reactive terrain). It sits on the stage's flat
	# centre disc (bed 0.15 above the graded ground), so the wheels dig ruts / kick berms there.
	var patch: Node = load("res://scripts/terrain.gd").new()
	patch.name = "ReactivePatch"
	patch.zone_center = Vector3(0, 0, 0)          # set BEFORE add_child so its _ready() uses them
	patch.track_center = Vector3(0, 0, 0)
	patch.zone_size = 150.0                        # bigger centre dirt area (+20 m each side)
	add_child(patch)
	patch.vehicle = car                            # feeds get_wheels()/velocity for the dig model
	if stage != null:
		stage.patch_color = patch.dirt_color       # terrain.gd owns the patch's dirt colour; the
		                                           # stage only needs to answer "what is underfoot
		                                           # here" with the same answer (dust tint)

func _build_stage() -> Node:
	# M5 procedural rally stage (elevated terrain + winding road). Replaces the old flat
	# ground / test course / deformable dirt field (those remain in the repo for reference).
	var stage: Node = load("res://scripts/stage.gd").new()
	stage.name = "Stage"
	add_child(stage)
	return stage

func _build_tuning(car: Node) -> void:
	var panel: CanvasLayer = load("res://scripts/tuning_panel.gd").new()
	panel.name = "TuningPanel"
	panel.layer = 6                              # above the HUD layers, so the sliders are never
	                                             # hidden behind the bottom-right instrument
	panel.vehicle = car
	add_child(panel)

func _build_course() -> void:
	var course: Node3D = load("res://scripts/course.gd").new()
	course.name = "Course"
	add_child(course)

# ---------------------------------------------------------------------------
# Input (defined in code so it's self-contained and works headless).
# Keyboard + Xbox/PS gamepad. WASD/arrows + triggers/left-stick.
# ---------------------------------------------------------------------------
func _setup_input() -> void:
	_add_keys("throttle",   [KEY_W, KEY_UP])
	_add_keys("brake",      [KEY_S, KEY_DOWN])
	_add_keys("steer_left", [KEY_A, KEY_LEFT])
	_add_keys("steer_right",[KEY_D, KEY_RIGHT])
	_add_keys("handbrake",  [KEY_SPACE])
	_add_keys("reset",      [KEY_R])
	_add_keys("camera_toggle", [KEY_C])
	_add_keys("look_back",     [KEY_V])   # 180 deg glance behind (right-stick click on a pad)
	_add_keys("tuning_toggle", [KEY_TAB])
	_add_keys("shift_up",   [KEY_E])
	_add_keys("shift_down", [KEY_Q])
	_add_keys("clutch",     [KEY_SHIFT])  # A1: clutch pedal, held = disengaged (manual-clutch mode)
	_add_keys("ignition",   [KEY_I])      # A2: starter button - re-fires a stalled engine
	_add_keys("hud_bigger",  [KEY_EQUAL, KEY_KP_ADD])
	_add_keys("hud_smaller", [KEY_MINUS, KEY_KP_SUBTRACT])
	_add_keys("hud_menu",    [KEY_H])          # HUD menu; rebindable from inside the menu (hud.gd)
	_add_keys("drive_mode",  [KEY_T])
	_add_keys("circuit_toggle", [KEY_B])
	_add_keys("puncture_test", [KEY_P])   # debug: puncture a tyre to test the flat visual + vibration
	_add_keys("time_of_day", [KEY_L])     # cycle noon/morning/evening/night
	_add_keys("diff_preset_1", [KEY_1, KEY_KP_1])   # A3: OPEN / VISCOUS / RALLY diff setups,
	_add_keys("diff_preset_2", [KEY_2, KEY_KP_2])   # swappable mid-drive for back-to-back
	_add_keys("diff_preset_3", [KEY_3, KEY_KP_3])   # comparison on the same corner

	# --- Gamepad: Assetto-Corsa-style rally layout (PS4 DualShock 4 names in comments;
	# Godot's A/B/X/Y are SDL positions, so on a DS4 they read Cross/Circle/Square/Triangle).
	# Driving lives on triggers + shoulders + face buttons; everything utility sits on the
	# d-pad, the menu buttons and the stick clicks so nothing important is a thumb-slip away.
	_add_axis("throttle",    JOY_AXIS_TRIGGER_RIGHT, 1.0)      # R2
	_add_axis("brake",       JOY_AXIS_TRIGGER_LEFT,  1.0)      # L2
	_add_axis("steer_left",  JOY_AXIS_LEFT_X, -1.0)            # left stick
	_add_axis("steer_right", JOY_AXIS_LEFT_X,  1.0)
	_add_button("shift_up",   JOY_BUTTON_RIGHT_SHOULDER)       # R1
	_add_button("shift_down", JOY_BUTTON_LEFT_SHOULDER)        # L1
	_add_button("handbrake",  JOY_BUTTON_A)                    # Cross - rally standard
	_add_button("clutch",     JOY_BUTTON_X)                    # Square (hold = disengaged)
	_add_button("ignition",   JOY_BUTTON_B)                    # Circle - starter button
	_add_button("camera_toggle", JOY_BUTTON_Y)                 # Triangle
	_add_button("circuit_toggle", JOY_BUTTON_DPAD_LEFT)
	_add_button("time_of_day",    JOY_BUTTON_DPAD_RIGHT)
	_add_button("hud_bigger",     JOY_BUTTON_DPAD_UP)
	_add_button("hud_smaller",    JOY_BUTTON_DPAD_DOWN)
	_add_button("drive_mode",    JOY_BUTTON_BACK)     # Share: AWD/RWD/FWD
	_add_button("tuning_toggle", JOY_BUTTON_START)    # Options: tuning panel
	_add_button("reset",             JOY_BUTTON_LEFT_STICK)    # L3 - deliberate, never a slip
	_add_button("look_back",         JOY_BUTTON_RIGHT_STICK)   # R3 - pairs with the look stick
	_add_button("diff_preset_next",  JOY_BUTTON_TOUCHPAD)      # touchpad click: cycle 1/2/3

	# analog deadzones: triggers rest at 0 (small dz), sticks drift a little (a touch more)
	InputMap.action_set_deadzone("throttle", 0.06)
	InputMap.action_set_deadzone("brake", 0.06)
	InputMap.action_set_deadzone("steer_left", 0.12)
	InputMap.action_set_deadzone("steer_right", 0.12)

func _ensure(action: String) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)

func _add_keys(action: String, keys: Array) -> void:
	_ensure(action)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(action, e)

func _add_axis(action: String, axis: JoyAxis, value: float) -> void:
	_ensure(action)
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	InputMap.action_add_event(action, e)

func _add_button(action: String, button: JoyButton) -> void:
	_ensure(action)
	var e := InputEventJoypadButton.new()
	e.button_index = button
	InputMap.action_add_event(action, e)

# ---------------------------------------------------------------------------
# Scene construction
# ---------------------------------------------------------------------------
## ARC E - THE SKY. ProceduralSkyMaterial is an empty two-colour gradient, which is a large part of
## why the game read as a model on a table rather than a place. This is the same gradient plus a sun
## disc and a layer of fbm cumulus projected onto a plane overhead, lit by the sun's own colour so
## the time-of-day presets carry through. It uses no TIME, so the sky's radiance (the ambient light
## it feeds) is re-baked only when a uniform changes - i.e. on a time-of-day switch, not per frame.
const SKY_SHADER := """
shader_type sky;
render_mode use_half_res_pass;
uniform vec3 top_col : source_color = vec3(0.34, 0.50, 0.86);
uniform vec3 horizon_col : source_color = vec3(0.72, 0.82, 0.95);
uniform vec3 ground_col : source_color = vec3(0.25, 0.27, 0.24);
uniform float cloud_cover = 0.45;
uniform float cloud_shade = 1.0;
float hash(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) {
	float a = 0.5;
	float v = 0.0;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}
void sky() {
	// The clouds are soft, so they are computed in the HALF-RESOLUTION sky pass (a quarter of the
	// pixels) and the full-resolution pass only reads that back and adds the sharp sun disc. Per-pixel
	// cost was what made the 2026-11-17 fullscreen drive GPU-bound, and the sky covers much of it.
	vec3 d = EYEDIR;
	float h = d.y;
	vec3 sun_c = LIGHT0_COLOR * LIGHT0_ENERGY;
	float sd = dot(d, LIGHT0_DIRECTION);
	if (AT_HALF_RES_PASS || AT_CUBEMAP_PASS) {
		vec3 col = mix(horizon_col, top_col, pow(clamp(h, 0.0, 1.0), 0.45));
		if (h < 0.0) {
			col = mix(horizon_col, ground_col, clamp(-h * 6.0, 0.0, 1.0));
		}
		if (LIGHT0_ENABLED) {
			col += sun_c * pow(max(sd, 0.0), 48.0) * 0.25;
		}
		float cov_out = 0.0;
		if (h > 0.0) {
			vec2 uv = d.xz / (h + 0.06);
			float c = fbm(uv * 0.55 + vec2(3.7, 1.3));
			float cov = smoothstep(1.0 - cloud_cover - 0.08, 1.0 - cloud_cover + 0.22, c);
			// thicker cloud is darker underneath; the sun side of each cloud is brighter
			float thick = smoothstep(0.4, 0.85, c);
			vec3 lit = mix(horizon_col * 1.1, sun_c * 0.85 + horizon_col * 0.35, 0.65 - thick * 0.35);
			lit += sun_c * pow(max(sd, 0.0), 6.0) * 0.35;
			cov_out = cov * smoothstep(0.0, 0.12, h) * 0.92;
			col = mix(col, lit * cloud_shade, cov_out);
		}
		COLOR = col;
		ALPHA = 1.0 - cov_out;            // how much of the sun disc a cloud lets through
		if (AT_CUBEMAP_PASS && LIGHT0_ENABLED) {
			COLOR += sun_c * smoothstep(0.99955, 0.99975, sd) * 12.0 * ALPHA;
			ALPHA = 1.0;
		}
	} else {
		COLOR = HALF_RES_COLOR.rgb;
		if (LIGHT0_ENABLED) {
			COLOR += sun_c * smoothstep(0.99955, 0.99975, sd) * 12.0 * HALF_RES_COLOR.a;
		}
	}
}
"""

func _build_environment() -> void:
	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = true
	# Arc E: shadows reach far enough to lay the roadside spruces' shadows across the road ahead, and
	# soft enough at the edge that the penumbra reads as sunlight rather than a stencil.
	# Back to 100 m (Godot's default, what main used) after the fullscreen comparison - see
	# gfx_shadow_m on the car, which drives it live.
	_sun.directional_shadow_max_distance = 100.0
	_sun.shadow_blur = 1.0
	# Two cascades, not four: every shadow caster is drawn once per cascade it touches, and over a
	# 100 m range two splits keep the near shadows sharp. Halves the shadow passes.
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	_sun.directional_shadow_split_1 = 0.25
	add_child(_sun)

	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var ssh := Shader.new()
	ssh.code = SKY_SHADER
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = ssh
	sky.sky_material = _sky_mat
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# ARC E - TONEMAPPING. The default LINEAR mapper clips: a sunlit light surface lands above 1.0
	# and is drawn white, which is the washed-out road and grass the audit's baseline screenshots
	# showed. Filmic rolls the highlights off instead of clipping them.
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.tonemap_exposure = 0.95
	_env.tonemap_white = 6.0
	# ARC E - AERIAL PERSPECTIVE. Without it a hill 800 m away is as sharp and saturated as the road
	# under the car, which flattens the depth of the whole picture. Exponential fog tinted by the sky
	# (aerial_perspective) makes distance read as distance. The density puts ~60% haze at the
	# streamer's 800 m road horizon, so the far end of the road window fades into the sky rather
	# than ending.
	_env.fog_enabled = true
	_env.fog_density = 0.0011
	_env.fog_aerial_perspective = 0.55
	_env.fog_sky_affect = 0.0
	_env.fog_sun_scatter = 0.15
	# Screen-space extras, both behind the Tab panel's graphics switch (see _apply_gfx).
	_env.ssao_radius = 1.2
	_env.ssao_intensity = 1.6
	_env.ssao_power = 1.4
	_env.ssao_detail = 0.4
	_env.glow_intensity = 0.35
	_env.glow_strength = 0.9
	_env.glow_bloom = 0.0
	_env.glow_hdr_threshold = 1.2
	_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)
	_apply_tod(_tod)
	_apply_gfx(false)

func _warm_shaders() -> void:
	## THE FIRST 30 SECONDS ON SHAKEDOWN STUTTERED (drive 2026-11-17): the frame log shows shaders
	## compiling at the moment the car arrived, because the stage's ground, tree and backdrop
	## materials are first DRAWN there, 3 km from the spawn. Draw each of them once, a couple of
	## metres in front of the chase camera and behind the car, during the first frames - with shadows,
	## so the shadow-pass variants compile too - then remove them.
	if _stage_area == null or _stage_area.chunks == null or _chase_cam == null:
		return
	var ch = _stage_area.chunks
	var meshes: Array = []
	var q := QuadMesh.new()
	q.size = Vector2(0.05, 0.05)
	q.material = ch._mat
	meshes.append(q)
	if ch._backdrop != null:
		var q2 := QuadMesh.new()
		q2.size = Vector2(0.05, 0.05)
		q2.material = ch._backdrop.mesh.surface_get_material(0)
		meshes.append(q2)
	if ch.forest != null:
		meshes.append(ch.forest.mesh_near)
		meshes.append(ch.forest.mesh_far)
	var holder := Node3D.new()
	holder.name = "ShaderWarmup"
	_chase_cam.add_child(holder)
	var x := -0.06
	for m in meshes:
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.scale = Vector3.ONE * 0.05
		mi.position = Vector3(x, 0.0, -1.5)
		holder.add_child(mi)
		x += 0.04
	# a few frames is enough for the pipelines to be built; then it is gone
	get_tree().create_timer(0.5).timeout.connect(holder.queue_free)

func _apply_gfx(high: bool) -> void:
	_env.ssao_enabled = high
	_env.glow_enabled = high

## SHADOW MODES (2026-11-18): see StageChunks.shadow_mode. The bake lives in the stage ground; the
## world owns the sun, so it switches the shadow map and tells the ground which way the sun is.
var _shadow_mode := 0
var _contact: Decal = null

func _sun_toward() -> Vector3:
	# A DirectionalLight3D shines along its -Z; the sun is therefore along +Z.
	return _sun.global_transform.basis.z.normalized()

func _apply_shadow_mode() -> void:
	_sun.shadow_enabled = _shadow_mode != 2
	if _stage_area != null and _stage_area.chunks != null:
		_stage_area.chunks.set_shadow_bake(_shadow_mode, _sun_toward())
	# BAKED has no shadow map, so nothing would put the car on the ground. A Decal stands in for the
	# shadow it would cast - shaped and placed from the SUN each frame; see _update_car_shadow().
	if _shadow_mode == 2 and _contact == null and _car != null:
		_contact = Decal.new()
		_contact.name = "ContactShadow"
		_contact.cull_mask = StageChunks.GROUND_LAYER   # the ground only - never the car itself
		_car.add_child(_contact)
		_contact.top_level = true          # placed in world space: the sun's offset is not the car's
	if _contact != null:
		_contact.visible = _shadow_mode == 2

## THE CAR'S SHADOW IN BAKED MODE (2026-11-23). sagi: "the under shadow for the car is too small".
## It was a fixed 2.4 x 4.9 m oval, dark only inside 45% of its radius (~1.1 x 2.2 m - smaller than
## the car) and straight down whatever the sun did, while the live shadow at a 13-28 deg sun is
## several metres long and thrown away from the sun. Now the shadow is the car's own silhouette
## projected along the sun: the hull of the body box and the cabin box, each corner moved by its
## height above the ground times u = -L.xz / L.y. The hull depends on the sun only through the angle
## between the car and the sun, so images are cached per 4-degree bucket of that angle (and dropped
## when the sun moves); one costs ~3 ms to draw, once.
const CAR_SHADOW_BOXES := [
	# [half width, z min, z max, bottom height, top height] above the ground, car frame (fwd = -Z)
	[0.90, -2.10, 2.10, 0.20, 0.85],        # body, body_size 1.8 x 4.2
	[0.70, -0.65, 0.55, 0.85, 1.58],        # cabin up to the roof (roof at 0.98 above the origin)
]
const CAR_SHADOW_RES := 12.0              # pixels per metre
var _cs_cache := {}
var _cs_sun := Vector3.ZERO

func _car_shadow_hull(u: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for bx in CAR_SHADOW_BOXES:
		for x in [-float(bx[0]), float(bx[0])]:
			for z in [float(bx[1]), float(bx[2])]:
				for y in [float(bx[3]), float(bx[4])]:
					pts.append(Vector2(x, z) + u * y)
	return Geometry2D.convex_hull(pts)

func _update_car_shadow() -> void:
	if _contact == null or not _contact.visible or _car == null:
		return
	var L: Vector3 = _sun_toward()
	if L.y < 0.05:
		L = Vector3(L.x, 0.05, L.z).normalized()
	if L.distance_to(_cs_sun) > 1e-3:
		_cs_sun = L
		_cs_cache.clear()
	var b: Basis = _car.global_transform.basis
	var fwd := Vector3(-b.z.x, 0.0, -b.z.z)
	if fwd.length_squared() < 1e-6:
		return
	fwd = fwd.normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	# the shadow offset per metre of height, world -> car frame (x = right, z = back)
	var uw := Vector2(-L.x, -L.z) / L.y
	var u := Vector2(uw.dot(Vector2(right.x, right.z)), -uw.dot(Vector2(fwd.x, fwd.z)))
	var bucket: int = int(round(rad_to_deg(u.angle()) / 4.0))
	if not _cs_cache.has(bucket):
		_cs_cache[bucket] = _draw_car_shadow(Vector2.from_angle(deg_to_rad(float(bucket) * 4.0)) * u.length())
	var e: Dictionary = _cs_cache[bucket]
	_contact.texture_albedo = e["tex"]
	var c: Vector2 = e["centre"]
	var sz: Vector2 = e["size"]
	_contact.size = Vector3(sz.x, 4.0, sz.y)
	var p: Vector3 = _car.global_position + right * c.x - fwd * c.y
	_contact.global_transform = Transform3D(Basis(right, Vector3.UP, -fwd), p + Vector3(0.0, -0.3, 0.0))
	_contact.modulate = Color(1, 1, 1, 0.92 * _sun.shadow_opacity)

func _draw_car_shadow(u: Vector2) -> Dictionary:
	var hull := _car_shadow_hull(u)
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for q in hull:
		lo = lo.min(q)
		hi = hi.max(q)
	var soft := 0.25                       # m of penumbra: a car's shadow edge is close and sharp
	lo -= Vector2(soft, soft)
	hi += Vector2(soft, soft)
	var w := int(ceil((hi.x - lo.x) * CAR_SHADOW_RES))
	var hgt := int(ceil((hi.y - lo.y) * CAR_SHADOW_RES))
	var img := Image.create(w, hgt, false, Image.FORMAT_LA8)
	var n := hull.size() - 1               # convex_hull repeats the first point at the end
	var flip: float = -1.0 if Geometry2D.is_polygon_clockwise(hull) else 1.0
	for py in range(hgt):
		for px in range(w):
			var q := lo + Vector2((float(px) + 0.5) / CAR_SHADOW_RES, (float(py) + 0.5) / CAR_SHADOW_RES)
			# signed distance to the hull: max over the edges of the outward distance
			var dmax := -1e9
			for i in range(n):
				var a: Vector2 = hull[i]
				var ed: Vector2 = hull[i + 1] - a
				var nrm := Vector2(ed.y, -ed.x).normalized() * flip
				dmax = maxf(dmax, (q - a).dot(nrm))
			var al: float = 1.0 - smoothstep(-soft, soft, dmax)
			img.set_pixel(px, py, Color(0.0, 0.0, 0.0, al))
	# a Decal's texture runs +X right and +Z toward the bottom of the image
	return {"tex": ImageTexture.create_from_image(img), "centre": (lo + hi) * 0.5, "size": hi - lo}

func _apply_tod(i: int) -> void:
	var p: Dictionary = TOD[i]
	_sun.rotation_degrees = p["rot"]
	_sun.light_color = p["col"]
	_sun.light_energy = p["energy"]
	_sky_mat.set_shader_parameter("top_col", p["top"])
	_sky_mat.set_shader_parameter("horizon_col", p["horizon"])
	# clouds are lit by the sun; at night there is nothing to light them, so they go to silhouettes
	_sky_mat.set_shader_parameter("cloud_shade", clampf(float(p["energy"]) / 1.1, 0.25, 1.0))
	# Arc E: the sky now feeds real ambient (it has clouds and a bright horizon), and at the presets'
	# old energy that flat fill swamped the sun - no shading contrast, everything pale. A clear-sky
	# day is roughly 80% direct and 20% sky light on a horizontal surface; 0.55 of the old fill puts
	# the shadow side back near that ratio.
	# NIGHT is the exception (drive verdict 2026-11-17: "maybe the night shadows are too strong"). By
	# moonlight the direct beam is weak and the sky's share of the light is much larger, so cutting
	# the fill there made shadows near-black. Scale the cut by how strong the sun is.
	var sun_share: float = clampf((float(p["energy"]) - 0.3) / 0.75, 0.0, 1.0)
	_env.ambient_light_energy = float(p["ambient"]) * lerpf(0.95, 0.55, sun_share)
	# ...and moon shadows are soft-edged and faint, not stencils: the moon is a weak, broad source.
	_sun.shadow_opacity = lerpf(0.6, 1.0, sun_share)
	# the haze takes the horizon's colour, so morning haze is warm and night haze is dark blue
	_env.fog_light_color = p["horizon"]
	_env.fog_light_energy = clampf(float(p["energy"]), 0.15, 1.0)
	if _stage_area != null and _stage_area.chunks != null:
		_stage_area.chunks.set_bake_strength(_sun.shadow_opacity)
		_stage_area.chunks.set_shadow_bake(_shadow_mode, _sun_toward())

func _build_ground() -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = 1
	body.collision_mask = 1 | 2 | 4

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GROUND_SIZE, 1.0, GROUND_SIZE)
	col.shape = box
	col.position = Vector3(0, -0.5, 0)
	body.add_child(col)

	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(GROUND_SIZE, 1.0, GROUND_SIZE)
	mesh.mesh = bm
	mesh.position = Vector3(0, -0.5, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.31, 0.27)  # dirt-ish
	mesh.material_override = mat
	body.add_child(mesh)

	# faint reference grid (both axes) so motion + distance read clearly
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.46, 0.43, 0.38)
	for i in range(-20, 21):
		for axis in range(2):
			var line := MeshInstance3D.new()
			var lb := BoxMesh.new()
			lb.size = Vector3(0.2, 0.02, GROUND_SIZE) if axis == 0 else Vector3(GROUND_SIZE, 0.02, 0.2)
			line.mesh = lb
			line.position = Vector3(i * 100.0, 0.02, 0) if axis == 0 else Vector3(0, 0.02, i * 100.0)
			line.material_override = gmat
			body.add_child(line)

	add_child(body)

func _build_car() -> RigidBody3D:
	var VehicleScript := load("res://scripts/vehicle_m2.gd")
	var car: RigidBody3D = VehicleScript.new()
	car.name = "Vehicle"
	add_child(car)
	return car

func _build_cameras(car: Node3D) -> void:
	_chase_cam = load("res://scripts/chase_camera.gd").new()
	_chase_cam.name = "ChaseCamera"
	add_child(_chase_cam)
	_chase_cam.target = car

	# Both interior cams are rigidly bolted to the car (roll/pitch with it) for speed feel.
	# Cockpit: driver's eye (LHD -> left), higher seat, close to the wheel/dash.
	_cockpit_cam = Camera3D.new()
	_cockpit_cam.name = "CockpitCamera"
	_cockpit_cam.position = Vector3(-0.35, 0.72, 0.16)
	_cockpit_cam.rotation_degrees = Vector3(-10, 0, 0)
	_cockpit_cam.fov = 85.0
	car.add_child(_cockpit_cam)
	_rigid_cams.append({"cam": _cockpit_cam, "base": _cockpit_cam.rotation})

	# Dash: centred, on top of the dashboard looking forward (for a future gauge readout).
	_dash_cam = Camera3D.new()
	_dash_cam.name = "DashCamera"
	_dash_cam.position = Vector3(-0.35, 0.82, 0.08)
	_dash_cam.rotation_degrees = Vector3(-12, 0, 0)
	_dash_cam.fov = 86.0
	car.add_child(_dash_cam)
	_rigid_cams.append({"cam": _dash_cam, "base": _dash_cam.rotation})

	# Bonnet: sits at the base of the windshield looking forward OVER the hood + scoop.
	_hood_cam = Camera3D.new()
	_hood_cam.name = "HoodCamera"
	_hood_cam.position = Vector3(0.0, 0.62, -0.85)
	_hood_cam.rotation_degrees = Vector3(-10, 0, 0)
	_hood_cam.fov = 104.0
	car.add_child(_hood_cam)
	_rigid_cams.append({"cam": _hood_cam, "base": _hood_cam.rotation})

	_apply_camera()

func _apply_camera() -> void:
	_chase_cam.current = (_cam_mode == 0)
	_cockpit_cam.current = (_cam_mode == 1)
	_dash_cam.current = (_cam_mode == 2)
	_hood_cam.current = (_cam_mode == 3)
	_apply_mirror()
	if _status_layer != null:
		_status_layer.visible = not (_cam_mode == 1 or _cam_mode == 2)   # outside views only

func _apply_mirror() -> void:
	# The mirror is a SECOND render of the whole world, so it must only run while it is on screen.
	# A SubViewportContainer does switch its viewport off when hidden, but only at the moment its
	# own visibility CHANGES - and at startup the viewport is added to a container that is already
	# hidden, so no change ever arrives and the mirror kept rendering behind the chase camera until
	# the driver had cycled through the cockpit view once. Measured 2026-11-17 on the legacy map in
	# chase view: 343 of 1,213 draw calls and 1.25 M of 2.55 M primitives a frame were the unseen
	# mirror. Stating the mode here, every time the view changes, makes it not depend on that.
	var on := (_cam_mode == 1 or _cam_mode == 2)                 # mirror in cockpit + dash views
	if _mirror_layer != null:
		_mirror_layer.visible = on
	if _mirror_vp != null:
		_mirror_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED

func _process(delta: float) -> void:
	_cull_legacy_map()
	if _car != null and _env != null:
		var hi := bool(_car.get("gfx_high"))
		if hi != _env.ssao_enabled:
			_apply_gfx(hi)
		var mode := int(_car.get("gfx_shadow_mode")) if _car.get("gfx_shadow_mode") != null else 0
		if mode != _shadow_mode:
			_shadow_mode = mode
			_apply_shadow_mode()
		var sm := clampf(float(_car.get("gfx_shadow_m")), 20.0, 400.0)
		if _shadow_mode == 1:
			sm = clampf(float(_car.get("gfx_shadow_live_m")), 10.0, sm)
		if not is_equal_approx(sm, _sun.directional_shadow_max_distance):
			_sun.directional_shadow_max_distance = sm
	_update_car_shadow()
	if Input.is_action_just_pressed("camera_toggle"):
		_cam_mode = (_cam_mode + 1) % 4
		_apply_camera()
	_update_look(delta)

## THE LEGACY MAP IS NOT DRAWN FROM DEEP INSIDE SHAKEDOWN. Measured 2026-11-18 (cloud probe, chase
## cam 300 m into the stage, noon): of 589k primitives a frame, the legacy map 3 km away was 222k and
## 88 draw calls - more than the whole stage ground (78k) - for a map hidden behind haze and forest.
## Hiding it keeps its collision (visible is render-only) and it reappears before the car can reach
## it. Kept visible within LEGACY_SHOW_DEPTH of the stage's edge, where the start clearing could
## still look back toward it.
## FELL OUT OF THE WORLD (2026-11-18, sagi: fell through at ~155 km/h, mid-stage on unbroken road -
## cause still open, see CHANGELOG). Also, off the sides of the 44 m transition pad past the stage
## edge there is nothing but the collider-less backdrop. Nothing ever caught a car that went through
## - it fell forever. The net that covers every such hole, and logs WHERE it happened: a car that has
## dropped VOID_DROP_M below the last height it stood at without free-falling is put back on the
## nearest road. Nothing on a generated road falls 25 m, so this cannot fire in normal driving.
const VOID_DROP_M := 25.0
var _safe_y := 0.0
var _safe_p := Vector3.ZERO
var _have_safe := false

func _void_rescue() -> void:
	var p: Vector3 = _car.global_position
	var vy: float = _car.linear_velocity.y
	if not _have_safe or vy > -4.0:
		# not falling: this is a height the car can legitimately be at
		if not _have_safe or vy > -1.0:
			_safe_y = p.y
			_safe_p = p
			_have_safe = true
		return
	if p.y > _safe_y - VOID_DROP_M:
		return
	print("VOID RESCUE: car fell from (%.1f, %.1f, %.1f) to y=%.1f at %.0f km/h" % [_safe_p.x, _safe_y, _safe_p.z, p.y, _car.linear_velocity.length() * 3.6])
	_have_safe = false
	if _stage_area != null and StageDef.depth_in(_stage_area._gb, _safe_p.x, _safe_p.z) > -1500.0:
		var cl = _stage_area.gen.centreline
		var np: Dictionary = cl.nearest_point(_safe_p.x, _safe_p.z)
		var s: float = clampf(float(np["s"]), 0.0, cl.length() - 10.0)
		var pt: Dictionary = cl.point_at(s)
		var pos: Vector3 = pt["pos"]
		var h: Vector2 = pt["heading"]
		if StageDef.depth_in(_stage_area._gb, pos.x, pos.z) > 0.0:
			var o := Vector3(pos.x, _stage_area.height_at(pos.x, pos.z) + 1.8, pos.z)
			_car.respawn()   # resets engine, tyres and damage exactly as [R] does...
			_car.global_transform = Transform3D(Basis(), o).looking_at(o + Vector3(h.x, 0.0, h.y), Vector3.UP)
			return           # ...but on the road where you went off, not at the start
	_car.respawn()

const LEGACY_SHOW_DEPTH := 150.0
var _legacy_shown := true
func _cull_legacy_map() -> void:
	if _car == null or _stage_area == null or _stage == null:
		return
	var p: Vector3 = _car.global_position
	var show: bool = StageDef.depth_in(_stage_area._gb, p.x, p.z) < LEGACY_SHOW_DEPTH
	if show == _legacy_shown:
		return
	_legacy_shown = show
	(_stage as Node3D).visible = show
	var patch := get_node_or_null("ReactivePatch") as Node3D
	if patch != null:
		patch.visible = show

func _axis_shaped(v: float) -> float:
	# deadzone, then rescale what is left to the full 0..1 range so the view starts moving
	# smoothly from zero instead of jumping the moment the stick clears the deadzone
	if absf(v) < LOOK_DEADZONE:
		return 0.0
	return signf(v) * (absf(v) - LOOK_DEADZONE) / (1.0 - LOOK_DEADZONE)

func _update_look(delta: float) -> void:
	if Input.is_action_just_pressed("look_back"):
		_look_back = not _look_back
	var rx := 0.0
	var ry := 0.0
	var pads := Input.get_connected_joypads()
	if pads.size() > 0:
		rx = _axis_shaped(Input.get_joy_axis(pads[0], JOY_AXIS_RIGHT_X))
		ry = _axis_shaped(Input.get_joy_axis(pads[0], JOY_AXIS_RIGHT_Y))
	# third person orbits the car; the interior views turn in place like a head
	var yaw_max := deg_to_rad(LOOK_YAW_CHASE if _cam_mode == 0 else LOOK_YAW_INTERIOR)
	var yaw_t := -rx * yaw_max + (PI if _look_back else 0.0)
	var pitch_t := -ry * deg_to_rad(LOOK_PITCH_MAX)
	var k := clampf(delta / LOOK_TAU, 0.0, 1.0)
	_look_yaw = lerp_angle(_look_yaw, yaw_t, k)      # lerp_angle takes the short way round the flip
	_look_pitch = lerpf(_look_pitch, pitch_t, k)
	for entry in _rigid_cams:
		var cam: Camera3D = entry["cam"]
		var base: Vector3 = entry["base"]
		# default Euler order is YXZ, i.e. yaw then pitch - the FPS convention. The cams are
		# children of the car, so the yaw axis is the car's own up and the view rolls with it.
		cam.rotation = Vector3(base.x + _look_pitch, _look_yaw, base.z)
	if _chase_cam != null:
		_chase_cam.orbit_yaw = _look_yaw
		_chase_cam.orbit_pitch = _look_pitch

func _build_hud(car: Node3D) -> CanvasLayer:
	var hud: CanvasLayer = load("res://scripts/hud.gd").new()
	hud.name = "HUD"
	add_child(hud)
	hud.car = car
	return hud

func _build_rearview(_car_ref: Node3D) -> void:
	# In-cockpit rear-view mirror, drawn as a 2D SubViewportContainer overlay (the container path
	# renders reliably; a ViewportTexture on a 3D quad renders black on Metal). Top-centre of the
	# screen, mirror-flipped, and shown only in cockpit view.
	_mirror_layer = CanvasLayer.new()
	_mirror_layer.name = "MirrorOverlay"
	_mirror_layer.visible = (_cam_mode == 1 or _cam_mode == 2)
	add_child(_mirror_layer)
	# dark mirror housing behind the glass
	var frame := ColorRect.new()
	frame.color = Color(0.03, 0.03, 0.04)
	frame.anchor_left = 0.5; frame.anchor_right = 0.5
	frame.offset_left = -86; frame.offset_right = 286       # shifted right of centre
	frame.offset_top = 8; frame.offset_bottom = 120
	_mirror_layer.add_child(frame)
	var cont := SubViewportContainer.new()
	cont.stretch = true
	cont.anchor_left = 0.5; cont.anchor_right = 0.5
	cont.offset_left = -80; cont.offset_right = 280         # 360 wide, shifted right
	cont.offset_top = 12; cont.offset_bottom = 116          # 104 tall
	cont.pivot_offset = Vector2(180, 52)                    # flip around the panel centre...
	cont.scale = Vector2(-1, 1)                             # ...so the mirror image is left-right reversed
	_mirror_layer.add_child(cont)
	var vp := SubViewport.new()
	vp.own_world_3d = false                                 # share the MAIN world (real geometry)
	cont.add_child(vp)
	_mirror_vp = vp
	_rear_cam = Camera3D.new()
	_rear_cam.fov = 72.0
	_rear_cam.far = 600.0
	vp.add_child(_rear_cam)
	_rear_cam.make_current()
	_apply_mirror()                                         # off unless an interior view is up
