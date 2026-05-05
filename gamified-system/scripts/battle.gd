extends Node2D

var turn_budget: int = 3

func consume_action() -> bool:
	if turn_budget <= 0:
		return false
	turn_budget -= 1
	return true

func reset_turn_budget(new_budget: int = 3) -> void:
	turn_budget = max(new_budget, 0)
