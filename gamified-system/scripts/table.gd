extends Node2D

@onready var cue_ball: RigidBody2D = $ball_1

var aiming: bool = false
var aim_line: Line2D = null
var waiting_for_ball_stop: bool = false
var _api_bridge: Node = null
var _overlay: Node2D = null

const MAX_DRAG_DISTANCE: float = 500.0
const MAX_IMPULSE: float = 2500.0

func _ready() -> void:
	_api_bridge = preload("res://scripts/api_bridge.gd").new()
	_api_bridge.name = "ApiBridge"
	_api_bridge.recommendation_ready.connect(_on_recommendation_ready)
	add_child(_api_bridge)

	_overlay = preload("res://scripts/overlay.gd").new()
	_overlay.name = "Overlay"
	add_child(_overlay)

func _physics_process(_delta: float) -> void:
	if waiting_for_ball_stop:
		var ball_velocity_length: float = cue_ball.linear_velocity.length()
		if ball_velocity_length < 5.0:
			waiting_for_ball_stop = false
			# wait for 5 sec
			await get_tree().create_timer(1.0).timeout

			_request_ml_recommendation()

func _request_ml_recommendation() -> void:
	if _api_bridge == null:
		return

	var cue_pos: Vector2 = cue_ball.global_position
	var target_pos: Vector2 = _find_nearest_red_ball_position(cue_pos)
	_api_bridge.request_recommendation(cue_pos, target_pos)

func _find_nearest_red_ball_position(from_position: Vector2) -> Vector2:
	var nearest_ball_position: Vector2 = from_position
	var nearest_distance: float = INF

	for i in range(2, 17):
		var ball_node: Node = get_node_or_null("ball_" + str(i))
		if ball_node != null and ball_node is RigidBody2D:
			var ball: RigidBody2D = ball_node
			var distance: float = from_position.distance_to(ball.global_position)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest_ball_position = ball.global_position

	return nearest_ball_position

func _on_recommendation_ready(recommended_shot: Dictionary) -> void:
	if _overlay == null:
		return
	_overlay.apply_recommendation(recommended_shot)

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
	waiting_for_ball_stop = true

func _clear_aim_line() -> void:
	if aim_line != null and is_instance_valid(aim_line):
		aim_line.queue_free()
	aim_line = null
