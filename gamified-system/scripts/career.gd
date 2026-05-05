extends Node2D

var current_match: int = 1
var ai_difficulty: float = 0.35

func start_next_match() -> void:
	current_match += 1
	ai_difficulty = min(ai_difficulty + 0.05, 1.0)
