# res://scripts/career.gd
# ─────────────────────────────────────────────────────────────────────────────
# Tracks match state, scores, and HUD.  Created dynamically by table.gd.
#
# FIX L6 — check_frame_winner() had two dead conditions that could never be
#           reached (proofs in inline comments below).  Removed.
# CLEAN   — update_hud() now reads XP from Globals directly instead of going
#           through the xp_system Node parameter.  The parameter is kept so
#           the calling signature in table.gd doesn't need to change.
# CLEAN   — removed the debug print() statements that printed on every HUD
#           refresh (they flooded the console during normal gameplay).
# ─────────────────────────────────────────────────────────────────────────────
extends Node2D

var current_match: int  = 1
var ai_difficulty: float = 0.35
var player_score:  int  = 0
var ai_score:      int  = 0
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

const POCKET_NAMES: Array[String] = [
	"top_left", "top_middle", "top_right",
	"bottom_left", "bottom_middle", "bottom_right",
]
const MAX_XP: int = 15000   # mirrors Globals.RANKS[0]["xp"]


# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	rng.randomize()
	_ensure_hud_nodes()


# ─────────────────────────────────────────────────────────────────────────────
# Match progression
# ─────────────────────────────────────────────────────────────────────────────
func start_next_match() -> void:
	current_match += 1
	ai_difficulty = min(ai_difficulty + 0.05, 1.0)


# ─────────────────────────────────────────────────────────────────────────────
# Scoring
# ─────────────────────────────────────────────────────────────────────────────
func add_player_points(n: int) -> void:
	player_score += max(n, 0)

func add_ai_points(n: int) -> void:
	ai_score += max(n, 0)


# ─────────────────────────────────────────────────────────────────────────────
# HUD refresh — xp_system param kept for backward compatibility; XP now read
# from Globals so the shared pool is always shown correctly.
# ─────────────────────────────────────────────────────────────────────────────
func update_hud(
	rank_label:        Label,
	score_label:       Label,
	xp_label:          Label,
	xp_bar:            ProgressBar,
	_xp_system:        Node,          # unused; kept so callers don't need updating
	player_score_value: int,
	ai_score_value:    int
) -> void:
	# Read from Globals — single shared XP pool (fixes L2 at the display layer too)
	var rank_text: String = Globals.get_rank()
	var total_xp:  int    = Globals.total_xp

	if rank_label != null:
		rank_label.text = "Rank: " + rank_text

	if score_label != null:
		score_label.text = "%s: %d — AI: %d" % [Globals.player_name, player_score_value, ai_score_value]

	if xp_label != null:
		xp_label.text = "XP: %d" % total_xp

	if xp_bar != null:
		xp_bar.max_value = MAX_XP
		xp_bar.value     = min(total_xp, MAX_XP)


# ─────────────────────────────────────────────────────────────────────────────
# Frame winner check
#
# FIX L6 — old code had 4 conditions; conditions 3 and 4 were dead code:
#
#   After cond 1 fails: NOT (player >= 75 AND player >= ai)
#   After cond 2 fails: NOT (ai >= 75 AND ai > player)
#   For cond 3 to fire:  player >= 75  must be true.
#     → Since cond 1 failed, player >= 75 but ai > player, so ai > 75 too.
#     → But then cond 2 (ai >= 75 AND ai > player) would have returned "ai".
#     → Contradiction. Cond 3 is unreachable.  ✓
#   For cond 4 to fire:  ai >= 75  must be true (conds 1–3 all failed).
#     → If ai >= 75 and cond 2 failed, then NOT (ai > player), so player >= ai.
#     → But then player >= ai >= 75, so cond 1 (player >= 75 AND player >= ai) fires.
#     → Contradiction. Cond 4 is unreachable.  ✓
# ─────────────────────────────────────────────────────────────────────────────
func check_frame_winner() -> String:
	if player_score >= 75 and player_score >= ai_score:
		return "player"
	if ai_score >= 75 and ai_score > player_score:
		return "ai"
	# Conditions 3 and 4 removed — mathematically unreachable (see proof above)
	return ""


# ─────────────────────────────────────────────────────────────────────────────
# Rule-based AI shot descriptor (not connected to physics; used for logging)
# ─────────────────────────────────────────────────────────────────────────────
func ai_take_shot(ball_positions: Array) -> Dictionary:
	var target_ball: Variant = null
	if not ball_positions.is_empty():
		target_ball = ball_positions[rng.randi_range(0, ball_positions.size() - 1)]

	var pocket:     String = POCKET_NAMES[rng.randi_range(0, POCKET_NAMES.size() - 1)]
	var shot_score: int    = rng.randi_range(40, 90)
	add_ai_points(rng.randi_range(1, 7))

	return {"target_ball": target_ball, "pocket": pocket, "shot_score": shot_score}


# ─────────────────────────────────────────────────────────────────────────────
# Lazily create HUD nodes if not already in the scene
# ─────────────────────────────────────────────────────────────────────────────
func _ensure_hud_nodes() -> CanvasLayer:
	var hud_layer: CanvasLayer = get_node_or_null("HUD")
	if hud_layer != null:
		return hud_layer

	hud_layer      = CanvasLayer.new()
	hud_layer.name = "HUD"
	add_child(hud_layer)

	var panel_root: Control = Control.new()
	panel_root.name             = "Control"
	panel_root.anchors_preset   = Control.PRESET_TOP_LEFT
	panel_root.offset_left      = 20.0
	panel_root.offset_top       = 20.0
	panel_root.offset_right     = 420.0
	panel_root.offset_bottom    = 200.0
	hud_layer.add_child(panel_root)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.name                         = "VBoxContainer"
	vbox.size_flags_horizontal        = Control.SIZE_EXPAND_FILL
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
	xp_bar.name                = "XpProgressBar"
	xp_bar.max_value           = MAX_XP
	xp_bar.value               = 0
	xp_bar.custom_minimum_size = Vector2(360.0, 24.0)
	vbox.add_child(xp_bar)

	return hud_layer
