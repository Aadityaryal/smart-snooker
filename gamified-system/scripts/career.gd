extends Node2D

var current_match: int = 1
var ai_difficulty: float = 0.35
var player_score: int = 0
var ai_score: int = 0
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

const POCKET_NAMES: Array[String] = ["top_left", "top_middle", "top_right", "bottom_left", "bottom_middle", "bottom_right"]

func _ready() -> void:
	rng.randomize()

func start_next_match() -> void:
	current_match += 1
	ai_difficulty = min(ai_difficulty + 0.05, 1.0)

func add_player_points(n: int) -> void:
	player_score += max(n, 0)

func add_ai_points(n: int) -> void:
	ai_score += max(n, 0)

func check_frame_winner() -> String:
	if player_score >= 75 and player_score >= ai_score:
		return "player"
	if ai_score >= 75 and ai_score > player_score:
		return "ai"
	if player_score >= 75:
		return "player"
	if ai_score >= 75:
		return "ai"
	return ""

func ai_take_shot(ball_positions: Array) -> Dictionary:
	var target_ball: Variant = null
	if not ball_positions.is_empty():
		target_ball = ball_positions[rng.randi_range(0, ball_positions.size() - 1)]

	var pocket: String = POCKET_NAMES[rng.randi_range(0, POCKET_NAMES.size() - 1)]
	var shot_score: int = rng.randi_range(40, 90)
	add_ai_points(rng.randi_range(1, 7))

	return {
		"target_ball": target_ball,
		"pocket": pocket,
		"shot_score": shot_score,
	}
