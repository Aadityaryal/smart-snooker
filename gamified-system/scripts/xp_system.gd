extends Node

var xp: int = 0
var rank: int = 1

func add_xp(amount: int) -> void:
	xp += max(amount, 0)
	_update_rank()

func _update_rank() -> void:
	while xp >= rank * 100:
		rank += 1
