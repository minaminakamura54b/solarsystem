"""パネル内の高温領域の検出と、出力の条件（mild）の扱い（docs/IMPROVEMENT_PLAN.md 5.6）。"""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from analyzer.analysis.baseline import mad_used
from analyzer.contract import ANOMALY_TYPES, DetectionParams, IrradianceInput, RulesInput


@dataclass
class HotRegion:
    mask: np.ndarray  # パッチと同じ形の bool
    area_px: int
    bbox: tuple[int, int, int, int]  # パッチ上の x1, y1, x2, y2（両端を含む）

    @property
    def width(self) -> int:
        return self.bbox[2] - self.bbox[0] + 1

    @property
    def height(self) -> int:
        return self.bbox[3] - self.bbox[1] + 1

    @property
    def aspect(self) -> float:
        return max(self.width, self.height) / min(self.width, self.height)


def hot_regions(patch: np.ndarray, params: DetectionParams) -> tuple[list[HotRegion], float]:
    """パネル中央値 + max(panel_mad_k × mad_used, min_region_offset_c) を超える連結領域（8近傍）。"""
    values = patch.astype(np.float64)
    median = float(np.median(values))
    _, used = mad_used(values.ravel(), params.panel_mad_floor_c)
    threshold = median + max(params.panel_mad_k * used, params.min_region_offset_c)

    mask = (values > threshold).astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    regions = []
    for label in range(1, count):
        x, y, w, h, area = stats[label]
        regions.append(HotRegion(mask=labels == label, area_px=int(area), bbox=(int(x), int(y), int(x + w - 1), int(y + h - 1))))
    return regions, threshold


@dataclass(frozen=True)
class MildThresholds:
    """種類ごとの検出の最小値（mild）を、生の温度差（℃）に換算したもの。

    正規化ΔT（ΔT × 1000 / POA 日射量）≥ normalized_mild は、ΔT ≥ normalized_mild × 日射量 / 1000 と同じ。
    POA の日射量が無いときは raw_mild をそのまま使う。
    """

    raw_equivalent: dict[str, float]
    basis: str  # normalized / raw
    irradiance_value: float | None

    @classmethod
    def build(cls, rules: RulesInput, irradiance: IrradianceInput) -> "MildThresholds":
        if irradiance.normalizable:
            factor = irradiance.value / 1000.0
            values = {t: rules.rule_for(t).normalized_mild * factor for t in ANOMALY_TYPES}
            return cls(values, "normalized", irradiance.value)
        return cls({t: rules.rule_for(t).raw_mild for t in ANOMALY_TYPES}, "raw", None)

    def __getitem__(self, anomaly_type: str) -> float:
        return self.raw_equivalent[anomaly_type]

    def normalized(self, delta_t: float) -> float | None:
        if self.basis != "normalized":
            return None
        return delta_t * 1000.0 / self.irradiance_value
