"""エリア撮影（写真測量の飛び方）の画像から、解析する画像を間引いて選ぶ（11 月の案件の手順。2026-11-06 ユーザー指示）。

同じパネルが多くの画像に写るため、飛行ラインを原則 2 本おき、ライン内の撮影を原則 3 枚おきに選び、
人が架台ごとに 1 回だけグリッドを指定する。間隔は撮影位置（GPS）の距離で決める:
  - 次に選ぶラインは、前に選んだラインから --max-line-gap-m 以内で最も遠いライン（ライン間隔 約 6.7 m なら 2 本おき）
  - ライン内で次に選ぶ画像は、前に選んだ画像から --max-shot-gap-m 以内で最も遠い画像（撮影間隔 約 3.5 m なら 3 枚おき。3 × 3.54 m に余裕を見て 11 m）
  ラインの間隔が広い所では自動的に詰める（架台が画像の端で切れて、どの画像にも丸ごと写らないことを防ぐため）。
既定値は、サーモ 1 枚の写る範囲（対地約 41 m で約 27 m × 21 m）と架台の大きさ（約 12 m × 5 m）から決めた。
パネルが写っていない画像も選ばれることがある（人が飛ばす）。判定には関係しない（どの画像を人が見るかの補助）。

入力は exiftool の CSV（例: exiftool -n -csv -FileName -GPSLatitude -GPSLongitude DIR/*_T.JPG > meta.csv）。
FileName の代わりに seq（番号）の列でもよい。撮影順は FileName（または seq）の自然な順とする。

  uv run python scripts/select_images.py meta.csv --out selected.csv
"""

from __future__ import annotations

import argparse
import csv
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path

METERS_PER_DEG_LAT = 110_950.0


@dataclass(frozen=True)
class Shot:
    name: str
    x: float  # 東向き（m）
    y: float  # 北向き（m）


def natural_key(name: str) -> list:
    return [(0, int(p)) if p.isdigit() else (1, p) for p in re.findall(r"\d+|\D+", name)]


def load(path: Path) -> list[Shot]:
    with path.open(encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        return []
    name_key = "FileName" if "FileName" in rows[0] else "seq"
    lat_key = "GPSLatitude" if "GPSLatitude" in rows[0] else "lat"
    lon_key = "GPSLongitude" if "GPSLongitude" in rows[0] else "lon"
    rows = [r for r in rows if r.get(lat_key) and r.get(lon_key)]
    rows.sort(key=lambda r: natural_key(r[name_key]))
    lat0 = sum(float(r[lat_key]) for r in rows) / len(rows)
    meters_per_deg_lon = METERS_PER_DEG_LAT * math.cos(math.radians(lat0))
    return [Shot(r[name_key], float(r[lon_key]) * meters_per_deg_lon, float(r[lat_key]) * METERS_PER_DEG_LAT) for r in rows]


def flight_lines(shots: list[Shot], max_cross_step_m: float, min_shots: int) -> list[list[Shot]]:
    """撮影順に並んだ画像を飛行ラインに分ける。北向きに大きく動いたとき、または東西の向きが反転したときに区切る。
    折り返しの数枚など、短すぎるラインは捨てる。"""
    lines: list[list[Shot]] = []
    current: list[Shot] = []
    direction = 0
    for shot in shots:
        if current:
            dx = shot.x - current[-1].x
            dy = shot.y - current[-1].y
            step_direction = 0 if abs(dx) < 0.5 else (1 if dx > 0 else -1)
            if abs(dy) >= max_cross_step_m or (direction and step_direction and step_direction != direction):
                lines.append(current)
                current, direction = [], 0
            elif step_direction:
                direction = direction or step_direction
        current.append(shot)
    if current:
        lines.append(current)
    return [line for line in lines if len(line) >= min_shots]


def farthest_within(values: list[float], max_gap: float) -> list[int]:
    """昇順の値から、前に選んだ値との差が max_gap 以内で最も遠いものを順に選ぶ（最初と最後は必ず選ぶ）。"""
    if not values:
        return []
    chosen = [0]
    i = 0
    while i < len(values) - 1:
        j = i + 1
        while j + 1 < len(values) and values[j + 1] - values[i] <= max_gap:
            j += 1
        chosen.append(j)
        i = j
    return chosen


def select(shots: list[Shot], max_line_gap_m: float, max_shot_gap_m: float,
           max_cross_step_m: float = 2.0, min_shots: int = 5) -> list[tuple[int, Shot]]:
    lines = flight_lines(shots, max_cross_step_m, min_shots)
    lines.sort(key=lambda line: sum(s.y for s in line) / len(line))
    centers = [sum(s.y for s in line) / len(line) for line in lines]
    selected: list[tuple[int, Shot]] = []
    for line_index in farthest_within(centers, max_line_gap_m):
        line = sorted(lines[line_index], key=lambda s: s.x)
        for shot_index in farthest_within([s.x for s in line], max_shot_gap_m):
            selected.append((line_index, line[shot_index]))
    return selected


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv", type=Path, help="exiftool の CSV（FileName または seq、GPSLatitude、GPSLongitude）")
    parser.add_argument("--max-line-gap-m", type=float, default=13.5, help="選ぶ飛行ラインの間隔の上限（m）")
    parser.add_argument("--max-shot-gap-m", type=float, default=11.0, help="ライン内で選ぶ画像の間隔の上限（m）")
    parser.add_argument("--out", type=Path, help="選んだ画像の CSV（省略時は標準出力）")
    args = parser.parse_args(argv)

    shots = load(args.csv)
    selected = select(shots, args.max_line_gap_m, args.max_shot_gap_m)
    out = args.out.open("w", encoding="utf-8", newline="") if args.out else sys.stdout
    writer = csv.writer(out)
    writer.writerow(["order", "name", "flight_line", "east_m", "north_m"])
    x0 = min((s.x for s in shots), default=0)
    y0 = min((s.y for s in shots), default=0)
    for order, (line, shot) in enumerate(selected, 1):
        writer.writerow([order, shot.name, line + 1, round(shot.x - x0, 1), round(shot.y - y0, 1)])
    if args.out:
        out.close()
    print(f"{len(shots)} 枚から {len(selected)} 枚を選びました", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
