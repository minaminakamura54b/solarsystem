"""パネルごとの温度の特徴量。"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class PanelStats:
    t_max: float
    t_mean: float
    t_min: float
    p95: float
    median: float


def panel_stats(patch: np.ndarray) -> PanelStats:
    values = patch.astype(np.float64).ravel()
    return PanelStats(
        t_max=float(values.max()),
        t_mean=float(values.mean()),
        t_min=float(values.min()),
        p95=float(np.percentile(values, 95)),
        median=float(np.median(values)),
    )
