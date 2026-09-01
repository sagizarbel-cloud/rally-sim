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
var _status_layer: CanvasLayer    # bottom-right rev/speed/telltales; the OUTSIDE-view cluster
var _cam_mode := 0                # 0 = chase, 1 = cockpit, 2 = dash, 3 = bonnet
var _car                          # the vehicle (untyped so get_wheels() resolves dynamically)
var _stage                        # RallyStage, for the base surface type (skid marks are asphalt-only)
var _sun: DirectionalLight3D      # M10: the sun, cycled by time-of-day
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
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

func _physics_process(delta: float) -> void:
	if _car == null:
		return
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
func _build_environment() -> void:
	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = true
	add_child(_sun)

	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	_sky_mat = ProceduralSkyMaterial.new()
	sky.sky_material = _sky_mat
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)
	_apply_tod(_tod)

func _apply_tod(i: int) -> void:
	var p: Dictionary = TOD[i]
	_sun.rotation_degrees = p["rot"]
	_sun.light_color = p["col"]
	_sun.light_energy = p["energy"]
	_sky_mat.sky_top_color = p["top"]
	_sky_mat.sky_horizon_color = p["horizon"]
	_env.ambient_light_energy = p["ambient"]

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
	if _mirror_layer != null:
		_mirror_layer.visible = (_cam_mode == 1 or _cam_mode == 2)   # mirror in cockpit + dash views
	if _status_layer != null:
		_status_layer.visible = not (_cam_mode == 1 or _cam_mode == 2)   # outside views only

func _process(delta: float) -> void:
	if Input.is_action_just_pressed("camera_toggle"):
		_cam_mode = (_cam_mode + 1) % 4
		_apply_camera()
	_update_look(delta)

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
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = false                                 # share the MAIN world (real geometry)
	cont.add_child(vp)
	_rear_cam = Camera3D.new()
	_rear_cam.fov = 72.0
	_rear_cam.far = 600.0
	vp.add_child(_rear_cam)
	_rear_cam.make_current()
