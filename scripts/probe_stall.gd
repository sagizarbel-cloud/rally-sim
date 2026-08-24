extends Node
## TEMPORARY probe: on DEFAULT settings (auto clutch + anti-stall ON), can the engine die, and if
## it does, is there any way back? Pure physics, so headless is fine.

var _car: Node

func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_car = get_tree().root.find_child("Vehicle", true, false)
	print("STALL settings: manual_clutch=%s  anti_stall=%s  idle_rpm=%.0f  floor=%.0f rpm" % [
		_car.manual_clutch, _car.anti_stall, _car.idle_rpm, _car.idle_rpm * 0.5])

	# --- get rolling in gear so the plates lock ---
	Input.action_press("throttle", 1.0)
	_car._gear = 2
	for i in range(240):
		await get_tree().physics_frame
	_st("rolling in 2nd")

	# --- now stand on the brake, in gear, no throttle: the wheels stop and a locked clutch
	#     drags the crank down with them ---
	Input.action_release("throttle")
	Input.action_press("brake", 1.0)
	for k in range(10):
		for i in range(60):
			await get_tree().physics_frame
		_st("braking %.1fs" % (float(k + 1) * 0.5))
		if _car._engine_rpm < 1.0:
			break
	Input.action_release("brake")

	# --- is there ANY way back? ---
	for i in range(60):
		await get_tree().physics_frame
	_st("brake released, coasting")

	print("STALL --- pressing [I] ignition ---")
	Input.action_press("ignition")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("ignition")
	for i in range(60):
		await get_tree().physics_frame
	_st("after [I]")

	print("STALL --- bump start: shove the car to 12 m/s in gear ---")
	_car.linear_velocity = -_car.global_transform.basis.z * 12.0
	for i in range(120):
		await get_tree().physics_frame
	_st("after bump start attempt")

	print("STALL --- neutral + [I] ---")
	_car._gear = 0
	Input.action_press("ignition")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("ignition")
	for i in range(60):
		await get_tree().physics_frame
	_st("neutral + [I]")
	get_tree().quit()

func _st(tag: String) -> void:
	print("STALL %-28s rpm %7.1f  stalled=%-5s clutch %.2f locked=%-5s gear %d  speed %5.1f km/h  t_comb %6.1f" % [
		tag, _car._engine_rpm, _car._stalled, _car._clutch, _car._clutch_locked, _car._gear,
		_car.linear_velocity.length() * 3.6, _car._t_comb])
