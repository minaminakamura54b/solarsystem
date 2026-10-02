"""DJI の R-JPEG から温度行列を得る（DJI Thermal SDK の dji_irp を subprocess で呼ぶ）。

Phase S（DJI SDK の検証）が未実施のため、この段階では次の2つだけを実装している:
  - JPEG でなければ終了コード 2（no_radiometric）
  - SDK（環境変数 DJI_IRP_PATH の dji_irp）が無ければ終了コード 2（sdk_unavailable）

SDK のオプション名・出力形式・測定パラメータの渡し方は Phase S で確認してから実装する（TODO）。
推測で実装しないこと。温度データを取得できないときに、色から温度を逆算することもしない。
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np

from analyzer.errors import AnalyzerError, NoTemperatureDataError

JPEG_MAGIC = b"\xff\xd8\xff"


def read(path: Path, thermal_params: dict, irp_path: str | None = None) -> np.ndarray:
    if not is_jpeg(path):
        raise NoTemperatureDataError("no_radiometric", f"JPEG（R-JPEG）ではありません: {path.name}")

    irp = irp_path if irp_path is not None else os.environ.get("DJI_IRP_PATH")
    if not irp or not Path(irp).is_file() or not os.access(irp, os.X_OK):
        raise NoTemperatureDataError(
            "sdk_unavailable",
            "DJI Thermal SDK（dji_irp）が見つからないため、温度データを取得できません。環境変数 DJI_IRP_PATH を設定してください",
        )

    # TODO(Phase S): dji_irp を subprocess で呼び、float32 の温度行列を得る。
    #   - オプション名（測定モード・出力形式など）と出力ファイルの形式は、SDK 同梱の README と
    #     docs/spike_dji_sdk.md（Phase S の記録）で確認してから実装する
    #   - thermal_params（放射率・反射温度・湿度・距離）の渡し方も Phase S で決める
    #   - SDK が失敗した・R-JPEG でなかった場合は NoTemperatureDataError（終了コード 2）にする
    raise AnalyzerError(
        "dji_reader_not_implemented",
        "DJI Thermal SDK の呼び出しは Phase S（SDK の検証）の後に実装します（TODO）",
    )


def is_jpeg(path: Path) -> bool:
    with path.open("rb") as f:
        return f.read(3) == JPEG_MAGIC
