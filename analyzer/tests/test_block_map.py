"""架台の地図づくり（analyzer/layout/）。既知の配置を合成の画像に描き、そこから地図を作り直せるかを確かめる。"""

import json

import numpy as np
import pytest

from analyzer.__main__ import main
from analyzer.geo.projection import LocalFrame, NadirCamera
from analyzer.layout import block_map as BM
from analyzer.layout.command import load_layout_params
from analyzer.layout.edges import detect_edges

PLANE = 30.0  # パネル面の標高
GROUND = 28.0
IFOV = 0.975e-3
ROWS = [0.0, -13.0, -26.0]  # 列の中心（北 m）
BLOCK_L, BLOCK_H, GAP, N_BLOCKS = 11.6, 4.0, 0.25, 5
PANELS = 10


def truth():
    blocks = []
    for c in ROWS:
        for k in range(N_BLOCKS):
            a0 = k * (BLOCK_L + GAP)
            blocks.append((a0, a0 + BLOCK_L, c - BLOCK_H / 2, c + BLOCK_H / 2))
    return blocks


def render(cam: NadirCamera, rng) -> np.ndarray:
    """パネル面（温度 35℃・ばらつき小・パネルの境目に細い線）と草地（ばらつき大）"""
    u, v = np.meshgrid(np.arange(cam.width), np.arange(cam.height))
    h = cam.abs_alt - PLANE
    dx, dy = (u - cam.cx) * IFOV * h, -(v - cam.cy) * IFOV * h
    a = np.radians(cam.up_azimuth_deg)
    east = cam.east + dx * np.cos(a) + dy * np.sin(a)
    north = cam.north - dx * np.sin(a) + dy * np.cos(a)
    ground = 25 + rng.normal(0, 2.5, u.shape)
    ground = 0.5 * ground + 0.5 * np.roll(ground, 1, axis=1)
    img = ground.astype(np.float32)
    pitch = BLOCK_L / PANELS
    for a0, a1, n0, n1 in truth():
        inside = (east >= a0) & (east <= a1) & (north >= n0) & (north <= n1)
        panel = 35 + rng.normal(0, 0.05, u.shape)
        line = (np.abs(((east - a0) / pitch) - np.round((east - a0) / pitch)) * pitch < 0.03)
        panel = np.where(line, 34.2, panel)
        img = np.where(inside, panel, img)
    return img.astype(np.float32)


def flight(rng, lines=(2.0, -4.7, -11.4, -18.1, -24.8), shots=None, up=0.0):
    shots = np.arange(-6, 62, 3.5) if shots is None else shots
    obs = []
    params = load_layout_params()
    for li, n in enumerate(lines):
        for e in shots:
            cam = NadirCamera(float(e), float(n), PLANE + 37.0, up, IFOV, 640, 512)
            temps = render(cam, rng)
            on_panel = any(a0 <= e <= a1 and n0 <= n <= n1 for a0, a1, n0, n1 in truth())
            edges = detect_edges(temps, IFOV * 37.0, params)
            obs.append(BM.ImageObs(f"{li}-{e}", cam, edges, PLANE if on_panel else GROUND))
    return obs


@pytest.fixture(scope="module")
def scene():
    return flight(np.random.default_rng(0))


def test_合成の画像から架台の地図を作り直せる(scene):
    result = BM.build_block_map(scene, LocalFrame(43.2, 141.3), load_layout_params(), 180.0, {"width_m": 1.16, "length_m": 2.0})
    blocks = result["blocks"]
    assert result["estimated"]["panel_elevation_m"] == pytest.approx(PLANE)
    assert result["estimated"]["block_length_m"] == pytest.approx(BLOCK_L, abs=0.2)
    assert len(blocks) == len(truth())
    for a0, a1, n0, n1 in truth():
        cx, cy = (a0 + a1) / 2, (n0 + n1) / 2
        b = min(blocks, key=lambda b: (np.mean([c[0] for c in b["corners_local"]]) - cx) ** 2 + (np.mean([c[1] for c in b["corners_local"]]) - cy) ** 2)
        es = [c[0] for c in b["corners_local"]]
        ns = [c[1] for c in b["corners_local"]]
        assert min(es) == pytest.approx(a0, abs=0.25) and max(es) == pytest.approx(a1, abs=0.25)
        assert max(ns) == pytest.approx(n1, abs=0.3) and min(ns) == pytest.approx(n0, abs=0.3)
        assert b["cols_estimate"] == PANELS


def test_機首を90度回して列が画像の縦に並んでも地図を作れる():
    obs = flight(np.random.default_rng(2), lines=(0.0, -6.5, -13.0, -19.5, -26.0), shots=np.arange(-4, 60, 4.0), up=90.0)
    assert any(o.edges.transposed for o in obs)
    result = BM.build_block_map(obs, LocalFrame(43.2, 141.3), load_layout_params())
    assert result["estimated"]["block_length_m"] == pytest.approx(BLOCK_L, abs=0.25)
    assert len(result["blocks"]) >= len(truth()) - 2


def test_北側が上端_パネルの向く南側が下端(scene):
    result = BM.build_block_map(scene, LocalFrame(43.2, 141.3), load_layout_params())
    b = result["blocks"][0]
    upper_z = b["corners_local"][0][2]
    lower_z = b["corners_local"][3][2]
    assert upper_z >= lower_z
    assert b["corners_local"][0][1] > b["corners_local"][3][1]


def test_画像が少なければ要確認(scene):
    with pytest.raises(BM.BlockMapError) as e:
        BM.build_block_map(scene[:2], LocalFrame(43.2, 141.3), load_layout_params())
    assert e.value.reason == "too_few_images"


def test_LRFがパネルに当たった画像が無ければ標高を決めず要確認(scene):
    no_lrf = [BM.ImageObs(o.id, o.camera, o.edges, None) for o in scene]
    with pytest.raises(BM.BlockMapError) as e:
        BM.build_block_map(no_lrf, LocalFrame(43.2, 141.3), load_layout_params())
    assert e.value.reason == "panel_elevation_unknown"


def test_架台の長さは誤検出の短い間隔に引っぱられない():
    gaps = [11.6] * 20 + [11.5] * 5 + [2.0, 3.1, 4.5, 6.6, 2.2, 3.0, 4.4, 6.5, 7.0, 8.1]
    assert BM.typical_length(gaps, 0.6) == pytest.approx(11.6, abs=0.05)


def test_端は最も近い列に割り当て_通路の誤検出で隣の列とつながらない():
    params = load_layout_params()
    feats = []
    for c in (0.0, -13.0):
        for img in range(6):
            feats.append(BM.Feature(f"i{img}", "long", "upper", 5.0 + img, c + 2.0))
            feats.append(BM.Feature(f"i{img}", "long", "lower", 5.0 + img, c - 2.0))
            feats.append(BM.Feature(f"i{img}", "short", "start", 0.0, c))
    # 通路の誤検出（列の中心から 2.5 m より離れたもの）は捨て、列の中の端（-1.0）は北の列に入る
    feats += [BM.Feature("x", "short", "start", 0.0, -4.0), BM.Feature("y", "short", "start", 0.0, -8.5),
              BM.Feature("z", "short", "start", 0.0, -1.0)]
    groups = [g for kind, g in BM.cluster(feats, params) if kind == "short"]
    sizes = sorted(len(g) for g in groups)
    assert sizes == [6, 7]
    for g in groups:
        assert max(feats[i].across for i in g) - min(feats[i].across for i in g) < 5


def test_コマンドとして動く(scene, tmp_path):
    frame = LocalFrame(43.2, 141.3)
    rng = np.random.default_rng(1)
    images = []
    for o in scene[20:80]:  # LRF がパネルに当たる画像を含む範囲
        path = tmp_path / f"{o.id}.npy"
        np.save(path, render(o.camera, rng))
        lat, lng = frame.to_latlon(o.camera.east, o.camera.north)
        images.append({"id": o.id, "thermal": str(path), "lrf_target_abs_alt_m": o.lrf_target_abs_alt,
                       "camera": {"lat": lat, "lng": lng, "abs_alt_m": o.camera.abs_alt, "image_up_azimuth_deg": 0.0,
                                  "ifov_mrad": IFOV * 1000, "width": 640, "height": 512}})
    (tmp_path / "in.json").write_text(json.dumps({"origin": {"lat": 43.2, "lng": 141.3}, "images": images}))
    code = main(["build-block-map", "--input", str(tmp_path / "in.json"), "--out", str(tmp_path / "out.json")])
    out = json.loads((tmp_path / "out.json").read_text())
    assert code == 0, out
    assert out["status"] == "proposed"
    assert len(out["blocks"]) >= 6
    assert all(len(b["corners_latlng"]) == 4 for b in out["blocks"])


def test_入力が不正なら終了コード1(tmp_path):
    (tmp_path / "in.json").write_text("{}")
    code = main(["build-block-map", "--input", str(tmp_path / "in.json"), "--out", str(tmp_path / "out.json")])
    out = json.loads((tmp_path / "out.json").read_text())
    assert code == 1
    assert out["review_reason"] == "invalid_input"
    assert out["blocks"] == []


def test_隣の架台と重なる端は中点から離す():
    params = load_layout_params()
    blocks = [{"a0": 0.0, "a1": 11.8, "c": 0.0}, {"a0": 11.7, "a1": 23.4, "c": 0.1}, {"a0": 23.65, "a1": 35.2, "c": 0.0}]
    BM.separate_neighbors(blocks, params)
    assert blocks[1]["a0"] - blocks[0]["a1"] == pytest.approx(params["min_gap_m"])
    assert blocks[0]["a1"] == pytest.approx(11.75 - params["min_gap_m"] / 2)
    assert blocks[0].get("adjusted") and blocks[1].get("adjusted")
    assert blocks[2]["a0"] == pytest.approx(23.65)  # 十分離れていれば動かさない


def test_近い列の中心は1つにまとめる():
    params = load_layout_params()
    feats = []
    for img in range(6):
        feats += [BM.Feature(f"i{img}", "long", "upper", 0.0, 2.0), BM.Feature(f"j{img}", "long", "upper", 30.0, 2.6),
                  BM.Feature(f"i{img}", "long", "lower", 0.0, -2.0)]
    groups = [("long", [i for i, f in enumerate(feats) if f.side == "upper" and f.across == 2.0]),
              ("long", [i for i, f in enumerate(feats) if f.side == "upper" and f.across == 2.6]),
              ("long", [i for i, f in enumerate(feats) if f.side == "lower"])]
    centers = BM.row_centers(feats, groups, params)
    assert len(centers) == 1
    assert centers[0] == pytest.approx(0.15)
