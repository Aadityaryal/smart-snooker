extends Node2D

var score: int = 0
var streak: int = 0

func record_attempt(success: bool) -> void:
	if success:
		streak += 1
		score += 10 + streak
	else:
		streak = 0
