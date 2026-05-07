extends Node2D

var total_xp: int = 0

const RANKS: Array[Dictionary] = [
	{"xp": 15000, "rank": "World Class"},
	{"xp": 10000, "rank": "Elite"},
	{"xp": 7000, "rank": "Pro Circuit"},
	{"xp": 4500, "rank": "Semi-Pro"},
	{"xp": 2500, "rank": "Regional"},
	{"xp": 1200, "rank": "Club Player"},
	{"xp": 500, "rank": "Amateur II"},
	{"xp": 0, "rank": "Amateur I"},
]

func add_xp(amount: int) -> void:
	total_xp += max(amount, 0)

func get_rank() -> String:
	for entry in RANKS:
		if total_xp >= int(entry["xp"]):
			return String(entry["rank"])
	return "Amateur I"
