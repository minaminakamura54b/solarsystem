"""DJI Thermal SDK（dji_irp）の呼び出し（Phase S の記録どおり）。

本物の SDK は使わず、dji_irp と同じ引数を受け取って同じ形式で出力する偽のスクリプトで確かめる
（標準出力に画像の大きさ、-o に float32 の生データ）。
"""

import json
import stat
import sys

import numpy as np
import pytest

from analyzer.errors import EXIT_NO_TEMPERATURE
from analyzer.thermal import dji_reader
from tests.fixtures.make_synthetic import make_scene

FAKE_IRP = '''#!{python}
import os, sys
import numpy as np
args = sys.argv[1:]
with open(os.environ["FAKE_IRP_ARGS"], "w") as f:
    f.write("\\n".join(args))
mode = os.environ.get("FAKE_IRP_MODE", "ok")
if mode == "fail":
    print("ERROR: call dirp_set_measurement_params failed")
    sys.exit(253)
temps = np.load(os.environ["FAKE_IRP_NPY"]).astype("<f4")
height, width = temps.shape
if mode != "no_resolution":
    print("R-JPEG resolution size")
    print("      image  width : %d" % width)
    print("      image height : %d" % height)
if mode == "short":
    temps = temps[:-1]
temps.tofile(args[args.index("-o") + 1])
'''


@pytest.fixture
def fake_sdk(tmp_path, monkeypatch):
    """偽の dji_irp。戻り値は (dji_irp のパス, 渡された引数を読む関数, 環境変数)。"""
    irp = tmp_path / "sdk" / "dji_irp"
    irp.parent.mkdir()
    irp.write_text(FAKE_IRP.format(python=sys.executable))
    irp.chmod(irp.stat().st_mode | stat.S_IXUSR)
    scene = make_scene()
    npy = tmp_path / "scene.npy"
    np.save(npy, scene.temps)
    args_file = tmp_path / "irp_args.txt"
    env = {"FAKE_IRP_ARGS": str(args_file), "FAKE_IRP_NPY": str(npy), "DJI_IRP_PATH": str(irp)}
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    return irp, lambda: args_file.read_text().split("\n"), env, scene


@pytest.fixture
def rjpeg(tmp_path):
    path = tmp_path / "DJI_0001_T.JPG"
    path.write_bytes(dji_reader.JPEG_MAGIC + b"\x00" * 64)
    return path


def test_温度行列をfloat32で読み_大きさは標準出力で確かめる(fake_sdk, rjpeg):
    irp, read_args, _, scene = fake_sdk

    temps = dji_reader.read(rjpeg, {}, irp_path=str(irp))

    assert temps.shape == scene.temps.shape
    np.testing.assert_allclose(temps, scene.temps.astype(np.float32))
    args = read_args()
    assert args[:4] == ["-s", str(rjpeg), "-a", "measure"]
    assert args[args.index("--measurefmt") + 1] == "float32"


def test_測定パラメータは値がある項目だけをSDKのオプションで渡す(fake_sdk, rjpeg):
    irp, read_args, _, _ = fake_sdk

    dji_reader.read(rjpeg, {"emissivity": None, "reflected_temperature_c": 12.5, "humidity_percent": 55,
                            "distance_m": 41.486}, irp_path=str(irp))

    args = read_args()
    assert "--emissivity" not in args
    assert args[args.index("--reflection") + 1] == "12.5"
    assert args[args.index("--humidity") + 1] == "55"
    assert args[args.index("--distance") + 1] == "41.486"


@pytest.mark.parametrize(("mode", "message"), [
    ("fail", "終了コード 253"),
    ("short", "大きさが合いません"),
    ("no_resolution", "画像の大きさを読み取れませんでした"),
])
def test_SDKの失敗は温度データなしとして終了コード2(fake_sdk, rjpeg, monkeypatch, mode, message):
    irp, *_ = fake_sdk
    monkeypatch.setenv("FAKE_IRP_MODE", mode)

    with pytest.raises(dji_reader.NoTemperatureDataError) as e:
        dji_reader.read(rjpeg, {}, irp_path=str(irp))

    assert e.value.exit_code == EXIT_NO_TEMPERATURE
    assert e.value.reason == "sdk_failed"
    assert message in e.value.message


def test_SDKの失敗の理由にはERRORの行を含める(fake_sdk, rjpeg, monkeypatch):
    irp, *_ = fake_sdk
    monkeypatch.setenv("FAKE_IRP_MODE", "fail")

    with pytest.raises(dji_reader.NoTemperatureDataError) as e:
        dji_reader.read(rjpeg, {}, irp_path=str(irp))

    assert "dirp_set_measurement_params failed" in e.value.message


def test_SDKが時間内に終わらなければsdk_failed(tmp_path, rjpeg):
    irp = tmp_path / "slow_irp"
    irp.write_text("#!/bin/sh\nsleep 5\n")
    irp.chmod(irp.stat().st_mode | stat.S_IXUSR)

    with pytest.raises(dji_reader.NoTemperatureDataError) as e:
        dji_reader.read(rjpeg, {}, irp_path=str(irp), timeout_seconds=0.5)

    assert e.value.reason == "sdk_failed"


def test_CLIはR_JPEGをSDKで読んで解析する(cli, fake_sdk, rjpeg):
    _, read_args, env, scene = fake_sdk

    code, data, _ = cli("analyze", "--thermal", str(rjpeg), "--panel-grids", json.dumps(scene.grids),
                        "--measurement", '{"distance_m": 40}', env=env)

    assert code == 0, data
    assert data["image"]["source"] == "dji_rjpeg"
    assert read_args()[read_args().index("--distance") + 1] == "40"


@pytest.mark.parametrize("payload", [
    {"distance_m": 500}, {"emissivity": 0.05}, {"reflected_temperature_c": 150}, {"humidity_percent": 0.5},
])
def test_CLIはSDKの受け付ける範囲外の測定パラメータならSDKを呼ばずに終了コード1(cli, fake_sdk, rjpeg, tmp_path, payload):
    _, _, env, scene = fake_sdk

    code, data, _ = cli("analyze", "--thermal", str(rjpeg), "--panel-grids", json.dumps(scene.grids),
                        "--measurement", json.dumps(payload), env=env)

    assert code == 1
    assert data["review_reason"] == "invalid_input"
    assert "範囲外" in data["message"]
    assert not (tmp_path / "irp_args.txt").exists()


def test_CLIのpropose_gridもSDKで読む(cli, fake_sdk, rjpeg):
    _, _, env, _ = fake_sdk

    code, data, _ = cli("propose-grid", "--thermal", str(rjpeg), env=env)

    assert code in (0, 3)
    assert data["image"]["source"] == "dji_rjpeg"
