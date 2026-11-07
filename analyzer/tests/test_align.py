"""登録した架台を画像に重ねて補正する（analyzer/layout/align.py）。既知の配置を合成の画像に描き、撮影情報をわざとずらして確かめる。"""

import json

import numpy as np

from analyzer.__main__ import main
from analyzer.geo.projection import LocalFrame, NadirCamera
from analyzer.layout.align import BlockIn, align, project_block
from analyzer.layout.command import load_layout_params
from analyzer.layout.edges import detect_edges

PLANE, IFOV, H = 30.0, 0.975e-3, 37.0
PARAMS = load_layout_params()


def layout(length=11.6, depth=4.0, gap=0.25, n=5, rows=(0.0, -13.0)):
    out = []
    for r, c in enumerate(rows):
        for k in range(n):
            a0 = k * (length + gap)
            out.append(BlockIn(f"{r}-{k}", f"B{r}{k}", 2, 10, [(a0, c + depth / 2), (a0 + length, c + depth / 2), (a0 + length, c - depth / 2), (a0, c - depth / 2)], PLANE, PLANE))
    return out


def render(cam: NadirCamera, blocks, seed=0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    u, v = np.meshgrid(np.arange(cam.width), np.arange(cam.height))
    east = cam.east + (u - cam.cx) * IFOV * H
    north = cam.north - (v - cam.cy) * IFOV * H
    ground = 25 + rng.normal(0, 2.5, u.shape)
    img = (0.5 * ground + 0.5 * np.roll(ground, 1, axis=1)).astype(np.float32)
    for b in blocks:
        (w, top), (e, _), (_, bottom), _ = b.corners_local
        inside = (east >= w) & (east <= e) & (north >= bottom) & (north <= top)
        pitch = (e - w) / b.cols
        line = np.abs(((east - w) / pitch) - np.round((east - w) / pitch)) * pitch < 0.03
        panel = np.where(line, 34.2, 35 + rng.normal(0, 0.05, u.shape))
        img = np.where(inside, panel, img)
    return img.astype(np.float32)


def camera(e, n):
    return NadirCamera(e, n, PLANE + H, 0.0, IFOV, 640, 512)


def run(true_cam, believed_cam, blocks, scene=None):
    temps = render(true_cam, scene or blocks)
    edges = detect_edges(temps, IFOV * H, PARAMS)
    return align(edges, believed_cam, blocks, 0.25, PARAMS)


def test_撮影情報のずれを架台の辺で補正する():
    blocks = layout()
    true_cam = camera(29.0, -6.5)
    result = run(true_cam, camera(29.4, -6.8), blocks)  # 東に 0.4 m・南に 0.3 m ずれた撮影情報

    assert result["status"] == "aligned", result.get("message")
    assert result["residual"]["panel_width_ratio"] < 0.1
    for g in result["grids"]:
        b = next(b for b in blocks if b.id == g["pv_block_id"])
        truth = project_block(true_cam, b)
        got = np.array(g["corners"]) * [640, 512]
        assert np.abs(got - truth).max() < 2.0, (g["block_label"], got - truth)


def test_グリッドの4隅は上端の始まりから_番号は上端から行優先():
    blocks = layout()
    result = run(camera(29.0, -6.5), camera(29.0, -6.5), blocks)
    g = result["grids"][0]
    (x0, y0), (x1, _), (_, y2), _ = g["corners"]
    assert x0 < x1, "始まり（西）が左"
    assert y0 < y2, "上端（北）が上"
    assert g["source"] == "layout" and g["rows"] == 2 and g["cols"] == 10


def test_架台が写っていなければ要確認():
    result = run(camera(29.0, -6.5), camera(300.0, 300.0), layout())
    assert (result["status"], result["review_reason"]) == ("needs_review", "no_blocks_in_view")


def test_架台の端が写っていなければ_残差が小さくても要確認():
    long_block = [BlockIn("L", "L1", 2, 43, [(-5.0, 2.0), (45.0, 2.0), (45.0, -2.0), (-5.0, -2.0)], PLANE, PLANE)]  # 両端とも画像の外
    result = run(camera(20.0, -2.0), camera(20.0, -2.0), long_block)
    assert (result["status"], result["review_reason"]) == ("needs_review", "no_along_anchor")
    assert result["draft_grids"], "手動のグリッドの下書きは出す"


def test_撮影情報が大きくずれていれば自動にしない():
    result = run(camera(29.0, -6.5), camera(31.5, -9.0), layout())
    assert result["status"] == "needs_review"


def test_コマンドとして動く(tmp_path):
    blocks = layout()
    frame = LocalFrame(35.0, 139.0)
    true_cam = camera(29.0, -6.5)
    np.save(tmp_path / "t.npy", render(true_cam, blocks))
    lat, lng = frame.to_latlon(29.3, -6.6)
    spec = {
        "origin": {"lat": 35.0, "lng": 139.0}, "max_residual_panel_width_ratio": 0.25,
        "image": {"id": "1", "thermal": str(tmp_path / "t.npy"), "lrf_target_abs_alt_m": PLANE,
                  "camera": {"lat": lat, "lng": lng, "abs_alt_m": PLANE + H, "image_up_azimuth_deg": 0.0, "ifov_mrad": IFOV * 1000, "width": 640, "height": 512}},
        "blocks": [{"id": b.id, "label": b.label, "rows": b.rows, "cols": b.cols, "corners_latlng": [list(frame.to_latlon(e, n)) for e, n in b.corners_local]}
                   for b in blocks],
    }
    (tmp_path / "in.json").write_text(json.dumps(spec))
    code = main(["align-layout", "--input", str(tmp_path / "in.json"), "--out", str(tmp_path / "out.json")])
    out = json.loads((tmp_path / "out.json").read_text())
    assert code == 0, out
    assert out["status"] == "aligned"
    assert out["grids"] and out["schema_version"]


def test_標高が分からなければ要確認(tmp_path):
    frame = LocalFrame(35.0, 139.0)
    np.save(tmp_path / "t.npy", np.zeros((512, 640), np.float32))
    spec = {"origin": {"lat": 35.0, "lng": 139.0}, "max_residual_panel_width_ratio": 0.25,
            "image": {"id": "1", "thermal": str(tmp_path / "t.npy"),
                      "camera": {"lat": 35.0, "lng": 139.0, "abs_alt_m": 67.0, "image_up_azimuth_deg": 0.0, "ifov_mrad": 0.975, "width": 640, "height": 512}},
            "blocks": [{"id": 1, "label": "A01", "rows": 2, "cols": 10, "corners_latlng": [list(frame.to_latlon(e, n)) for e, n in [(0, 4), (11.6, 4), (11.6, 0), (0, 0)]]}]}
    (tmp_path / "in.json").write_text(json.dumps(spec))
    code = main(["align-layout", "--input", str(tmp_path / "in.json"), "--out", str(tmp_path / "out.json")])
    out = json.loads((tmp_path / "out.json").read_text())
    assert code == 1
    assert (out["status"], out["review_reason"]) == ("needs_review", "panel_elevation_unknown")
