"""画像側の品質指標（温度レンジ・ブレ）。解析の判定には使わず、出力に記録するだけ。"""

from __future__ import annotations

import cv2
import numpy as np


def temperature_range(temps: np.ndarray) -> tuple[float, float]:
    return float(np.min(temps)), float(np.max(temps))


def blur_score(temps: np.ndarray) -> float:
    """温度行列のラプラシアンの分散（℃²）。値が小さいほどぼやけている。基準値は Phase S 以降に実画像で決める。"""
    return float(cv2.Laplacian(temps.astype(np.float32), cv2.CV_32F).var())
