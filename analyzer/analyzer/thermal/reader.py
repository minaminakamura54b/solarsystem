"""サーモ画像ファイルから float32 の温度行列（℃）を得る。拡張子で読み込み方法を選ぶ。"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from analyzer.errors import AnalyzerError
from analyzer.thermal import dji_reader, npy_reader, tiff_reader


@dataclass(frozen=True)
class ThermalImage:
    temps: np.ndarray  # shape (height, width)、float32、単位 ℃
    source: str  # 読み込み方法（dji_rjpeg / npy / tiff）


def read_thermal(path: str | Path, dji_thermal_params: dict | None = None) -> ThermalImage:
    path = Path(path)
    if not path.is_file():
        raise AnalyzerError("file_not_found", f"サーモ画像が見つかりません: {path}")

    suffix = path.suffix.lower()
    if suffix == ".npy":
        temps = npy_reader.read(path)
        source = "npy"
    elif suffix in (".tif", ".tiff"):
        temps = tiff_reader.read(path)
        source = "tiff"
    else:
        temps = dji_reader.read(path, dji_thermal_params or {})
        source = "dji_rjpeg"

    temps = np.asarray(temps, dtype=np.float32)
    if temps.ndim != 2 or temps.size == 0:
        raise AnalyzerError("invalid_temperature_matrix", "温度行列が2次元ではありません")
    if not np.isfinite(temps).all():
        raise AnalyzerError("invalid_temperature_matrix", "温度行列に数値でない値が含まれています")
    return ThermalImage(temps=temps, source=source)
