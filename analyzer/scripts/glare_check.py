"""撮影前の確認: パネルに映った太陽（反射）がサーモ画像に写るかを、傾斜角・方位・日時から計算する（2026-11-07 ユーザー指示）。

考え方（docs/LAYOUT_OVERLAY_DESIGN.md の C-2・E）:
  パネル面を鏡とみなし、画像の各画素の視線をパネル面で反射させた向きに太陽があれば、その画素に反射が写る。
  太陽の見かけの大きさ・パネル表面の凹凸を見込んで、角度の余裕（--margin-deg）を足して判定する。
  あわせて、視線がパネル面に垂直になる点（機体・カメラ自身が映り込む点）が画像に入るかも確かめる。

太陽の位置は NOAA の簡易式（誤差 約 0.5° 以内）。判定は幾何だけで、雲・日射の強さは考えない（撮影条件の目安。判定の規則ではない）。

  uv run python scripts/glare_check.py --lat 35.68 --lon 139.77 --tilt 20 --azimuth 180 \\
      --date 2026-11-15 --start 09:00 --end 15:00 --step-min 15
  # カメラを傾ける案も試す（パネルの向く方向へ 0〜20°。北へ傾ける案は映り込みの確認つき）
  uv run python scripts/glare_check.py ... --try-pitch

画角の既定値は DJI M4T のサーモ（640×512 画素、画素の角度 約 0.975 mrad。2026-11 の検証で推定）から: 横 約 35.8°・縦 約 28.6°。
"""

from __future__ import annotations

import argparse
import math
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

DEFAULT_HFOV_DEG = math.degrees(2 * math.atan(320 * 0.975e-3))
DEFAULT_VFOV_DEG = math.degrees(2 * math.atan(256 * 0.975e-3))


def sun_position(when: datetime, lat: float, lon: float) -> tuple[float, float]:
    """太陽の高度・方位（度。方位は北から時計回り）。when はタイムゾーン付き。"""
    utc = when.astimezone(timezone.utc)
    jd = utc.timestamp() / 86400.0 + 2440587.5
    t = (jd - 2451545.0) / 36525.0
    l0 = (280.46646 + t * (36000.76983 + 0.0003032 * t)) % 360
    m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
    e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    mr = math.radians(m)
    c = (math.sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t)) + math.sin(2 * mr) * (0.019993 - 0.000101 * t)
         + math.sin(3 * mr) * 0.000289)
    true_long = l0 + c
    omega = 125.04 - 1934.136 * t
    app_long = true_long - 0.00569 - 0.00478 * math.sin(math.radians(omega))
    eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
    eps = eps0 + 0.00256 * math.cos(math.radians(omega))
    decl = math.asin(math.sin(math.radians(eps)) * math.sin(math.radians(app_long)))
    y = math.tan(math.radians(eps / 2)) ** 2
    l0r = math.radians(l0)
    eq_time = 4 * math.degrees(y * math.sin(2 * l0r) - 2 * e * math.sin(mr) + 4 * e * y * math.sin(mr) * math.cos(2 * l0r)
                               - 0.5 * y * y * math.sin(4 * l0r) - 1.25 * e * e * math.sin(2 * mr))
    minutes = utc.hour * 60 + utc.minute + utc.second / 60
    true_solar = (minutes + eq_time + 4 * lon) % 1440
    hour_angle = math.radians(true_solar / 4 - 180)
    latr = math.radians(lat)
    cos_zen = math.sin(latr) * math.sin(decl) + math.cos(latr) * math.cos(decl) * math.cos(hour_angle)
    zen = math.acos(max(-1.0, min(1.0, cos_zen)))
    elevation = 90 - math.degrees(zen)
    az = math.degrees(math.atan2(math.sin(hour_angle), math.cos(hour_angle) * math.sin(latr) - math.tan(decl) * math.cos(latr)))
    return elevation, (az + 180) % 360


def unit_from(elevation_deg: float, azimuth_deg: float) -> tuple[float, float, float]:
    """高度・方位 → 単位ベクトル（東・北・上）"""
    el, az = math.radians(elevation_deg), math.radians(azimuth_deg)
    return (math.cos(el) * math.sin(az), math.cos(el) * math.cos(az), math.sin(el))


def panel_normal(tilt_deg: float, azimuth_deg: float) -> tuple[float, float, float]:
    """パネル面の法線（パネルの向く方位 azimuth、傾斜角 tilt）"""
    return unit_from(90 - tilt_deg, azimuth_deg)


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


@dataclass(frozen=True)
class Camera:
    pitch_deg: float = -90.0  # -90 = 真下
    heading_deg: float = 0.0  # 画像の上が向く方位（真下のとき）／カメラが向く方位（傾けたとき）
    hfov_deg: float = DEFAULT_HFOV_DEG
    vfov_deg: float = DEFAULT_VFOV_DEG

    def axes(self):
        p, h = math.radians(self.pitch_deg), math.radians(self.heading_deg)
        forward = (math.sin(h), math.cos(h), 0.0)
        axis = tuple(math.cos(p) * f + math.sin(p) * u for f, u in zip(forward, (0.0, 0.0, 1.0)))
        up = tuple(-math.sin(p) * f + math.cos(p) * u for f, u in zip(forward, (0.0, 0.0, 1.0)))
        right = cross(axis, up)
        return axis, up, right

    def locate(self, direction, margin_deg: float = 0.0):
        """視線の向き direction が画角（＋余裕）に入れば、画像内の位置（横・縦。-1〜1、中心 0、上が +）を返す。入らなければ None"""
        axis, up, right = self.axes()
        z = dot(direction, axis)
        if z <= 0:
            return None
        ax = math.degrees(math.atan2(dot(direction, right), z))
        ay = math.degrees(math.atan2(dot(direction, up), z))
        hx, hy = self.hfov_deg / 2 + margin_deg, self.vfov_deg / 2 + margin_deg
        if abs(ax) <= hx and abs(ay) <= hy:
            return ax / (self.hfov_deg / 2), ay / (self.vfov_deg / 2)
        return None


@dataclass(frozen=True)
class Check:
    when: datetime
    sun_elevation: float
    sun_azimuth: float
    glare: tuple[float, float] | None  # 反射が写る画像内の位置
    self_reflection: tuple[float, float] | None  # 機体・カメラが映り込む画像内の位置


def glare_position(sun_elevation: float, sun_azimuth: float, tilt: float, azimuth: float, camera: Camera, margin_deg: float):
    """太陽の高度・方位から、反射が写る画像内の位置（写らなければ None）"""
    n = panel_normal(tilt, azimuth)
    s = unit_from(sun_elevation, sun_azimuth)
    if sun_elevation <= 0 or dot(s, n) <= 0:
        return None
    # パネル面で反射した太陽光の向き r = 2(s·n)n − s。カメラはその逆向き（−r）を見ると反射が写る
    k = 2 * dot(s, n)
    view = tuple(si - k * ni for si, ni in zip(s, n))
    return camera.locate(view, margin_deg)


def self_reflection_position(tilt: float, azimuth: float, camera: Camera):
    """視線がパネル面に垂直（法線の逆向き）になる点 = 機体・カメラが映り込む。画像に入れば位置、入らなければ None"""
    n = panel_normal(tilt, azimuth)
    return camera.locate(tuple(-v for v in n), 0.0)


def check(when: datetime, lat: float, lon: float, tilt: float, azimuth: float, camera: Camera, margin_deg: float) -> Check:
    el, az = sun_position(when, lat, lon)
    return Check(when, el, az, glare_position(el, az, tilt, azimuth, camera, margin_deg),
                 self_reflection_position(tilt, azimuth, camera))


def times(day: date, start: str, end: str, step_min: int, tz: timezone):
    t = datetime.combine(day, datetime.strptime(start, "%H:%M").time(), tz)
    stop = datetime.combine(day, datetime.strptime(end, "%H:%M").time(), tz)
    while t <= stop:
        yield t
        t += timedelta(minutes=step_min)


def parse_tz(text: str) -> timezone:
    sign = -1 if text.startswith("-") else 1
    hh, mm = text.lstrip("+-").split(":")
    return timezone(sign * timedelta(hours=int(hh), minutes=int(mm)))


def fmt_pos(pos) -> str:
    if pos is None:
        return "なし"
    x, y = pos
    horiz = "左" if x < -0.33 else ("右" if x > 0.33 else "中央")
    vert = "上" if y > 0.33 else ("下" if y < -0.33 else "中央")
    return f"あり（画像の{vert}・{horiz}。x={x:+.2f} y={y:+.2f}）"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lat", type=float, required=True, help="緯度（度）")
    parser.add_argument("--lon", type=float, required=True, help="経度（度。東経が正）")
    parser.add_argument("--tilt", type=float, required=True, help="パネルの傾斜角（度）")
    parser.add_argument("--azimuth", type=float, default=180.0, help="パネルの向く方位（度。北 0・東 90・南 180・西 270）")
    parser.add_argument("--date", type=date.fromisoformat, required=True, help="撮影日（YYYY-MM-DD）")
    parser.add_argument("--start", default="08:00", help="開始時刻（HH:MM）")
    parser.add_argument("--end", default="16:00", help="終了時刻（HH:MM）")
    parser.add_argument("--step-min", type=int, default=15, help="計算の間隔（分）")
    parser.add_argument("--tz", default="+09:00", help="時刻のタイムゾーン（既定 +09:00）")
    parser.add_argument("--pitch", type=float, default=-90.0, help="カメラの角度（度。-90 = 真下）")
    parser.add_argument("--heading", type=float, default=0.0, help="真下のとき画像の上が向く方位／傾けたときカメラが向く方位（度）")
    parser.add_argument("--hfov", type=float, default=DEFAULT_HFOV_DEG, help="横の画角（度）")
    parser.add_argument("--vfov", type=float, default=DEFAULT_VFOV_DEG, help="縦の画角（度）")
    parser.add_argument("--margin-deg", type=float, default=5.0, help="判定の余裕（度。太陽の大きさ・パネル表面の凹凸の分）")
    parser.add_argument("--try-pitch", action="store_true", help="カメラを 5°〜20° 傾ける案も計算する（パネルの向く方向・反対方向）")
    args = parser.parse_args(argv)

    tz = parse_tz(args.tz)
    slots = list(times(args.date, args.start, args.end, args.step_min, tz))
    base = Camera(args.pitch, args.heading, args.hfov, args.vfov)
    print(f"パネル: 傾斜 {args.tilt:g}°・方位 {args.azimuth:g}° ／ カメラ: 角度 {args.pitch:g}°・画角 {args.hfov:.1f}°×{args.vfov:.1f}°・余裕 {args.margin_deg:g}°")
    print("時刻   太陽の高度 方位   反射")
    results = [check(t, args.lat, args.lon, args.tilt, args.azimuth, base, args.margin_deg) for t in slots]
    for r in results:
        print(f"{r.when:%H:%M}  {r.sun_elevation:6.1f}° {r.sun_azimuth:6.1f}°  {fmt_pos(r.glare)}")
    hits = [r for r in results if r.glare]
    print(f"\n反射が写る可能性のある時刻: {len(hits)} / {len(results)}" + (f"（{hits[0].when:%H:%M}〜{hits[-1].when:%H:%M}）" if hits else ""))
    if results and results[0].self_reflection:
        print(f"注意: 機体・カメラがパネルに映り込む点が画像に入ります: {fmt_pos(results[0].self_reflection)}")

    if args.try_pitch:
        print("\nカメラを傾ける案（反射が写る時刻の数 ／ 機体の映り込み）")
        for toward, label in ((args.azimuth, "パネルの向く方向"), ((args.azimuth + 180) % 360, "反対方向（北など）")):
            for tilt_cam in (5, 10, 15, 20):
                cam = Camera(-90 + tilt_cam, toward, args.hfov, args.vfov)
                rs = [check(t, args.lat, args.lon, args.tilt, args.azimuth, cam, args.margin_deg) for t in slots]
                n_hit = sum(1 for r in rs if r.glare)
                selfref = "あり（避ける）" if rs and rs[0].self_reflection else "なし"
                print(f"  {label}へ {tilt_cam:2d}°: 反射 {n_hit} / {len(rs)}・映り込み {selfref}")
        print("（傾けた画像は、位置の計算にカメラの角度を入れる必要がある。真下より解像度が少し下がる）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
