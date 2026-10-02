"""基準温度（docs/IMPROVEMENT_PLAN.md 5.6）。

基準温度 = 除外パネルと異常候補パネルを除いた「正常パネル」の t_mean の中央値。
1. 除外されていない全パネルの t_mean の中央値 m と mad_used を出す
2. m ± baseline_mad_k × mad_used を外れるパネルを除く
3. 残りの中央値を基準温度にする
4. 残りが max(baseline_min_panels, ceil(パネル数 × baseline_min_ratio)) 未満なら基準不足
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from analyzer.contract import DetectionParams

MAD_TO_SIGMA = 1.4826  # 正規分布の標準偏差相当への換算係数


def mad_used(values: np.ndarray, floor: float) -> tuple[float, float]:
    """(MAD, 下限を適用した mad_used) を返す。温度がほぼ均一だと MAD ≈ 0 になるため下限を設ける。"""
    median = float(np.median(values))
    mad = float(np.median(np.abs(values - median)))
    return mad, max(mad * MAD_TO_SIGMA, floor)


@dataclass
class Baseline:
    temp: float | None  # None = 基準不足
    panel_count: int
    required_count: int
    mad: float | None
    mad_used: float | None
    baseline_indices: set[int] = field(default_factory=set)

    @property
    def sufficient(self) -> bool:
        return self.temp is not None


def compute_baseline(panel_means: dict[int, float], params: DetectionParams) -> Baseline:
    n = len(panel_means)
    required = max(params.baseline_min_panels, math.ceil(n * params.baseline_min_ratio))
    if n == 0:
        return Baseline(temp=None, panel_count=0, required_count=required, mad=None, mad_used=None)

    values = np.array(list(panel_means.values()), dtype=np.float64)
    median = float(np.median(values))
    mad, used = mad_used(values, params.baseline_mad_floor_c)
    limit = params.baseline_mad_k * used
    kept = {index for index, value in panel_means.items() if abs(value - median) <= limit}

    temp = float(np.median([panel_means[i] for i in kept])) if len(kept) >= required else None
    return Baseline(temp=temp, panel_count=len(kept), required_count=required, mad=mad, mad_used=used, baseline_indices=kept)
