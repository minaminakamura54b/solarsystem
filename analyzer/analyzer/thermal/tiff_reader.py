"""radiometric TIFF から温度行列を得る（将来の他機種用。未対応）。"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from analyzer.errors import NoTemperatureDataError


def read(path: Path) -> np.ndarray:
    # TODO(将来): 対応する機種の radiometric TIFF の仕様を確認してから実装する
    raise NoTemperatureDataError("unsupported_format", f"radiometric TIFF にはまだ対応していません: {path.name}")
