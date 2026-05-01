from pathlib import Path

import joblib
import pandas as pd
from fastapi import FastAPI
from pydantic import BaseModel


class RecommendRequest(BaseModel):
	cue_x: float
	cue_y: float
	target_x: float
	target_y: float
	pocket_x: float
	pocket_y: float
	angle_to_pocket: float
	cut_angle: float
	distance_cue_to_target: float
	distance_target_to_pocket: float
	num_balls_in_path: int
	ball_colour: str
	is_snookered: bool


feature_columns = [
	"cue_x",
	"cue_y",
	"target_x",
	"target_y",
	"pocket_x",
	"pocket_y",
	"angle_to_pocket",
	"cut_angle",
	"distance_cue_to_target",
	"distance_target_to_pocket",
	"num_balls_in_path",
	"ball_colour",
	"is_snookered",
]

model_path = Path(__file__).resolve().parent.parent / "models" / "shot_model.pkl"
model = None


app = FastAPI()


@app.on_event("startup")
async def load_model():
	global model
	model = joblib.load(model_path)


@app.post("/recommend")
def recommend_shot(payload: RecommendRequest):
	payload_dict = payload.model_dump()
	X = pd.DataFrame([[payload_dict[col] for col in feature_columns]], columns=feature_columns)
	prediction = model.predict(X)[0]
	probabilities = model.predict_proba(X)[0]
	class_index = list(model.named_steps['classifier'].classes_).index(prediction)
	confidence = float(probabilities[class_index] * 100)
	
	return {
		"recommended_shot": {
			"target_ball_id": 1,
			"pocket": "top_left",
			"confidence": confidence,
		},
		"alternatives": [],
	}
