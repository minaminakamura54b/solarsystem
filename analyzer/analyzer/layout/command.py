"""build-block-map コマンド: 点検の画像から架台の地図（候補）を作る（docs/LAYOUT_OVERLAY_DESIGN.md の A-3）。

入力（--input の JSON）:
  {"origin": {"lat": .., "lng": ..},            発電所の原点（地図の座標の基準）
   "facing_azimuth_deg": 180,                   パネルの向く方位（上端・下端の区別に使う）
   "module": {"width_m": .., "length_m": ..},   任意。列数・段数の目安に使う
   "images": [{"id": "..", "thermal": "path",
               "camera": {"lat", "lng", "abs_alt_m", "image_up_azimuth_deg", "ifov_mrad", "width", "height"},
               "lrf_target_abs_alt_m": .. | null}]}
読めない画像は飛ばして理由を残す。地図を作れなければ needs_review（理由付き）。作った地図は「候補」で、人が確認してから使う。
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from pydantic import BaseModel, ConfigDict, Field

from analyzer import ANALYZER_VERSION, SCHEMA_VERSION
from analyzer.errors import AnalyzerError
from analyzer.geo.projection import LocalFrame, NadirCamera
from analyzer.layout.block_map import ImageObs, build_block_map
from analyzer.layout.edges import detect_edges
from analyzer.params import AnalyzerParams
from analyzer.thermal.reader import read_thermal

LAYOUT_PARAMS_PATH = Path(__file__).parent.parent / "config" / "layout_params.json"


class CameraIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    lat: float
    lng: float
    abs_alt_m: float
    image_up_azimuth_deg: float
    ifov_mrad: float = Field(gt=0)
    width: int = Field(gt=0)
    height: int = Field(gt=0)


class ImageIn(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: str
    thermal: str
    camera: CameraIn
    lrf_target_abs_alt_m: float | None = None


class Origin(BaseModel):
    lat: float
    lng: float


class BlockMapInput(BaseModel):
    model_config = ConfigDict(extra="ignore")
    origin: Origin
    facing_azimuth_deg: float = 180.0
    module: dict | None = None
    images: list[ImageIn]


def load_layout_params(path: str | None = None) -> dict:
    data = json.loads(Path(path or LAYOUT_PARAMS_PATH).read_text(encoding="utf-8"))
    data.pop("_comment", None)
    return data


def run_build_block_map(input_path: str, layout_params_path: str | None = None, params_path: str | None = None) -> dict:
    try:
        spec = BlockMapInput.model_validate_json(Path(input_path).read_text(encoding="utf-8"))
        layout_params = load_layout_params(layout_params_path)
        params = AnalyzerParams.load(params_path)
    except (ValueError, OSError) as e:
        raise AnalyzerError("invalid_input", f"入力が不正です: {e}") from e

    frame = LocalFrame(spec.origin.lat, spec.origin.lng)
    observations, skipped = [], []
    lrf_heights = [i.camera.abs_alt_m - i.lrf_target_abs_alt_m for i in spec.images if i.lrf_target_abs_alt_m is not None]
    typical_height = float(np.median(lrf_heights)) if lrf_heights else None
    for img in spec.images:
        try:
            thermal = read_thermal(img.thermal, params.dji_thermal_params, params.dji_irp_timeout_seconds)
        except AnalyzerError as e:
            skipped.append({"id": img.id, "reason": e.reason, "message": e.message})
            continue
        e, n = frame.to_local(img.camera.lat, img.camera.lng)
        cam = NadirCamera(e, n, img.camera.abs_alt_m, img.camera.image_up_azimuth_deg, img.camera.ifov_mrad / 1000,
                          img.camera.width, img.camera.height)
        if thermal.temps.shape != (img.camera.height, img.camera.width):
            skipped.append({"id": img.id, "reason": "size_mismatch", "message": "温度行列の大きさが画像の大きさと違います"})
            continue
        height = (img.camera.abs_alt_m - img.lrf_target_abs_alt_m) if img.lrf_target_abs_alt_m is not None else typical_height
        if height is None or height <= 0 or not math.isfinite(height):
            skipped.append({"id": img.id, "reason": "no_height", "message": "対地の高さが分からないため架台の大きさを確かめられません"})
            continue
        edges = detect_edges(thermal.temps, cam.ifov_rad * height, layout_params)
        observations.append(ImageObs(img.id, cam, edges, img.lrf_target_abs_alt_m))

    result = build_block_map(observations, frame, layout_params, spec.facing_azimuth_deg, spec.module)
    return {"schema_version": SCHEMA_VERSION, "analyzer_version": ANALYZER_VERSION, "status": "proposed",
            "review_reason": None, "message": None, "skipped": skipped, **result}
