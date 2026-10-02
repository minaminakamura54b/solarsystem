"""NumPy の .npy（float32 の温度行列、単位 ℃）を読む。合成データによるテストと開発用。"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from analyzer.errors import AnalyzerError


def read(path: Path) -> np.ndarray:
    try:
        return np.load(path, allow_pickle=False)
    except (ValueError, OSError) as e:
        raise AnalyzerError("invalid_temperature_matrix", f".npy を読めません: {e}") from e
