"""測定パラメータの受け皿と、DJI Thermal SDK の置き場所の確認（2026-10-22。SDK の呼び出し本体は Phase S の後）。"""

import json
import os
import stat
import subprocess
import sys

import pytest
from pydantic import ValidationError

from analyzer.contract import MeasurementInput
from analyzer.thermal import dji_reader, sdk
from tests.conftest import ANALYZER_ROOT
from tests.fixtures.make_synthetic import make_scene

DEFAULTS = {"_comment": "x", "emissivity": None, "reflected_temperature_c": None, "humidity_percent": None, "distance_m": None}


def test_測定パラメータは渡した値だけを既定値に上書きする():
    measurement = MeasurementInput.model_validate_json('{"emissivity": 0.9, "humidity_percent": 55}')

    assert measurement.merged_over(DEFAULTS) == {
        "emissivity": 0.9, "reflected_temperature_c": None, "humidity_percent": 55, "distance_m": None,
    }
    assert MeasurementInput().merged_over({"emissivity": 0.95}) == {"emissivity": 0.95}


@pytest.mark.parametrize("payload", [
    {"emissivity": 0}, {"emissivity": 1.2}, {"humidity_percent": 101}, {"distance_m": 0},
    {"reflected_temperature_c": -300}, {"unknown": 1},
])
def test_ありえない測定パラメータと知らない項目は受け付けない(payload):
    with pytest.raises(ValidationError):
        MeasurementInput.model_validate(payload)


def test_analyzeは不正な測定パラメータなら終了コード1で理由を返す(cli, save_npy):
    scene = make_scene()
    path = save_npy(scene.temps)

    code, data, _ = cli("analyze", "--thermal", str(path), "--panel-grids", json.dumps(scene.grids),
                        "--measurement", '{"emissivity": 2}')

    assert code == 1
    assert data["review_reason"] == "invalid_input"


def test_analyzeは測定パラメータを受け取っても合成データnpyの解析は変わらない(cli, save_npy):
    scene = make_scene().heat_rect(0, 1, 2, 0.4, 0.33, 0.5, 0.5, 15.0)
    path = save_npy(scene.temps)
    base = ["analyze", "--thermal", str(path), "--panel-grids", json.dumps(scene.grids)]

    _, without, _ = cli(*base)
    code, with_params, _ = cli(*base, "--measurement", '{"emissivity": 0.9, "reflected_temperature_c": 5, "distance_m": 30}')

    assert code == 0
    assert with_params["anomalies"] == without["anomalies"]


def test_dji_readerは測定パラメータを受け取り_SDK_が無ければ_sdk_unavailable(tmp_path):
    path = tmp_path / "DJI_0001_T.JPG"
    path.write_bytes(dji_reader.JPEG_MAGIC + b"\x00" * 16)

    with pytest.raises(dji_reader.NoTemperatureDataError) as e:
        dji_reader.read(path, {"emissivity": 0.9}, irp_path="")
    assert e.value.reason == "sdk_unavailable"


def fake_binary(tmp_path, header: bytes, executable=True):
    path = tmp_path / "dji_irp"
    path.write_bytes(header + b"\x00" * 64)
    if executable:
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def elf_header(machine: int) -> bytes:
    # ELF64・リトルエンディアン。e_machine は 18〜19 バイト目
    return b"\x7fELF\x02\x01\x01" + b"\x00" * 11 + machine.to_bytes(2, "little")


def test_check_sdkはDJI_IRP_PATHが無ければ使えないと報告する():
    report = sdk.check({})

    assert report["ok"] is False
    assert "DJI_IRP_PATH" in report["message"]


def test_check_sdkはx86_64のELFで実行権限とライブラリの場所があれば使えると報告する(tmp_path):
    path = fake_binary(tmp_path, elf_header(0x3E))

    report = sdk.check({"DJI_IRP_PATH": str(path)})

    assert report["ok"] is True, report
    assert report["elf_machine"] == "x86_64"
    assert report["library_dirs"] == [str(tmp_path)]


@pytest.mark.parametrize(("header", "executable", "env_extra", "message"), [
    (elf_header(0xB7), True, {}, "x86_64 Linux 向けではありません（aarch64）"),
    (b"#!/bin/sh\n", True, {}, "x86_64 Linux 向けではありません（not_elf）"),
    (elf_header(0x3E), False, {}, "実行権限がありません"),
    (elf_header(0x3E), True, {"DJI_IRP_LIB_DIR": "/nonexistent/lib"}, "ライブラリのディレクトリがありません"),
])
def test_check_sdkは使えない理由を報告する(tmp_path, header, executable, env_extra, message):
    path = fake_binary(tmp_path, header, executable)

    report = sdk.check({"DJI_IRP_PATH": str(path), **env_extra})

    assert report["ok"] is False
    assert message in report["message"]


def test_SDKを呼ぶときはLD_LIBRARY_PATHの先頭にライブラリの場所を足す(tmp_path):
    env = sdk.subprocess_env("/opt/sdk/bin/dji_irp", {"LD_LIBRARY_PATH": "/usr/lib/x", "PATH": "/bin"})
    assert env["LD_LIBRARY_PATH"] == os.pathsep.join(["/opt/sdk/bin", "/usr/lib/x"])
    assert env["PATH"] == "/bin"

    env = sdk.subprocess_env("/opt/sdk/bin/dji_irp", {"DJI_IRP_LIB_DIR": "/opt/sdk/lib"})
    assert env["LD_LIBRARY_PATH"] == "/opt/sdk/lib"


def test_check_sdkコマンドは結果のJSONを標準出力に出し_使えなければ終了コード2():
    proc = subprocess.run([sys.executable, "-m", "analyzer", "check-sdk"], cwd=ANALYZER_ROOT,
                          capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})

    assert proc.returncode == 2
    report = json.loads(proc.stdout)
    assert report["ok"] is False
    assert report["dji_irp_path"] is None
