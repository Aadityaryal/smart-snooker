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
var is_rl_mode: bool = false
var _just_shot: bool = false

const MAX_DRAG_DISTANCE: float = 500.0
const MAX_IMPULSE: float = 1500.0
const STOP_THRESHOLD: float = 2.0 # Velocity threshold for balls to be considered stopped

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

	# Add pocket areas dynamically
	var pocket_radius: float = 30.0
	var pocket_positions: Array[Vector2] = [
		Vector2(20, 20), Vector2(1260, 20),
		Vector2(20, 700), Vector2(1260, 700),
		Vector2(640, 20), Vector2(640, 700)
	]

	for pos in pocket_positions:
		var area = Area2D.new()
		var shape = CollisionShape2D.new()
		var circle = CircleShape2D.new()
		circle.radius = pocket_radius
		shape.shape = circle
		area.add_child(shape)
		area.position = pos
		area.body_entered.connect(_on_pocket_entered)
		add_child(area)

	# Adjusted Physics for "Snooker Cloth" feel
	# Increased linear_damp (rolling resistance) and adjusted material friction
	var ball_material = PhysicsMaterial.new()
	ball_material.friction = 0.6  # Higher surface friction
	ball_material.bounce = 0.7  # Snooker balls have lower bounce than billiards

	for ball_node in _get_table_balls():
		ball_node.physics_material_override = ball_material
		ball_node.linear_damp = 1.2  # Higher damping to stop the "ice" effect
		ball_node.angular_damp = 1.0 # Added angular damping to manage spin
		ball_node.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE

func _get_table_balls() -> Array:
	var balls: Array = []
	for child in get_children():
		if child is RigidBody2D and not child.is_queued_for_deletion():
			balls.append(child)
	return balls

func get_environment_state() -> Dictionary:
	var state = {
		"cue_ball": {
			"pos": cue_ball.global_position,
			"vel": cue_ball.linear_velocity
		},
		"other_balls": {}
	}
	for ball_node in _get_table_balls():
		if ball_node != cue_ball:
			state["other_balls"][ball_node.name] = {
				"pos": ball_node.global_position,
				"vel": ball_node.linear_velocity,
				"potted": _potted_balls.has(ball_node.name)
			}
	return state

func reset_game() -> void:
	# Reset game state
	_potted_balls.clear()
	_player_turn = true
	_ball_potted_this_turn = false
	waiting_for_ball_stop = false

	# Reset career scores
	_career.player_score = 0
	_career.ai_score = 0

	# Reposition all balls to initial spots
	for ball_node in _get_table_balls():
		if not is_instance_valid(ball_node):
			continue
		ball_node.linear_velocity = Vector2.ZERO
		ball_node.angular_velocity = 0

	# Update HUD
	var hud_root = _career.get_node_or_null("HUD/Control/VBoxContainer")
	if hud_root:
		_career.update_hud(
			hud_root.get_node_or_null("RankLabel"),
			hud_root.get_node_or_null("ScoreLabel"),
			hud_root.get_node_or_null("XpLabel"),
			hud_root.get_node_or_null("XpProgressBar"),
			_xp_system, 0, 0
		)

# Revised: Apply shot with spin (English)
# offset: Vector2 representing where the cue hits the ball (-1 to 1 range for x/y)
func execute_agent_shot(impulse_vector: Vector2, offset: Vector2 = Vector2.ZERO) -> void:
	if waiting_for_ball_stop:
		return

	# Offset determines the "English" (spin)
	# Normalizing offset to be within ball radius
	var contact_point = offset * 5.0
	cue_ball.apply_impulse(contact_point, impulse_vector)

	waiting_for_ball_stop = true
	_just_shot = true
	_ball_potted_this_turn = false

func get_game_result() -> Dictionary:
	var result = {
		"is_over": false,
		"winner": null,
		"reward": 0
	}

	# Logic: If someone hit 75 points
	if _career.player_score >= 75:
		result.is_over = true
		result.winner = "player"
		result.reward = 100
	elif _career.ai_score >= 75:
		result.is_over = true
		result.winner = "ai"
		result.reward = -100

	return result

func _on_pocket_entered(body: Node) -> void:
	if body is RigidBody2D and not _potted_balls.has(body.name):
		_potted_balls.append(body.name)
		body.queue_free()
		_ball_potted_this_turn = true
		if _career != null:
			if _player_turn:
				_career.add_player_points(1)
			else:
				_career.add_ai_points(1)

			var hud_root = _career.get_node_or_null("HUD/Control/VBoxContainer")
			if hud_root:
				_career.update_hud(
					hud_root.get_node_or_null("RankLabel"),
					hud_root.get_node_or_null("ScoreLabel"),
					hud_root.get_node_or_null("XpLabel"),
					hud_root.get_node_or_null("XpProgressBar"),
					_xp_system, _career.player_score, _career.ai_score
				)

func _physics_process(_delta: float) -> void:
	if _ai_shot_pending:
		_ai_shot_timer -= _delta
		if _ai_shot_timer <= 0.0:
			_ai_shot_pending = false
			_ball_potted_this_turn = false
			_ai_take_visual_shot()
			waiting_for_ball_stop = true
			_just_shot = true

	if waiting_for_ball_stop:
		if _just_shot:
			_just_shot = false
			return
		# First issue: The turn-end check must loop over ALL physics children on the table.
		# Only proceed if all balls have stopped moving below the threshold.
		if _are_all_balls_stopped():
			# All balls have stopped, so we can unset the flag.
			waiting_for_ball_stop = false

			# Wait for 1 second to ensure full stability and allow players to observe the outcome.
			# Bypass this wait entirely when in RL mode to allow fast simulation.
			if not is_rl_mode:
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
					_ai_shot_timer = 0.0 if is_rl_mode else 1.0
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
	# Second issue: The shot input handler must check this same all-balls-stopped condition
	# before allowing any new shot.
	# If 'waiting_for_ball_stop' is true, it means balls are currently in motion
	# or we are in the post-shot 1-second delay. In either case, no new shot should be allowed.
	if waiting_for_ball_stop:
		return # Ignore all input if balls are moving or turn logic is processing.

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# Added a check for whose turn it is to prevent player from shooting during AI's turn
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
	_just_shot = true
	_ball_potted_this_turn = false

func _clear_aim_line() -> void:
	if aim_line != null and is_instance_valid(aim_line):
		aim_line.queue_free()
	aim_line = null

## First issue: Helper function to check if all physics children (balls) are stopped.
func _are_all_balls_stopped() -> bool:
	for ball_node in _get_table_balls():
		# Check the linear velocity length against the defined STOP_THRESHOLD.
		if ball_node.linear_velocity.length() >= STOP_THRESHOLD:
			return false # At least one ball is still moving fast.

	# Only freeze and sleep all balls once the entire table has slowed below the threshold.
	for ball_node in _get_table_balls():
		ball_node.linear_velocity = Vector2.ZERO
		ball_node.angular_velocity = 0.0
		ball_node.sleeping = true
	return true


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
	_just_shot = true


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
