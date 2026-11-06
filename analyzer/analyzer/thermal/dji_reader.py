"""DJI の R-JPEG から温度行列を得る（DJI Thermal SDK の dji_irp を subprocess で呼ぶ）。

呼び出し方は Phase S（docs/spike_dji_sdk.md の 3〜5 章）で SDK 同梱の README・ヘルプ・サンプルのソースと
実画像（M4T）で確かめたもの:

  dji_irp -s <R-JPEG> -a measure -o <出力> --measurefmt float32 [--emissivity E] [--reflection R] [--humidity H] [--distance D]

- 出力はヘッダーなしの float32（℃、リトルエンディアン、行優先）。大きさは dji_irp が標準出力に出す
  「image  width : W」「image height : H」で確かめる
- 測定パラメータは値がある項目だけ渡す。渡さない項目は R-JPEG に記録された値のまま（SDK が読む）
- 失敗（終了コード 0 以外・出力が無い・大きさが合わない）は NoTemperatureDataError（終了コード 2）にする。
  温度データを取得できないときに、色から温度を逆算することはしない
- 呼び出すときの環境変数は sdk.subprocess_env（LD_LIBRARY_PATH に SDK のライブラリの場所を足す）
"""

from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path

import numpy as np

from analyzer.errors import NoTemperatureDataError
from analyzer.thermal import sdk

JPEG_MAGIC = b"\xff\xd8\xff"

# 測定パラメータの名前 → dji_irp のオプション（Phase S で確認）
OPTIONS = {
    "emissivity": "--emissivity",
    "reflected_temperature_c": "--reflection",
    "humidity_percent": "--humidity",
    "distance_m": "--distance",
}

WIDTH_PATTERN = re.compile(r"image\s+width\s*:\s*(\d+)")
HEIGHT_PATTERN = re.compile(r"image\s+height\s*:\s*(\d+)")


def read(path: Path, thermal_params: dict, irp_path: str | None = None, timeout_seconds: float = 60) -> np.ndarray:
    if not is_jpeg(path):
        raise NoTemperatureDataError("no_radiometric", f"JPEG（R-JPEG）ではありません: {path.name}")

    irp = irp_path if irp_path is not None else sdk.irp_path()
    if not sdk.available(irp):
        raise NoTemperatureDataError(
            "sdk_unavailable",
            "DJI Thermal SDK（dji_irp）が見つからないため、温度データを取得できません。環境変数 DJI_IRP_PATH を設定してください",
        )

    with tempfile.TemporaryDirectory(prefix="dji_irp") as tmpdir:
        out = Path(tmpdir) / "measure.raw"
        command = [irp, "-s", str(path), "-a", "measure", "-o", str(out), "--measurefmt", "float32", *options(thermal_params)]
        try:
            completed = subprocess.run(
                command, env=sdk.subprocess_env(irp), capture_output=True, text=True, errors="replace",
                timeout=timeout_seconds, check=False,
            )
        except subprocess.TimeoutExpired as e:
            raise NoTemperatureDataError("sdk_failed", f"DJI Thermal SDK が {timeout_seconds:g} 秒以内に終わりませんでした") from e
        except OSError as e:
            raise NoTemperatureDataError("sdk_failed", f"DJI Thermal SDK を起動できませんでした: {e}") from e

        if completed.returncode != 0 or not out.is_file():
            raise NoTemperatureDataError(
                "sdk_failed",
                f"DJI Thermal SDK で温度データを取得できませんでした（終了コード {completed.returncode}）: {last_error(completed.stdout)}",
            )
        width, height = resolution(completed.stdout)
        temps = np.fromfile(out, dtype="<f4")

    if temps.size != width * height:
        raise NoTemperatureDataError(
            "sdk_failed", f"DJI Thermal SDK の出力の大きさが合いません（{temps.size} 画素 / 期待 {width}×{height}）",
        )
    return temps.reshape(height, width)


def options(thermal_params: dict) -> list[str]:
    """値がある測定パラメータだけを dji_irp のオプションにする（null は渡さない）。"""
    args: list[str] = []
    for key, option in OPTIONS.items():
        value = thermal_params.get(key)
        if value is not None:
            args += [option, f"{float(value):g}"]
    return args


def resolution(stdout: str) -> tuple[int, int]:
    width = WIDTH_PATTERN.search(stdout)
    height = HEIGHT_PATTERN.search(stdout)
    if not width or not height:
        raise NoTemperatureDataError("sdk_failed", "DJI Thermal SDK の出力から画像の大きさを読み取れませんでした")
    return int(width.group(1)), int(height.group(1))


def last_error(stdout: str) -> str:
    errors = [line.strip() for line in stdout.splitlines() if "ERROR" in line]
    return errors[-1] if errors else "理由は出力されていません"


def is_jpeg(path: Path) -> bool:
    with path.open("rb") as f:
        return f.read(3) == JPEG_MAGIC
