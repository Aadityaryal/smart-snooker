extends Node2D

@onready var cue_ball: RigidBody2D = $ball_1
@onready var http_request: HTTPRequest = _get_or_create_http_request()

var aiming: bool = false
var aim_line: Line2D = null
var waiting_for_ball_stop: bool = false

const MAX_DRAG_DISTANCE: float = 500.0
const MAX_IMPULSE: float = 2500.0

func _ready() -> void:
	http_request.request_completed.connect(_on_request_completed)

func _physics_process(_delta: float) -> void:
	if waiting_for_ball_stop:
		var ball_velocity_length: float = cue_ball.linear_velocity.length()
		if ball_velocity_length < 5.0:
			waiting_for_ball_stop = true
			send_to_ml()

func _get_or_create_http_request() -> HTTPRequest:
	var existing_request: HTTPRequest = get_node_or_null("HTTPRequest")
	if existing_request != null:
		return existing_request

	var new_request: HTTPRequest = HTTPRequest.new()
	new_request.name = "HTTPRequest"
	add_child(new_request)
	return new_request

func send_to_ml() -> void:
	var cue_pos: Vector2 = cue_ball.global_position
	var cue_x_norm: float = cue_pos.x / 1220.0
	var cue_y_norm: float = cue_pos.y / 685.0

	var nearest_ball: RigidBody2D = null
	var nearest_distance: float = INF
	for i in range(2, 17):
		var ball_node: Node = get_node_or_null("ball_" + str(i))
		if ball_node != null and ball_node is RigidBody2D:
			var ball: RigidBody2D = ball_node
			var distance: float = cue_pos.distance_to(ball.global_position)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest_ball = ball

	var target_x_norm: float = 0.5
	var target_y_norm: float = 0.5
	if nearest_ball != null:
		var target_pos: Vector2 = nearest_ball.global_position
		target_x_norm = target_pos.x / 1220.0
		target_y_norm = target_pos.y / 685.0

	var headers: PackedStringArray = ["Content-Type: application/json"]
	var body: String = JSON.stringify({
		"cue_x": cue_x_norm,
		"cue_y": cue_y_norm,
		"target_x": target_x_norm,
		"target_y": target_y_norm,
		"pocket_x": 0.0,
		"pocket_y": 0.0,
		"angle_to_pocket": 0.0,
		"cut_angle": 0.0,
		"distance_cue_to_target": 0.0,
		"distance_target_to_pocket": 0.0,
		"num_balls_in_path": 0,
		"ball_colour": "red",
		"is_snookered": false
	})
	http_request.request("http://127.0.0.1:8000/recommend", headers, HTTPClient.METHOD_POST, body)

func _on_request_completed(_result: int, _response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var response_text: String = body.get_string_from_utf8()
	print(response_text)

	var parsed_response: Variant = JSON.parse_string(response_text)
	if typeof(parsed_response) != TYPE_DICTIONARY:
		return

	var response_data: Dictionary = parsed_response
	if not response_data.has("recommended_shot"):
		return

	var recommended_shot: Variant = response_data["recommended_shot"]
	if typeof(recommended_shot) != TYPE_DICTIONARY:
		return

	var shot_data: Dictionary = recommended_shot
	if shot_data.has("confidence"):
		var confidence: float = float(shot_data["confidence"])
		var confidence_label: Label = _get_or_create_confidence_label()
		confidence_label.text = "Confidence: " + str(confidence) + "%"

	if not shot_data.has("cue_path"):
		return

	var cue_path: Variant = shot_data["cue_path"]
	if typeof(cue_path) != TYPE_ARRAY:
		return

	var shot_overlay: Line2D = _get_or_create_shot_overlay()
	shot_overlay.clear_points()
	for point_data in cue_path:
		if typeof(point_data) != TYPE_ARRAY:
			continue
		var point: Array = point_data
		if point.size() < 2:
			continue
		var point_position: Vector2 = Vector2(float(point[0]) * 1220.0, float(point[1]) * 685.0)
		shot_overlay.add_point(point_position)

func _get_or_create_confidence_label() -> Label:
	var hud_node: Node = get_node_or_null("HUD")
	if hud_node == null:
		hud_node = CanvasLayer.new()
		hud_node.name = "HUD"
		add_child(hud_node)

	var existing_label: Label = hud_node.get_node_or_null("ConfidenceLabel")
	if existing_label != null:
		return existing_label

	var confidence_label: Label = Label.new()
	confidence_label.name = "ConfidenceLabel"
	confidence_label.position = Vector2(20.0, 20.0)
	hud_node.add_child(confidence_label)
	return confidence_label

func _get_or_create_shot_overlay() -> Line2D:
	var existing_overlay: Line2D = get_node_or_null("ShotOverlay")
	if existing_overlay != null:
		return existing_overlay

	var new_overlay: Line2D = Line2D.new()
	new_overlay.name = "ShotOverlay"
	new_overlay.width = 4.0
	new_overlay.default_color = Color(1.0, 0.2, 0.2)
	new_overlay.z_index = 1001
	add_child(new_overlay)
	return new_overlay

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
