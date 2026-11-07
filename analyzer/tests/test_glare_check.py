"""撮影前の反射の確認スクリプト（scripts/glare_check.py）。太陽の位置と、反射・映り込みの幾何を確かめる。"""

import importlib.util
import sys
from datetime import date, datetime, timedelta, timezone

from tests.conftest import ANALYZER_ROOT

spec = importlib.util.spec_from_file_location("glare_check", ANALYZER_ROOT / "scripts" / "glare_check.py")
glare_check = importlib.util.module_from_spec(spec)
sys.modules["glare_check"] = glare_check
spec.loader.exec_module(glare_check)

JST = timezone(timedelta(hours=9))
NADIR = glare_check.Camera()


def test_夏至の東京の南中高度は約78度():
    day = datetime(2026, 6, 21, 10, 0, tzinfo=JST)
    best = max(glare_check.sun_position(day + timedelta(minutes=m), 35.68, 139.77)[0] for m in range(0, 240))
    assert abs(best - (90 - 35.68 + 23.44)) < 0.5


def test_南中のとき太陽は南():
    el, az = glare_check.sun_position(datetime(2026, 11, 15, 11, 30, tzinfo=JST), 43.2, 141.3)
    assert 170 < az < 190
    assert 24 < el < 31  # 北緯 43° の 11 月中旬の南中高度は約 28°


def test_真下向きで傾斜20度なら南の高度50度の太陽が画像の中央付近に写る():
    pos = glare_check.glare_position(50, 180, 20, 180, NADIR, 0)
    assert pos is not None
    assert abs(pos[0]) < 0.1 and abs(pos[1]) < 0.1


def test_真下向きで傾斜20度なら南の高度28度の太陽は写らない():
    assert glare_check.glare_position(28, 180, 20, 180, NADIR, 5) is None


def test_太陽がパネルの裏側や地平線の下なら写らない():
    assert glare_check.glare_position(30, 0, 20, 180, NADIR, 5) is None
    assert glare_check.glare_position(-5, 180, 20, 180, NADIR, 5) is None


def test_カメラを南へ傾けると反射の写る向きが地平線側へ動く():
    # 真下で中央に写る太陽（高度 50°）は、南へ 20° 傾けると画角の外
    south = glare_check.Camera(pitch_deg=-70, heading_deg=180)
    assert glare_check.glare_position(50, 180, 20, 180, south, 0) is None
    # 代わりに、より低い太陽（高度 30°）が写る
    assert glare_check.glare_position(30, 180, 20, 180, south, 0) is not None


def test_北へ傾けると機体の映り込みが画像に入る():
    assert glare_check.self_reflection_position(20, 180, NADIR) is None
    north = glare_check.Camera(pitch_deg=-80, heading_deg=0)
    assert glare_check.self_reflection_position(20, 180, north) is not None


def test_コマンドとして動く(capsys):
    code = glare_check.main(["--lat", "43.2", "--lon", "141.3", "--tilt", "20", "--date", "2026-11-15",
                             "--start", "10:00", "--end", "14:00", "--step-min", "60", "--try-pitch"])
    out = capsys.readouterr().out
    assert code == 0
    assert "反射が写る可能性のある時刻: 0 / 5" in out
    assert "パネルの向く方向へ" in out
