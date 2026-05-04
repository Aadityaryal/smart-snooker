extends Node2D

@onready var cue_ball: RigidBody2D = $ball_1

var aiming: bool = false
var aim_line: Line2D = null

const MAX_DRAG_DISTANCE: float = 500.0
const MAX_IMPULSE: float = 2000.0

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			aiming = true
			_ensure_aim_line()
			_update_aim_line(event.position)
		else:
			if aiming:
				_shoot_cue_ball(event.position)
				_clear_aim_line()
				aiming = false
	elif event is InputEventMouseMotion and aiming:
		_ensure_aim_line()
		_update_aim_line(event.position)

func _ensure_aim_line() -> void:
	if aim_line != null and is_instance_valid(aim_line):
		return

	aim_line = get_node_or_null("AimLine")
	if aim_line == null:
		aim_line = Line2D.new()
		aim_line.name = "AimLine"
		aim_line.width = 3.0
		aim_line.default_color = Color(0.0, 1.0, 0.0)
		aim_line.z_index = 1000
		aim_line.top_level = true
		add_child(aim_line)

	aim_line.visible = true

func _update_aim_line(mouse_position: Vector2) -> void:
	aim_line.clear_points()
	aim_line.add_point(cue_ball.global_position)
	aim_line.add_point(mouse_position)

func _shoot_cue_ball(mouse_position: Vector2) -> void:
	var direction: Vector2 = mouse_position - cue_ball.global_position
	var distance: float = direction.length()
	if distance <= 0.001:
		return

	var impulse_strength: float = (min(distance, MAX_DRAG_DISTANCE) / MAX_DRAG_DISTANCE) * MAX_IMPULSE
	cue_ball.apply_central_impulse(direction.normalized() * impulse_strength)

func _clear_aim_line() -> void:
	if aim_line != null and is_instance_valid(aim_line):
		aim_line.queue_free()
	aim_line = null
