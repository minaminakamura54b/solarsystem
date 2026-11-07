"""登録した架台を 1 枚の画像に重ね、画像の架台の辺に合わせて補正する（docs/LAYOUT_OVERLAY_DESIGN.md の B-2・B-3）。

1. 撮影情報（georef）で架台の 4 隅を画像に移す（上端・下端はそれぞれの高さで）
2. 画像の架台の辺（長辺・短辺。analyzer/layout/edges.py）を、予測した辺に対応させる（向き・側・距離で）
3. 対応した辺から、画像全体の補正（平行移動・拡大縮小・小さな回転）を外れ値を除いて最小二乗で求める
4. 補正後に残ったずれ（残差）をパネル幅に対する割合で出す。閾値以内で、列に沿う向き（架台の端）と列に直交する向き
   （長辺）の両方の手がかりがあれば aligned。架台の端が 1 つも写っていない画像は、パネルの境目だけでは 1 枚分の
   取り違えを見分けられないため needs_review
5. 画像に入る架台ごとに、解析エンジンのグリッド（4 隅は 上端の始まり・上端の終わり・下端の終わり・下端の始まり）を出す。
   パネルの番号はグリッドの行（上端から）・列（始まりから）で決まる
判定（異常・重大度）には使わない。位置合わせできない画像を正常にはしない（needs_review）。
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from analyzer.geo.projection import NadirCamera
from analyzer.layout.edges import EdgeSet


@dataclass
class BlockIn:
    id: int | str
    label: str
    rows: int
    cols: int
    corners_local: list[tuple[float, float]]  # 上端の始まり・上端の終わり・下端の終わり・下端の始まり（東・北 m）
    upper_z: float
    lower_z: float
    panel_orientation: str = "portrait"


@dataclass
class Constraint:
    kind: str  # long / short
    normal: np.ndarray
    point: np.ndarray  # 予測した辺の上の点（画素）
    residual: float  # 画像の辺までの距離（normal 向き、画素）


def project_block(cam: NadirCamera, b: BlockIn) -> np.ndarray:
    zs = [b.upper_z, b.upper_z, b.lower_z, b.lower_z]
    return np.array([cam.ground_to_pixel(e, n, z) for (e, n), z in zip(b.corners_local, zs)])


def visible(px: np.ndarray, width: int, height: int) -> bool:
    return px[:, 0].max() > 0 and px[:, 0].min() < width and px[:, 1].max() > 0 and px[:, 1].min() < height


def _side_long(line_mid: np.ndarray, center: np.ndarray, transposed: bool) -> str:
    """画像の上側（転置したときは左側）の長辺が "a"（edges.py の約束）"""
    i = 0 if transposed else 1
    return "a" if line_mid[i] < center[i] else "b"


def _side_short(line_mid: np.ndarray, center: np.ndarray, transposed: bool) -> str:
    """画像の左側（転置したときは上側）の短辺が "start"（edges.py の約束）"""
    i = 1 if transposed else 0
    return "start" if line_mid[i] < center[i] else "end"


def _seg_fit(q: np.ndarray, a: np.ndarray, b: np.ndarray):
    """点 q を線分 a-b に投影したときの位置（0〜1）と、線分上の点・法線・符号付き距離"""
    d = b - a
    length = float(np.linalg.norm(d))
    u = d / length
    n = np.array([-u[1], u[0]])
    t = float(np.dot(q - a, u)) / length
    p = a + u * (t * length)
    return t, p, n, float(np.dot(q - p, n))


def match_edges(px_blocks: list[np.ndarray], edges: EdgeSet, search_px: float) -> list[Constraint]:
    out = []
    lines = []  # (kind, side, a, b, center)
    for px in px_blocks:
        center = px.mean(axis=0)
        for kind, (i, j) in (("long", (0, 1)), ("long", (3, 2)), ("short", (0, 3)), ("short", (1, 2))):
            a, b = px[i], px[j]
            mid = (a + b) / 2
            side = _side_long(mid, center, edges.transposed) if kind == "long" else _side_short(mid, center, edges.transposed)
            lines.append((kind, side, a, b))
    for e in edges.longs:
        q = np.array([e.x, e.y])
        direction = np.array([e.end_x[1] - e.end_x[0], e.end_y[1] - e.end_y[0]])
        best = None
        for kind, side, a, b in lines:
            if kind != "long" or side != e.side:
                continue
            t, p, n, dist = _seg_fit(q, a, b)
            seg = b - a
            cos = abs(np.dot(seg, direction)) / (np.linalg.norm(seg) * np.linalg.norm(direction) + 1e-9)
            ok = -0.1 <= t <= 1.1 and abs(dist) <= search_px and cos > math.cos(math.radians(10))
            if ok and (best is None or abs(dist) < abs(best.residual)):
                best = Constraint("long", n, p, dist)
        if best:
            out.append(best)
    for e in edges.shorts:
        q = np.array([e.x, e.y])
        best = None
        for kind, side, a, b in lines:
            if kind != "short" or side != e.side:
                continue
            t, p, n, dist = _seg_fit(q, a, b)
            ok = -0.2 <= t <= 1.2 and abs(dist) <= search_px
            if ok and (best is None or abs(dist) < abs(best.residual)):
                best = Constraint("short", n, p, dist)
        if best:
            out.append(best)
    return out


def fit_correction(constraints: list[Constraint], center: np.ndarray, outlier_px: float):
    """補正 p' = p + t + ds (p − c) + θ perp(p − c) を、各辺の法線向きのずれから外れ値を除いて求める。
    返り値: (パラメータ [tx, ty, ds, θ], 外れ値でない制約の添字)"""
    kinds = {c.kind for c in constraints}
    use_scale = len(constraints) >= 6 and kinds == {"long", "short"}
    keep = list(range(len(constraints)))
    params = np.zeros(4)
    for _ in range(4):
        rows, y = [], []
        for i in keep:
            c = constraints[i]
            v = c.point - center
            rows.append([c.normal[0], c.normal[1], float(np.dot(c.normal, v)), float(np.dot(c.normal, [-v[1], v[0]]))])
            y.append(c.residual)
        a = np.array(rows)
        cols = [0, 1, 2, 3] if use_scale else [0, 1]
        sol = np.linalg.lstsq(a[:, cols], np.array(y), rcond=None)[0]
        params = np.zeros(4)
        params[cols] = sol
        res = np.array(y) - a @ params
        mad = float(np.median(np.abs(res - np.median(res)))) * 1.4826
        limit = max(outlier_px, 2.5 * mad)
        new_keep = [i for i, r in zip(keep, res) if abs(r) <= limit]
        if len(new_keep) == len(keep) or len(new_keep) < 2:
            break
        keep = new_keep
    return params, keep


def apply_correction(px: np.ndarray, params: np.ndarray, center: np.ndarray) -> np.ndarray:
    tx, ty, ds, th = params
    v = px - center
    return px + np.array([tx, ty]) + ds * v + th * np.c_[-v[:, 1], v[:, 0]]


def align(temps_edges: EdgeSet, cam: NadirCamera, blocks: list[BlockIn], max_ratio: float, params: dict) -> dict:
    px_all = [(b, project_block(cam, b)) for b in blocks]
    seen = [(b, px) for b, px in px_all if visible(px, cam.width, cam.height)]
    if not seen:
        return {"status": "needs_review", "review_reason": "no_blocks_in_view", "message": "登録した架台がこの画像に写っていません",
                "grids": [], "draft_grids": []}
    gsd = float(np.median([cam.gsd((b.upper_z + b.lower_z) / 2) for b, _ in seen]))
    panel_w = float(np.median([math.dist(b.corners_local[0], b.corners_local[1]) / b.cols for b, _ in seen]))
    search_px = params["align_search_m"] / gsd
    constraints = match_edges([px for _, px in seen], temps_edges, search_px)
    center = np.array([cam.cx, cam.cy])
    draft = grids_for(seen, cam, np.zeros(4), center)
    n_long = sum(c.kind == "long" for c in constraints)
    n_short = sum(c.kind == "short" for c in constraints)
    base = {"gsd_m": round(gsd, 4), "panel_width_m": round(panel_w, 3), "draft_grids": draft,
            "matches": {"long": n_long, "short": n_short}, "blocks_in_view": len(seen)}
    if n_long == 0 or n_short == 0:
        reason = "no_across_anchor" if n_long == 0 else "no_along_anchor"
        message = ("架台の長辺が見つからず、列に直交する向きの位置を合わせられません" if n_long == 0
                   else "架台の端が写っておらず、列に沿う向きの位置を合わせられません（パネル 1 枚分の取り違えを見分けられないため）")
        return {"status": "needs_review", "review_reason": reason, "message": message, "grids": [], **base}

    p, keep = fit_correction(constraints, center, params["align_outlier_px"])
    inl = [constraints[i] for i in keep]
    v = np.array([c.point - center for c in inl])
    pred = np.array([np.dot(c.normal, [p[0], p[1]]) + p[2] * np.dot(c.normal, vv) + p[3] * np.dot(c.normal, [-vv[1], vv[0]])
                     for c, vv in zip(inl, v)])
    res = np.array([c.residual for c in inl]) - pred
    rms_px = float(np.sqrt(np.mean(res ** 2)))
    ratio = rms_px * gsd / panel_w
    inlier_ratio = len(keep) / len(constraints)
    kinds_kept = {c.kind for c in inl}
    result = {
        **base,
        "correction": {"tx_px": round(float(p[0]), 2), "ty_px": round(float(p[1]), 2), "scale": round(1 + float(p[2]), 5),
                       "rotation_deg": round(math.degrees(float(p[3])), 3)},
        "residual": {"rms_px": round(rms_px, 2), "rms_m": round(rms_px * gsd, 3), "panel_width_ratio": round(ratio, 3),
                     "threshold_ratio": max_ratio},
        "matches": {"long": n_long, "short": n_short, "inliers": len(keep)},
        "grids": grids_for(seen, cam, p, center),
    }
    if kinds_kept != {"long", "short"}:
        return {"status": "needs_review", "review_reason": "no_along_anchor" if "short" not in kinds_kept else "no_across_anchor",
                "message": "補正に使える辺が片方の向きしか残りませんでした", **result}
    if inlier_ratio < params["align_min_inlier_ratio"]:
        return {"status": "needs_review", "review_reason": "inconsistent_edges",
                "message": f"画像の辺と架台の対応がそろいません（そろった辺 {len(keep)} / {len(constraints)}）", **result}
    if ratio > max_ratio:
        return {"status": "needs_review", "review_reason": "residual_too_large",
                "message": f"補正後のずれがパネル幅の {ratio:.2f} で、閾値 {max_ratio:g} を超えています", **result}
    return {"status": "aligned", "review_reason": None, "message": None, **result}


def grids_for(seen, cam: NadirCamera, p: np.ndarray, center: np.ndarray) -> list[dict]:
    grids = []
    for b, px in seen:
        corr = apply_correction(px, p, center)
        norm = [[round(float(x) / cam.width, 6), round(float(y) / cam.height, 6)] for x, y in corr]
        if any(not (-1.0 <= v <= 2.0) for pt in norm for v in pt):
            continue
        grids.append({"rows": b.rows, "cols": b.cols, "corners": norm, "panel_orientation": b.panel_orientation,
                      "source": "layout", "pv_block_id": b.id, "block_label": b.label})
    return grids
