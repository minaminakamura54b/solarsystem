"""基準温度（docs/IMPROVEMENT_PLAN.md 5.6）。

基準温度 = 除外パネルと異常候補パネルを除いた「正常パネル」の t_mean の中央値。
1. 除外されていない全パネルの t_mean の中央値 m と mad_used を出す
2. m ± baseline_mad_k × mad_used を外れるパネルを除く
3. 残りの中央値を基準温度にする
4. 残りが max(baseline_min_panels, ceil(パネル数 × baseline_min_ratio)) 未満なら基準不足

baseline_method = position_trend（2026-11-08 ユーザー承認。暫定）のときは、各パネルの基準温度を「画像内の位置での温度の傾向」にする:
1. パネルの t_mean を、画像内の中心の位置（縦 y・横 x。0〜1）の平面 a·y + b·x + c で表す（位置の広がりが足りなければ
   縦の直線 a·y + c、それも足りなければ定数＝中央値）
2. 傾向からの差の中央値と mad_used（下限 baseline_mad_floor_c）を出し、baseline_mad_k × mad_used を外れるパネルを除いて当てはめ直す（最大 5 回）
3. 残ったパネルが必要数未満なら基準不足（従来と同じ数え方）
見る角度によって画像の下側ほど温かく見える影響（2026-11 の実データで確認）を除くため。
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
    per_panel: dict[int, float] | None = None  # position_trend のときの、パネルごとの基準温度
    trend: dict | None = None

    def temp_for(self, index: int) -> float:
        if self.per_panel is not None:
            return self.per_panel[index]
        return self.temp

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


def compute_baseline_trend(panel_means: dict[int, float], positions: dict[int, tuple[float, float]], params: DetectionParams) -> Baseline:
    """position_trend の基準温度。positions は パネル番号 → (x, y)（画像の大きさで割った中心の位置）"""
    n = len(panel_means)
    required = max(params.baseline_min_panels, math.ceil(n * params.baseline_min_ratio))
    if n == 0:
        return Baseline(temp=None, panel_count=0, required_count=required, mad=None, mad_used=None)

    idx = list(panel_means)
    v = np.array([panel_means[i] for i in idx], dtype=np.float64)
    x = np.array([positions[i][0] for i in idx], dtype=np.float64)
    y = np.array([positions[i][1] for i in idx], dtype=np.float64)
    keep = np.ones(n, dtype=bool)
    spread = params.trend_min_spread
    shape, coef, pred, mad, used = "constant", [float(np.median(v))], np.full(n, float(np.median(v))), 0.0, params.baseline_mad_floor_c
    for _ in range(5):
        if keep.sum() >= 8 and np.ptp(y[keep]) > spread and np.ptp(x[keep]) > spread:
            a = np.c_[y, x, np.ones(n)]
            shape, coef = "plane", np.linalg.lstsq(a[keep], v[keep], rcond=None)[0].tolist()
            pred = a @ np.array(coef)
        elif keep.sum() >= 6 and np.ptp(y[keep]) > spread:
            shape, coef = "line", np.polyfit(y[keep], v[keep], 1).tolist()
            pred = coef[0] * y + coef[1]
        else:
            shape, coef = "constant", [float(np.median(v[keep]))]
            pred = np.full(n, coef[0])
        residual = v - pred
        mad, used = mad_used(residual[keep], params.baseline_mad_floor_c)
        center = float(np.median(residual[keep]))
        new_keep = np.abs(residual - center) <= params.baseline_mad_k * used
        if (new_keep == keep).all() or new_keep.sum() == 0:
            break
        keep = new_keep

    kept = {i for i, k in zip(idx, keep) if k}
    if len(kept) < required:
        return Baseline(temp=None, panel_count=len(kept), required_count=required, mad=mad, mad_used=used, baseline_indices=kept)
    per_panel = {i: float(p) for i, p in zip(idx, pred)}
    names = {"plane": ["y", "x", "c"], "line": ["y", "c"], "constant": ["c"]}[shape]
    return Baseline(
        temp=float(np.median(list(per_panel.values()))), panel_count=len(kept), required_count=required, mad=mad, mad_used=used,
        baseline_indices=kept, per_panel=per_panel, trend={"shape": shape, "coefficients": dict(zip(names, [round(c, 4) for c in coef]))},
    )
