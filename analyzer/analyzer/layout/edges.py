"""1 枚の温度行列から架台の辺を見つける（docs/LAYOUT_OVERLAY_DESIGN.md の A-3・B-2）。

- パネル面は温度のばらつきが小さく、草地はばらつきが大きい。細い線を中央値フィルタで消し、局所的なばらつきの小さい
  領域（大津の方法で画像ごとに閾値）を長方形として取り出す（架台の候補）
- 長辺（列に沿う辺）は直線で、短辺（架台の端・架台の間の隙間）は傾きも含めて直線で合わせ込む。
  パネルは傾いているので、上端と下端で高さが違い、真上から見た短辺は画像の位置によって斜めに見える
- 画像の端に接する辺は「切れている」として使わない
- 架台が画像の縦方向に並ぶ（列が画像の縦向き）ときは、転置して同じ処理をする
"""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np


@dataclass(frozen=True)
class LongEdge:
    side: str  # "a" / "b": 架台の中心から見て、列に直交する向きのどちら側か（画像の転置前の上側が "a"）
    x: float  # 辺の中点（画素）
    y: float
    end_x: tuple[float, float]  # 辺の両端（画素）。地上での向きを求めるのに使う
    end_y: tuple[float, float]
    center: tuple[float, float]  # 架台の候補の中心（画素）
    sd: float


@dataclass(frozen=True)
class ShortEdge:
    side: str  # "start" / "end": 列に沿う向きの、画像の左側の端が "start"（転置前）
    x: float  # 架台の高さの中央での位置（画素）
    y: float
    center: tuple[float, float]
    sd: float


@dataclass(frozen=True)
class EdgeSet:
    longs: list[LongEdge]
    shorts: list[ShortEdge]
    blocks: list[np.ndarray]  # 4 辺とも切れていない架台の候補の 4 隅（画素。LRF がパネルに当たったかの判定に使う）
    transposed: bool


def detect_edges(temps: np.ndarray, gsd_m: float, params: dict) -> EdgeSet:
    """gsd_m: 1 画素の大きさの目安（m）。架台の大きさの範囲の確認に使う"""
    t = np.asarray(temps, dtype=np.float32)
    first = _detect(t, gsd_m, params)
    if _looks_vertical(t, params):
        second = _detect(np.ascontiguousarray(t.T), gsd_m, params)
        if len(second[0]) > len(first[0]):
            return _untranspose(*second)
    return EdgeSet(*first, transposed=False)


def _components(t: np.ndarray):
    tm = cv2.medianBlur(t, 5)
    mean = cv2.blur(tm, (9, 9))
    sq = cv2.blur(tm * tm, (9, 9))
    std = np.sqrt(np.maximum(sq - mean * mean, 0))
    top = np.percentile(std, 99)
    s8 = (np.clip(std / (top if top > 0 else 1.0), 0, 1) * 255).astype(np.uint8)
    _, smooth = cv2.threshold(s8, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    smooth = cv2.morphologyEx(smooth, cv2.MORPH_OPEN, np.ones((11, 11), np.uint8))
    return cv2.connectedComponentsWithStats(smooth)


def _looks_vertical(t: np.ndarray, params: dict) -> bool:
    n, _, st, _ = _components(t)
    angles = []
    for i in range(1, n):
        if st[i][4] < params["min_component_area_px"]:
            continue
        _, _, bw, bh, _ = st[i]
        angles.append(bh > bw)
    return bool(angles) and sum(angles) > len(angles) / 2


def _box(lab, i):
    cnt, _ = cv2.findContours((lab == i).astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    rect = cv2.minAreaRect(cnt[0])
    box = cv2.boxPoints(rect)
    s = box.sum(1)
    d = box[:, 0] - box[:, 1]
    tl, br = box[np.argmin(s)], box[np.argmax(s)]
    tr, bl = box[np.argmax(d)], box[np.argmin(d)]
    return rect, tl, tr, br, bl


def _fit(points: np.ndarray, outlier_px: float):
    """points[:,0] を説明変数、points[:,1] を目的変数とする直線（外れ値を除いて最小二乗）。(傾き, 切片, 標準偏差, 使った点の数)"""
    a = np.c_[points[:, 0], np.ones(len(points))]
    coef = np.linalg.lstsq(a, points[:, 1], rcond=None)[0]
    res = points[:, 1] - a @ coef
    keep = np.abs(res - np.median(res)) <= outlier_px
    if keep.sum() < 3:
        return None
    coef = np.linalg.lstsq(a[keep], points[keep, 1], rcond=None)[0]
    sd = float(np.std(points[keep, 1] - a[keep] @ coef))
    return float(coef[0]), float(coef[1]), sd, int(keep.sum())


def _detect(t: np.ndarray, gsd_m: float, params: dict):
    h_img, w_img = t.shape
    n, lab, st, _ = _components(t)
    g = cv2.GaussianBlur(t, (0, 0), 1.0)
    gy, gx = np.gradient(g)
    offs = np.arange(-params["edge_search_px"], params["edge_search_px"] + 1)
    lo_m, hi_m = params["block_short_side_m"]
    longs, shorts, blocks = [], [], []
    for i in range(1, n):
        x, y, w, h, area = st[i]
        if area < params["min_component_area_px"]:
            continue
        rect, tl, tr, br, bl = _box(lab, i)
        if area / max(rect[1][0] * rect[1][1], 1) < params["min_rectangularity"]:
            continue
        wpx, hpx = float(np.linalg.norm(tr - tl)), float(np.linalg.norm(bl - tl))
        cut = {"top": y <= 2, "bottom": y + h >= h_img - 2, "left": x <= 2, "right": x + w >= w_img - 2}
        if wpx < params["min_long_side_px"]:
            continue
        if not cut["top"] and not cut["bottom"] and not (lo_m <= hpx * gsd_m <= hi_m):
            continue
        center = (float((tl[0] + br[0]) / 2), float((tl[1] + br[1]) / 2))
        if not any(cut.values()):
            blocks.append(np.array([tl, tr, br, bl], dtype=np.float32))
        # 長辺
        for side, (p, q) in (("a", (tl, tr)), ("b", (bl, br))):
            if cut["top" if side == "a" else "bottom"]:
                continue
            pts = []
            for f in np.linspace(0.08, 0.92, 15):
                c = p + (q - p) * f
                xi = round(float(c[0]))
                if not 0 <= xi < w_img:
                    continue
                ys = (c[1] + offs).round().astype(int)
                ok = (ys >= 1) & (ys < h_img - 1)
                if ok.sum() < len(offs) * 0.6:
                    continue
                j = offs[ok][np.argmax(np.abs(gy[ys[ok], xi]))]
                pts.append((c[0], c[1] + j))
            if len(pts) < 6:
                continue
            fit = _fit(np.array(pts), params["edge_outlier_px"])
            if fit is None or fit[3] < 6 or fit[2] > params["max_edge_fit_sd_px"]:
                continue
            m, k, sd, _ = fit
            xs = np.array(pts)[:, 0]
            x0, x1 = float(xs.min()), float(xs.max())
            xm = (x0 + x1) / 2
            longs.append(LongEdge(side, xm, m * xm + k, (x0, x1), (m * x0 + k, m * x1 + k), center, sd))
        # 短辺（長辺の向きに沿って探し、傾きも合わせ込む）
        ytop = 0.0 if cut["top"] else float(tl[1])
        ybot = float(h_img - 1) if cut["bottom"] else float(bl[1])
        slope = float((tr[1] - tl[1]) / max(tr[0] - tl[0], 1e-6))
        for side, p in (("start", (tl + bl) / 2), ("end", (tr + br) / 2)):
            if cut["left" if side == "start" else "right"]:
                continue
            pts = []
            for f in np.linspace(0.12, 0.88, 11):
                yv = ytop + (ybot - ytop) * f
                if not 1 <= yv < h_img - 1:
                    continue
                x0 = p[0] - slope * (yv - p[1])
                xs = (x0 + offs).round().astype(int)
                ok = (xs >= 1) & (xs < w_img - 1)
                if ok.sum() < len(offs) * 0.6:
                    continue
                j = offs[ok][np.argmax(np.abs(gx[int(yv), xs[ok]]))]
                pts.append((yv, x0 + j))
            if len(pts) < 6:
                continue
            fit = _fit(np.array(pts), params["edge_outlier_px"])
            if fit is None or fit[3] < 6 or fit[2] > params["max_edge_fit_sd_px"]:
                continue
            m, k, sd, _ = fit
            yc = (ytop + ybot) / 2
            shorts.append(ShortEdge(side, m * yc + k, yc, center, sd))
    return longs, shorts, blocks


def _untranspose(longs, shorts, blocks) -> EdgeSet:
    def sw(p):
        return (p[1], p[0])
    longs2 = [LongEdge(e.side, e.y, e.x, e.end_y, e.end_x, sw(e.center), e.sd) for e in longs]
    shorts2 = [ShortEdge(e.side, e.y, e.x, sw(e.center), e.sd) for e in shorts]
    blocks2 = [b[:, ::-1].copy() for b in blocks]
    return EdgeSet(longs2, shorts2, blocks2, transposed=True)
