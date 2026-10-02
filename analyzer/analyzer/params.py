"""解析パラメータ（analyzer/config/default_params.json）の読み込み。"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_PARAMS_PATH = Path(__file__).parent / "config" / "default_params.json"


@dataclass(frozen=True)
class AnalyzerParams:
    hotspot_max_area_ratio: float
    hotspot_max_aspect: float
    module_wide_min_area_ratio: float
    glare_max_area_ratio: float
    edge_margin_px: float
    edge_min_inside_ratio: float
    segmenter_min_panels: int
    segmenter_min_area_ratio: float
    segmenter_min_rectangularity: float
    segmenter_size_tolerance: float
    dji_thermal_params: dict = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path | None = None) -> "AnalyzerParams":
        data = json.loads(Path(path or DEFAULT_PARAMS_PATH).read_text(encoding="utf-8"))
        names = cls.__dataclass_fields__.keys()
        missing = [n for n in names if n not in data]
        if missing:
            raise ValueError(f"解析パラメータに未設定の項目があります: {', '.join(missing)}")
        return cls(**{n: data[n] for n in names})
