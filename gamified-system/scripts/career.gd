extends Node2D

var current_match: int = 1
var ai_difficulty: float = 0.35
var player_score: int = 0
var ai_score: int = 0
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

const POCKET_NAMES: Array[String] = ["top_left", "top_middle", "top_right", "bottom_left", "bottom_middle", "bottom_right"]
const MAX_XP: int = 15000

func _ready() -> void:
	rng.randomize()
	_ensure_hud_nodes()

func start_next_match() -> void:
	current_match += 1
	ai_difficulty = min(ai_difficulty + 0.05, 1.0)

func add_player_points(n: int) -> void:
	player_score += max(n, 0)

func add_ai_points(n: int) -> void:
	ai_score += max(n, 0)

func update_hud(xp_system: Node, player_score_value: int, ai_score_value: int) -> void:
	var hud_layer: CanvasLayer = _ensure_hud_nodes()

	var rank_label: Label = hud_layer.get_node_or_null("RankLabel")
	var score_label: Label = hud_layer.get_node_or_null("ScoreLabel")
	var xp_label: Label = hud_layer.get_node_or_null("XpLabel")
	var xp_bar: ProgressBar = hud_layer.get_node_or_null("XpProgressBar")

	var rank_text: String = "Amateur I"
	var total_xp: int = 0

	if xp_system != null:
		if xp_system.has_method("get_rank"):
			rank_text = str(xp_system.call("get_rank"))
		if "total_xp" in xp_system:
			total_xp = int(xp_system.get("total_xp"))

	if rank_label != null:
		rank_label.text = "Rank: " + rank_text

	if score_label != null:
		score_label.text = "Player: " + str(player_score_value) + " — AI: " + str(ai_score_value)

	if xp_label != null:
		xp_label.text = "XP: " + str(total_xp)

	if xp_bar != null:
		xp_bar.max_value = MAX_XP
		xp_bar.value = min(total_xp, MAX_XP)

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

func _ensure_hud_nodes() -> CanvasLayer:
	var hud_layer: CanvasLayer = get_node_or_null("HUD")
	if hud_layer != null:
		return hud_layer

	hud_layer = CanvasLayer.new()
	hud_layer.name = "HUD"
	add_child(hud_layer)

	var panel_root: Control = Control.new()
	panel_root.name = "Control"
	panel_root.anchors_preset = Control.PRESET_TOP_LEFT
	panel_root.offset_left = 20.0
	panel_root.offset_top = 20.0
	panel_root.offset_right = 420.0
	panel_root.offset_bottom = 200.0
	hud_layer.add_child(panel_root)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	panel_root.add_child(vbox)

	var rank_label: Label = Label.new()
	rank_label.name = "RankLabel"
	rank_label.text = "Rank: Amateur I"
	vbox.add_child(rank_label)

	var score_label: Label = Label.new()
	score_label.name = "ScoreLabel"
	score_label.text = "Player: 0 — AI: 0"
	vbox.add_child(score_label)

	var xp_label: Label = Label.new()
	xp_label.name = "XpLabel"
	xp_label.text = "XP: 0"
	vbox.add_child(xp_label)

	var xp_bar: ProgressBar = ProgressBar.new()
	xp_bar.name = "XpProgressBar"
	xp_bar.max_value = MAX_XP
	xp_bar.value = 0
	xp_bar.custom_minimum_size = Vector2(360.0, 24.0)
	vbox.add_child(xp_bar)

	return hud_layer
