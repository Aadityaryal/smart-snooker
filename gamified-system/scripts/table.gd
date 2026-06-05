extends Node2D

@onready var cue_ball: RigidBody2D = $ball_1

var aiming: bool = false
var aim_line: Line2D = null
var waiting_for_ball_stop: bool = false
var _player_turn: bool = true
var _ball_potted_this_turn: bool = false
var _ai_shot_timer: float = 0.0
var _ai_shot_pending: bool = false
var _api_bridge: Node = null
var _overlay: Node2D = null
var _career: Node = null
var _xp_system: Node = null
var _potted_balls: Array = []

const MAX_DRAG_DISTANCE: float = 500.0
const MAX_IMPULSE: float = 1500.0

func _ready() -> void:
	_api_bridge = preload("res://scripts/api_bridge.gd").new()
	_api_bridge.name = "ApiBridge"
	_api_bridge.recommendation_ready.connect(_on_recommendation_ready)
	add_child(_api_bridge)

	_overlay = preload("res://scripts/overlay.gd").new()
	_overlay.name = "Overlay"
	add_child(_overlay)

	_career = preload("res://scripts/career.gd").new()
	_career.name = "Career"
	add_child(_career)

	_xp_system = preload("res://scripts/xp_system.gd").new()
	_xp_system.name = "XPSystem"
	add_child(_xp_system)

	var pockets_node = PocketDrawer.new()
	pockets_node.name = "Pockets"
	add_child(pockets_node)

	# Set all ball linear dampening to 2.0
	for ball_node in _get_table_balls():
		ball_node.linear_damp = 2.0
		ball_node.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE

	_career.start_next_match()

func _get_table_balls() -> Array:
	var balls: Array = []
	for child in get_children():
		if child is RigidBody2D:
			balls.append(child)
	return balls

func _physics_process(_delta: float) -> void:
	# Check for potted balls every physics frame
	# Pocket positions inset 40 pixels from corners and top/bottom middle
	var pocket_positions: Array = [
		Vector2(20, 20), # Top left (inset)
		Vector2(1260, 20), # Top right (inset)
		Vector2(20, 700), # Bottom left (inset)
		Vector2(1260, 700), # Bottom right (inset)
		Vector2(640, 20), # Top middle (inset from top)
		Vector2(640, 700), # Bottom middle (inset from bottom)
	]
	var pocket_radius: float = 30.0

	for ball_node in _get_table_balls():
		if _potted_balls.has(ball_node.name):
			continue
		var pos: Vector2 = ball_node.global_position
		for pocket_pos in pocket_positions:
			if pos.distance_to(pocket_pos) <= pocket_radius:
				_potted_balls.append(ball_node.name)
				ball_node.queue_free()
				_ball_potted_this_turn = true
				if _career != null:
					if _player_turn:
						_career.add_player_points(1)
					else:
						_career.add_ai_points(1)
					var rank_label: Label = _career.get_node_or_null("HUD/Control/VBoxContainer/RankLabel")
					var score_label: Label = _career.get_node_or_null("HUD/Control/VBoxContainer/ScoreLabel")
					var xp_label: Label = _career.get_node_or_null("HUD/Control/VBoxContainer/XpLabel")
					var xp_bar: ProgressBar = _career.get_node_or_null("HUD/Control/VBoxContainer/XpProgressBar")
					_career.update_hud(rank_label, score_label, xp_label, xp_bar, _xp_system, _career.player_score, _career.ai_score)
				break

	if _ai_shot_pending:
		_ai_shot_timer -= _delta
		if _ai_shot_timer <= 0.0:
			_ai_shot_pending = false
			_ball_potted_this_turn = false
			_ai_take_visual_shot()
			waiting_for_ball_stop = true

	if waiting_for_ball_stop:
		var ball_velocity_length: float = cue_ball.linear_velocity.length()
		if ball_velocity_length < 2.0:
			waiting_for_ball_stop = false
			# wait for 1 sec
			await get_tree().create_timer(1.0).timeout

			if _player_turn:
				# Player's turn just finished
				if _ball_potted_this_turn:
					# Ball was potted, player shoots again
					_ball_potted_this_turn = false
				else:
					# No ball potted, AI's turn
					_player_turn = false
					_ai_shot_pending = true
					_ai_shot_timer = 1.0
			else:
				# AI's turn just finished, back to player
				_player_turn = true
				_ball_potted_this_turn = false
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

	_career.check_frame_winner()

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
	if distance < 50.0:
		return

	var impulse_strength: float = (min(distance, MAX_DRAG_DISTANCE) / MAX_DRAG_DISTANCE) * MAX_IMPULSE
	var final_impulse: float = min(impulse_strength * 2.0, 4000.0)
	cue_ball.apply_central_impulse(direction.normalized() * final_impulse)
	waiting_for_ball_stop = true
	_ball_potted_this_turn = false

func _clear_aim_line() -> void:
	if aim_line != null and is_instance_valid(aim_line):
		aim_line.queue_free()
	aim_line = null

func _ai_take_visual_shot() -> void:
	var available_balls: Array = []
	for ball_node in _get_table_balls():
		if not _potted_balls.has(ball_node.name):
			available_balls.append(ball_node)

	if available_balls.is_empty():
		return

	var target_ball: RigidBody2D = available_balls[randi() % available_balls.size()]
	var direction: Vector2 = (target_ball.global_position - cue_ball.global_position).normalized()
	var impulse_strength: float = randf_range(2000.0, 5000.0)
	var final_impulse: float = min(impulse_strength * 2.0, 2500.0)
	cue_ball.apply_central_impulse(direction * final_impulse)
	waiting_for_ball_stop = true


class PocketDrawer extends Node2D:
	func _ready() -> void:
		queue_redraw()

	func _draw() -> void:
		var pocket_radius: float = 20.0
		var pocket_color: Color = Color(0.3, 0.15, 0.05, 1.0) # Dark brown

		var pockets: Array[Vector2] = [
			Vector2(40, 40), # Top left (inset)
			Vector2(1240, 40), # Top right (inset)
			Vector2(40, 680), # Bottom left (inset)
			Vector2(1240, 680), # Bottom right (inset)
			Vector2(640, 40), # Top middle (inset from top)
			Vector2(640, 680), # Bottom middle (inset from bottom)
		]

		for pocket_pos in pockets:
			draw_circle(pocket_pos, pocket_radius, pocket_color)
