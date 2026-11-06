"""11 月の案件の手順で使う、解析する画像を間引くスクリプト（scripts/select_images.py）。合成の撮影位置だけを使う。"""

import csv
import importlib.util
import math
import sys

from tests.conftest import ANALYZER_ROOT

spec = importlib.util.spec_from_file_location("select_images", ANALYZER_ROOT / "scripts" / "select_images.py")
select_images = importlib.util.module_from_spec(spec)
sys.modules["select_images"] = select_images  # dataclass がモジュールを参照するため
spec.loader.exec_module(select_images)

LAT0 = 43.2
M_PER_DEG_LON = select_images.METERS_PER_DEG_LAT * math.cos(math.radians(LAT0))


def write_flight(path, line_ys, shots_per_line=20, step=3.5, turn_shots=True):
    """東西の往復（蛇行）の撮影位置を CSV に書く。折り返しに 1 枚ずつ撮影を入れる。"""
    rows, seq = [], 1
    for i, y in enumerate(line_ys):
        xs = [k * step for k in range(shots_per_line)]
        if i % 2:
            xs.reverse()
        for x in xs:
            rows.append((f"DJI_{seq:04d}_T.JPG", LAT0 + y / select_images.METERS_PER_DEG_LAT, 141.3 + x / M_PER_DEG_LON))
            seq += 1
        if turn_shots and i + 1 < len(line_ys):
            mid_y = (y + line_ys[i + 1]) / 2
            rows.append((f"DJI_{seq:04d}_T.JPG", LAT0 + mid_y / select_images.METERS_PER_DEG_LAT, 141.3 + xs[-1] / M_PER_DEG_LON))
            seq += 1
    with path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["SourceFile", "FileName", "GPSLatitude", "GPSLongitude"])
        for name, lat, lon in rows:
            writer.writerow([f"dir/{name}", name, lat, lon])
    return path


def test_飛行ラインに分け_折り返しの画像は捨てる(tmp_path):
    shots = select_images.load(write_flight(tmp_path / "m.csv", [0, 6.7, 13.4]))

    lines = select_images.flight_lines(shots, max_cross_step_m=2.0, min_shots=5)

    assert [len(line) for line in lines] == [20, 20, 20]


def test_ラインは原則2本おき_撮影は原則3枚おきに選ぶ(tmp_path):
    ys = [i * 6.7 for i in range(9)]
    shots = select_images.load(write_flight(tmp_path / "m.csv", ys, shots_per_line=19))

    selected = select_images.select(shots, max_line_gap_m=13.5, max_shot_gap_m=11.0)

    assert sorted({line for line, _ in selected}) == [0, 2, 4, 6, 8]
    xs = sorted(round(s.x - min(t.x for t in shots), 1) for line, s in selected if line == 0)
    assert xs == [0.0, 10.5, 21.0, 31.5, 42.0, 52.5, 63.0]


def test_ラインの間隔が広い所では詰めて選ぶ(tmp_path):
    ys = [0, 6.7, 13.4, 23.4, 33.4, 40.1]
    shots = select_images.load(write_flight(tmp_path / "m.csv", ys))

    selected = select_images.select(shots, max_line_gap_m=13.5, max_shot_gap_m=11.0)

    assert sorted({line for line, _ in selected}) == [0, 2, 3, 4, 5]


def test_CLIは選んだ画像のCSVを書く(tmp_path):
    out = tmp_path / "selected.csv"
    write_flight(tmp_path / "m.csv", [0, 6.7, 13.4])

    assert select_images.main([str(tmp_path / "m.csv"), "--out", str(out)]) == 0

    rows = list(csv.DictReader(out.open()))
    assert rows[0].keys() == {"order", "name", "flight_line", "east_m", "north_m"}
    assert {r["flight_line"] for r in rows} == {"1", "3"}
    assert rows[0]["name"].startswith("DJI_")
