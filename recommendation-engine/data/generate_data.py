from pathlib import Path

import numpy as np
import pandas as pd


def generate_shot_data(num_rows: int = 10_000, seed: int = 42) -> pd.DataFrame:
	rng = np.random.default_rng(seed)

	cue_x = rng.uniform(0, 2.84, num_rows)
	cue_y = rng.uniform(0, 1.42, num_rows)
	target_x = rng.uniform(0, 2.84, num_rows)
	target_y = rng.uniform(0, 1.42, num_rows)
	pocket_x = rng.choice([0.0, 1.42, 2.84], num_rows) + rng.uniform(-0.04, 0.04, num_rows)
	pocket_y = rng.choice([0.0, 1.42], num_rows) + rng.uniform(-0.04, 0.04, num_rows)

	distance_cue_to_target = np.sqrt((cue_x - target_x) ** 2 + (cue_y - target_y) ** 2)
	distance_target_to_pocket = np.sqrt((target_x - pocket_x) ** 2 + (target_y - pocket_y) ** 2)

	angle_to_pocket = np.degrees(np.arctan2(pocket_y - target_y, pocket_x - target_x))
	cut_angle = np.abs(np.degrees(np.arctan2(target_y - cue_y, target_x - cue_x)) - angle_to_pocket)
	cut_angle = np.mod(cut_angle, 180.0)
	cut_angle = np.where(cut_angle > 90.0, 180.0 - cut_angle, cut_angle)

	num_balls_in_path = rng.integers(0, 4, num_rows)
	ball_colour = rng.choice(
		["red", "yellow", "green", "brown", "blue", "pink", "black"],
		num_rows,
	)
	is_snookered = rng.random(num_rows) < (0.15 + 0.15 * (num_balls_in_path > 0))

	shot_score = (
		100
		- 18.0 * distance_cue_to_target
		- 14.0 * distance_target_to_pocket
		- 0.9 * cut_angle
		- 10.0 * num_balls_in_path
		- 12.0 * is_snookered.astype(float)
		+ rng.normal(0, 6, num_rows)
	)
	shot_score = np.clip(shot_score, 0, 100)

	is_recommended = shot_score >= 62

	shot_type = np.where(
		cut_angle < 12,
		"straight",
		np.where(
			cut_angle < 35,
			"thin_cut",
			np.where(cut_angle < 60, "medium_cut", "heavy_cut"),
		),
	)

	return pd.DataFrame(
		{
			"cue_x": cue_x,
			"cue_y": cue_y,
			"target_x": target_x,
			"target_y": target_y,
			"pocket_x": pocket_x,
			"pocket_y": pocket_y,
			"angle_to_pocket": angle_to_pocket,
			"cut_angle": cut_angle,
			"distance_cue_to_target": distance_cue_to_target,
			"distance_target_to_pocket": distance_target_to_pocket,
			"num_balls_in_path": num_balls_in_path,
			"ball_colour": ball_colour,
			"is_snookered": is_snookered,
			"shot_score": shot_score,
			"is_recommended": is_recommended,
			"shot_type": shot_type,
		}
	)


def main() -> None:
	output_path = Path(__file__).resolve().parent / "shots.csv"
	data = generate_shot_data()
	data.to_csv(output_path, index=False)
	print(f"Saved {len(data)} rows to {output_path}")


if __name__ == "__main__":
	main()
