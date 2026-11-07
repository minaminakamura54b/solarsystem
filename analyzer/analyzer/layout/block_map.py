"""複数の画像の架台の辺から、架台の地図（候補）を作る（docs/LAYOUT_OVERLAY_DESIGN.md の A-3）。

手順（2026-11 の検証で確かめた方法）:
1. パネル面の標高: LRF がパネルに当たった画像（画像の中心が架台の候補の中）の LRFTargetAbsAlt の中央値
2. 列の向き: 長辺を地上に移したときの向きの中央値
3. 長辺は「上端（高い）・下端（低い）」、短辺は「列の始まり・終わり」に分け、地上の位置で群にまとめる。
   パネルは傾いているので、上端は パネル面 + δ、下端は パネル面 − δ の高さで地上に移す
4. 画素の角度の倍率は短辺の、δ は長辺の「その画像を除いた地図」とのずれ（1 つ抜き）が最も小さくなる値を探す
   （長辺では両者がほぼ同じ効き方をするので、δ に左右されない短辺で先に倍率を決める）
5. 架台: 始まりと終わりの端を、架台の長さ（端どうしの間隔の中央値）で対応させる。片方の端しか無いものは長さで補い、
   列に乗っていて上端・下端の観測があるものだけ「確認が必要な候補」として残す。重なるものは観測の多い方を残す
判定（異常・重大度）には使わない。地図は人が確認してから使う（候補のまま自動では使わない）。
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

import numpy as np

from analyzer.errors import AnalyzerError
from analyzer.geo.projection import LocalFrame, NadirCamera
from analyzer.layout.edges import EdgeSet


@dataclass(frozen=True)
class ImageObs:
    id: str
    camera: NadirCamera
    edges: EdgeSet
    lrf_target_abs_alt: float | None


@dataclass
class Feature:
    image: str
    kind: str  # long / short
    side: str  # long: upper / lower、short: start / end
    along: float
    across: float


class BlockMapError(AnalyzerError):
    status = "needs_review"


def build_block_map(observations: list[ImageObs], frame: LocalFrame, params: dict, facing_azimuth_deg: float = 180.0,
                    module: dict | None = None) -> dict:
    obs = [o for o in observations if o.edges.longs or o.edges.shorts]
    if len(obs) < params["min_images"]:
        raise BlockMapError("too_few_images", f"架台が写っている画像が少なすぎます（{len(obs)} 枚。{params['min_images']} 枚以上必要）")
    plane, n_on_panel = panel_elevation(obs, params)
    theta = row_angle(obs, plane)

    # 画素の角度の倍率は短辺（列に沿う位置。δ に左右されない）だけで、δ は長辺で決める（長辺では両者がほぼ同じ効き方をするため）
    best_ratio = None
    for ratio in params["ifov_search_ratio"]:
        feats = to_ground(obs, plane, theta, facing_azimuth_deg, ratio, 0.0)
        _, stats = loo_stats(feats, cluster(feats, params), params)
        if stats and (best_ratio is None or stats["along_median_m"] < best_ratio[0]):
            best_ratio = (stats["along_median_m"], ratio)
    if best_ratio is None:
        raise BlockMapError("no_repeated_edges", "複数の画像で同じ架台の辺を見つけられませんでした")
    ratio = best_ratio[1]
    best = None
    for delta in params["edge_delta_search_m"]:
        feats = to_ground(obs, plane, theta, facing_azimuth_deg, ratio, delta)
        groups = cluster(feats, params)
        _, stats = loo_stats(feats, groups, params)
        if stats and (best is None or stats["across_median_m"] < best[0]):
            best = (stats["across_median_m"], delta, feats, groups, stats)
    _, delta, feats, groups, stats = best
    blocks, length = make_blocks(feats, groups, params)
    if not blocks:
        raise BlockMapError("no_blocks", "架台を組み立てられませんでした")

    ca, sa = math.cos(theta), math.sin(theta)
    def en(a, c):
        return a * ca - c * sa, a * sa + c * ca
    heights = [b["upper"] - b["lower"] for b in blocks if b["upper"] is not None and b["lower"] is not None]
    typical_h = float(np.median(heights)) if heights else None
    out_blocks = []
    for b in blocks:
        upper, lower = b["upper"], b["lower"]
        if (upper is None or lower is None) and typical_h is not None:
            b["low_confidence"] = True
            if upper is None and lower is not None:
                upper = lower + typical_h
            elif lower is None and upper is not None:
                lower = upper - typical_h
            elif upper is None and lower is None:
                upper, lower = b["c"] + typical_h / 2, b["c"] - typical_h / 2
        z_up, z_low = plane + delta, plane - delta
        corners = [(*en(b["a0"], upper), z_up), (*en(b["a1"], upper), z_up), (*en(b["a1"], lower), z_low), (*en(b["a0"], lower), z_low)]
        length_m = b["a1"] - b["a0"]
        height_m = upper - lower
        slope_m = math.hypot(height_m, 2 * delta)
        out_blocks.append({
            "corners_local": [[round(e, 3), round(n, 3), round(z, 3)] for e, n, z in corners],
            "corners_latlng": [list(frame.to_latlon(e, n)) for e, n, _ in corners],
            "length_m": round(length_m, 3), "height_m": round(height_m, 3),
            "cols_estimate": round(length_m / module["width_m"]) if module and module.get("width_m") else None,
            "rows_estimate": round(slope_m / module["length_m"]) if module and module.get("length_m") else None,
            "source": b["source"], "low_confidence": bool(b.get("low_confidence")),
            "observations": {"start": b["n0"], "end": b["n1"], "upper": b["n_upper"], "lower": b["n_lower"]},
        })
    out_blocks.sort(key=lambda b: (-np.mean([c[1] for c in b["corners_local"]]), np.mean([c[0] for c in b["corners_local"]])))
    return {
        "estimated": {
            "panel_elevation_m": round(plane, 3), "lrf_on_panel_images": n_on_panel,
            "ifov_ratio": ratio, "edge_height_delta_m": delta,
            "row_azimuth_deg": round((90 - math.degrees(theta)) % 180, 3),
            "block_length_m": round(length, 3), "block_height_m": round(typical_h, 3) if typical_h else None,
        },
        "fit": stats,
        "images": len(obs),
        "blocks": out_blocks,
    }


def panel_elevation(obs: list[ImageObs], params: dict) -> tuple[float, int]:
    import cv2

    hits = []
    for o in obs:
        if o.lrf_target_abs_alt is None:
            continue
        c = (o.camera.cx, o.camera.cy)
        if any(cv2.pointPolygonTest(b.astype(np.float32), c, False) >= 0 for b in o.edges.blocks):
            hits.append(o.lrf_target_abs_alt)
    if len(hits) < params["min_lrf_on_panel_images"]:
        raise BlockMapError("panel_elevation_unknown",
                            f"LRF がパネルに当たった画像が少なく、パネル面の標高を決められません（{len(hits)} 枚）")
    return float(np.median(hits)), len(hits)


def row_angle(obs: list[ImageObs], plane: float) -> float:
    """列の向き（東から反時計回りの角度、rad。-90°〜90°）。長辺の向きの、180° の向きの違いを同一視した平均"""
    acc = 0j
    for o in obs:
        for e in o.edges.longs:
            p0 = o.camera.pixel_to_ground(e.end_x[0], e.end_y[0], plane)
            p1 = o.camera.pixel_to_ground(e.end_x[1], e.end_y[1], plane)
            ang = math.atan2(p1[1] - p0[1], p1[0] - p0[0])
            acc += complex(math.cos(2 * ang), math.sin(2 * ang))
    if acc == 0:
        raise BlockMapError("no_long_edges", "架台の長辺が見つかりません")
    return math.atan2(acc.imag, acc.real) / 2


def to_ground(obs, plane, theta, facing_azimuth_deg, ifov_ratio, delta) -> list[Feature]:
    ca, sa = math.cos(theta), math.sin(theta)
    f = math.radians(facing_azimuth_deg)
    # 列に直交する向き（+across）がパネルの向く方位と反対なら、+across 側が上端
    upper_sign = 1 if (math.sin(f) * -sa + math.cos(f) * ca) < 0 else -1
    feats = []
    for o in obs:
        cam = replace(o.camera, ifov_rad=o.camera.ifov_rad * ifov_ratio)
        def rot(p):
            return p[0] * ca + p[1] * sa, -p[0] * sa + p[1] * ca
        for e in o.edges.longs:
            mid = rot(cam.pixel_to_ground(e.x, e.y, plane))
            ctr = rot(cam.pixel_to_ground(*e.center, plane))
            side_sign = 1 if mid[1] > ctr[1] else -1
            upper = side_sign == upper_sign
            a, c = rot(cam.pixel_to_ground(e.x, e.y, plane + delta if upper else plane - delta))
            feats.append(Feature(o.id, "long", "upper" if upper else "lower", a, c))
        for e in o.edges.shorts:
            a, c = rot(cam.pixel_to_ground(e.x, e.y, plane))
            ctr = rot(cam.pixel_to_ground(*e.center, plane))
            feats.append(Feature(o.id, "short", "start" if a < ctr[0] else "end", a, c))
    return feats


def _cluster_1d(idx, values, radius):
    idx = sorted(idx, key=lambda i: values[i])
    groups, cur = [], []
    for i in idx:
        if cur and values[i] - values[cur[-1]] > radius:
            groups.append(cur)
            cur = []
        cur.append(i)
    if cur:
        groups.append(cur)
    return groups


def cluster(feats: list[Feature], params: dict) -> list[tuple[str, list[int]]]:
    """長辺は上端・下端ごとに列に直交する位置でまとめる。短辺は、長辺から求めた列の中心のうち最も近い列に割り当ててから
    （列から離れた短辺は捨てる）、列に沿う位置でまとめる。短辺を列に直交する位置だけでまとめると、通路の誤検出を介して
    隣の列（約 13 m 離れた列）の端とつながることがあったため（2026-11 の検証）"""
    across = [f.across for f in feats]
    along = [f.along for f in feats]
    groups = []
    for side in ("upper", "lower"):
        idx = [i for i, f in enumerate(feats) if f.kind == "long" and f.side == side]
        groups += [("long", g) for g in _cluster_1d(idx, across, params["cluster_across_m"])]
    centers = row_centers(feats, groups, params)
    for side in ("start", "end"):
        by_row: dict[int, list[int]] = {}
        for i, f in enumerate(feats):
            if f.kind != "short" or f.side != side or not centers:
                continue
            k = min(range(len(centers)), key=lambda r: abs(f.across - centers[r]))
            if abs(f.across - centers[k]) <= params["row_band_m"]:
                by_row.setdefault(k, []).append(i)
        for idx in by_row.values():
            groups += [("short", g) for g in _cluster_1d(idx, along, params["cluster_along_m"])]
    return groups


def row_centers(feats, groups, params) -> list[float]:
    """列の中心: 上端の群と、その下（パネルの向く側）にある下端の群の中点"""
    def level(g):
        return float(np.median([feats[i].across for i in g]))
    uppers = [level(g) for kind, g in groups if kind == "long" and feats[g[0]].side == "upper" and len(g) >= params["min_images"]]
    lowers = [level(g) for kind, g in groups if kind == "long" and feats[g[0]].side == "lower" and len(g) >= params["min_images"]]
    lo, hi = params["block_short_side_m"]
    centers = []
    for u in uppers:
        cands = [l for l in lowers if lo <= abs(u - l) <= hi]
        if cands:
            l = min(cands, key=lambda x: abs(abs(u - x) - (lo + hi) / 2))
            centers.append((u + l) / 2)
    return sorted(centers)


def _value(f: Feature) -> float:
    return f.across if f.kind == "long" else f.along


def loo_stats(feats, groups, params):
    """各観測と、その画像を除いた地図（同じ群の、列に沿って近い観測の中央値）のずれ"""
    res = {"long": [], "short": []}
    window = params["local_window_m"]
    for _, g in groups:
        for i in g:
            fi = feats[i]
            vals = [_value(feats[j]) for j in g if feats[j].image != fi.image and abs(feats[j].along - fi.along) <= window]
            if len(vals) >= 2:
                res[fi.kind].append(_value(fi) - float(np.median(vals)))
    if not res["long"] or not res["short"]:
        return None, {}
    a, s = np.abs(res["long"]), np.abs(res["short"])
    stats = {
        "across_median_m": round(float(np.median(a)), 3), "across_p90_m": round(float(np.percentile(a, 90)), 3), "across_n": len(a),
        "along_median_m": round(float(np.median(s)), 3), "along_p90_m": round(float(np.percentile(s, 90)), 3), "along_n": len(s),
    }
    return (float(np.median(a)) + float(np.median(s))) / 2, stats


def typical_length(gaps: list[float], tolerance: float) -> float:
    """架台の長さ: 端どうしの間隔の分布の山（誤って見つけた端による短い間隔に引っぱられないよう、中央値ではなく最頻値の近く）"""
    values = np.array(gaps)
    hist, edges = np.histogram(values, bins=np.arange(values.min(), values.max() + 0.5, 0.25))
    peak = edges[int(np.argmax(hist))] + 0.125
    near = values[np.abs(values - peak) <= tolerance]
    return float(np.median(near))


def make_blocks(feats, groups, params):
    ends = []
    for kind, g in groups:
        if kind != "short":
            continue
        ends.append({"side": feats[g[0]].side, "a": float(np.median([feats[i].along for i in g])),
                     "c": float(np.median([feats[i].across for i in g])), "n": len({feats[i].image for i in g})})
    starts = [e for e in ends if e["side"] == "start"]
    stops = [e for e in ends if e["side"] == "end"]
    gaps = []
    for e in starts:
        d = [r["a"] - e["a"] for r in stops if abs(r["c"] - e["c"]) < params["row_band_m"] and 2.0 < r["a"] - e["a"] < 40.0]
        if d:
            gaps.append(min(d))
    if not gaps:
        return [], 0.0
    length = typical_length(gaps, params["pair_length_tolerance_m"])
    tol = params["pair_length_tolerance_m"]
    blocks, used = [], set()
    for e in sorted(starts, key=lambda x: -x["n"]):
        cands = [(abs(r["a"] - e["a"] - length), j) for j, r in enumerate(stops)
                 if j not in used and abs(r["c"] - e["c"]) < params["row_band_m"] and abs(r["a"] - e["a"] - length) < tol]
        if cands:
            _, j = min(cands)
            used.add(j)
            r = stops[j]
            blocks.append({"a0": e["a"], "a1": r["a"], "c": (e["c"] + r["c"]) / 2, "n0": e["n"], "n1": r["n"], "source": "both"})
        else:
            blocks.append({"a0": e["a"], "a1": e["a"] + length, "c": e["c"], "n0": e["n"], "n1": 0, "source": "start_only"})
    for j, r in enumerate(stops):
        if j not in used:
            blocks.append({"a0": r["a"] - length, "a1": r["a"], "c": r["c"], "n0": 0, "n1": r["n"], "source": "end_only"})

    blocks.sort(key=lambda b: -(b["n0"] + b["n1"] + (1000 if b["source"] == "both" else 0)))
    kept = []
    for b in blocks:
        if any(abs(b["c"] - k["c"]) < params["row_band_m"] and min(b["a1"], k["a1"]) - max(b["a0"], k["a0"]) > params["dedupe_overlap_m"] for k in kept):
            continue
        kept.append(b)

    band = params["edge_band_m"]
    for b in kept:
        for side, sign in (("upper", 1), ("lower", -1)):
            vals = [f.across for f in feats if f.kind == "long" and f.side == side
                    and b["a0"] - 1 < f.along < b["a1"] + 1 and 0 < sign * (f.across - b["c"]) < band]
            b[side] = float(np.median(vals)) if len(vals) >= 2 else None
            b["n_" + side] = len(vals)

    both = sorted([b for b in kept if b["source"] == "both"], key=lambda b: b["c"])
    rows, cur = [], []
    for b in both:
        if cur and b["c"] - cur[-1]["c"] > params["row_cluster_m"]:
            rows.append(float(np.median([x["c"] for x in cur])))
            cur = []
        cur.append(b)
    if cur:
        rows.append(float(np.median([x["c"] for x in cur])))
    final = list(both)
    for b in [x for x in kept if x["source"] != "both"]:
        near = min((abs(b["c"] - r) for r in rows), default=math.inf)
        overlap = any(abs(b["c"] - k["c"]) < params["row_band_m"] and min(b["a1"], k["a1"]) - max(b["a0"], k["a0"]) > params["single_end_max_overlap_m"] for k in final)
        if near < params["single_end_row_tolerance_m"] and b["n_upper"] >= 2 and b["n_lower"] >= 2 and not overlap:
            b["low_confidence"] = True
            final.append(b)
    return final, length
