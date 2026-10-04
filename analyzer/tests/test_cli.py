"""CLI の終了コードと出力 JSON（5.2）。python -m analyzer を別プロセスで実行する。"""

import json
import stat

from tests.fixtures.make_synthetic import GridLayout, make_gapped_scene, make_scene


def grids_json(scene):
    return json.dumps(scene.grids)


def test_analyzeはグリッドが無ければ終了コード3(cli, save_npy):
    path = save_npy(make_scene().temps)

    code, data, stderr = cli("analyze", "--thermal", str(path))

    assert code == 3
    assert data["status"] == "needs_review"
    assert data["review_reason"] == "grid_required"
    assert "grid_required" in stderr


def test_analyzeは合成データを解析して終了コード0(cli, save_npy):
    scene = make_scene().heat_rect(0, 1, 2, 0.4, 0.33, 0.5, 0.5, 15.0)
    path = save_npy(scene.temps)

    code, data, _ = cli("analyze", "--thermal", str(path), "--panel-grids", grids_json(scene),
                        "--irradiance", "800", "--irradiance-type", "poa")

    assert code == 0
    assert data["schema_version"] == "2.1"
    assert data["analyzer_version"] == "thermal_rules_v1"
    assert data["status"] == "completed"
    assert data["rule_version"] == "test-initial"
    assert data["image"]["width"] == 640 and data["image"]["source"] == "npy"
    assert len(data["panels"]) == 24
    [anomaly] = data["anomalies"]
    assert anomaly["anomaly_type"] == "hotspot"
    assert "severity" not in anomaly, "解析エンジンは severity を出さない"


def test_analyzeは基準不足なら終了コード4(cli, save_npy):
    scene = make_scene([GridLayout(rows=2, cols=4, x0=100, y0=100)])
    for col in range(4):
        scene.heat_panel(0, 0, col, 3.0)
    scene.heat_panel(0, 1, 0, 3.0)
    path = save_npy(scene.temps)

    code, data, _ = cli("analyze", "--thermal", str(path), "--panel-grids", grids_json(scene))

    assert code == 4
    assert data["review_reason"] == "insufficient_baseline"


def test_JPEGでなければ終了コード2(cli, tmp_path):
    path = tmp_path / "DJI_0001_T.JPG"
    path.write_bytes(b"not a jpeg")

    code, data, _ = cli("analyze", "--thermal", str(path), "--panel-grids", json.dumps(make_scene().grids))

    assert code == 2
    assert data["review_reason"] == "no_radiometric"


def test_DJI_SDKが無ければ終了コード2(cli, tmp_path):
    path = tmp_path / "DJI_0001_T.JPG"
    path.write_bytes(b"\xff\xd8\xff\xe0" + b"\x00" * 100)

    code, data, _ = cli("analyze", "--thermal", str(path), "--panel-grids", json.dumps(make_scene().grids))

    assert code == 2
    assert data["status"] == "needs_review"
    assert data["review_reason"] == "sdk_unavailable"


def test_DJI_SDKがあっても呼び出しは未実装なので終了コード1(tmp_path, monkeypatch):
    from analyzer.errors import AnalyzerError
    from analyzer.thermal import dji_reader

    path = tmp_path / "DJI_0001_T.JPG"
    path.write_bytes(b"\xff\xd8\xff\xe0" + b"\x00" * 100)
    fake_sdk = tmp_path / "dji_irp"
    fake_sdk.write_text("#!/bin/sh\nexit 0\n")
    fake_sdk.chmod(fake_sdk.stat().st_mode | stat.S_IEXEC)

    try:
        dji_reader.read(path, {}, irp_path=str(fake_sdk))
    except AnalyzerError as e:
        assert e.exit_code == 1
        assert e.reason == "dji_reader_not_implemented"
    else:
        raise AssertionError("未実装のはず")


def test_radiometric_TIFFは未対応で終了コード2(cli, tmp_path):
    path = tmp_path / "thermal.tiff"
    path.write_bytes(b"II*\x00")

    code, data, _ = cli("analyze", "--thermal", str(path), "--panel-grids", json.dumps(make_scene().grids))

    assert code == 2
    assert data["review_reason"] == "unsupported_format"


def test_ファイルが無ければ終了コード1(cli, tmp_path):
    code, data, _ = cli("analyze", "--thermal", str(tmp_path / "missing.npy"), "--panel-grids", json.dumps(make_scene().grids))

    assert code == 1
    assert data["status"] == "failed"
    assert data["review_reason"] == "file_not_found"


def test_ルールセットが不正なら終了コード1(cli, save_npy, tmp_path):
    bad_rules = tmp_path / "bad_rules.json"
    bad_rules.write_text(json.dumps({"version": "x", "detection_params": {}, "severity_rules": []}))
    path = save_npy(make_scene().temps)

    code, data, _ = cli("analyze", "--thermal", str(path), "--panel-grids", json.dumps(make_scene().grids),
                        "--rules", str(bad_rules), rules=False)

    assert code == 1
    assert data["review_reason"] == "invalid_input"


def test_propose_gridは構造のはっきりした画像でグリッドを提案する(cli, save_npy):
    path = save_npy(make_gapped_scene(rows=3, cols=5))

    code, data, _ = cli("propose-grid", "--thermal", str(path))

    assert code == 0
    assert data["status"] == "proposed"
    proposal = data["grid_proposal"]
    assert (proposal["rows"], proposal["cols"]) == (3, 5)
    assert proposal["panel_orientation"] == "landscape"
    assert proposal["panel_count"] == 15
    xs = [c[0] for c in proposal["corners"]]
    assert min(xs) * 640 < 125 and max(xs) * 640 > 390


def test_propose_gridは構造の無い画像では終了コード3(cli, save_npy):
    import numpy as np

    path = save_npy((np.random.default_rng(1).normal(0, 0.2, (512, 640)) + 30).astype("float32"))

    code, data, _ = cli("propose-grid", "--thermal", str(path))

    assert code == 3
    assert data["review_reason"] == "panel_extraction_failed"
    assert data["image"]["width"] == 640


def test_propose_gridは温度データが無ければ終了コード2(cli, tmp_path):
    path = tmp_path / "photo.jpg"
    path.write_bytes(b"plain text")

    code, data, _ = cli("propose-grid", "--thermal", str(path))

    assert code == 2


