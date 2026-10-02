"""CLI（docs/IMPROVEMENT_PLAN.md 5.2）。

  python -m analyzer analyze --thermal X --panel-grids '[...]' --module '{...}' --rules rules.json --out result.json
  python -m analyzer propose-grid --thermal X --out proposal.json

終了コード: 0=成功（提案あり）、1=その他エラー、2=温度データなし、3=グリッドなし（提案できない）、4=基準パネル不足。
どの終了コードでも、可能なかぎり --out に結果の JSON を書き、理由を stderr に出す。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from pydantic import TypeAdapter, ValidationError

from analyzer.contract import AnalysisResult, GridSpec, IrradianceInput, ModuleSpec, ProposalResult, RulesInput
from analyzer.errors import EXIT_ERROR, EXIT_OK, AnalyzerError
from analyzer.params import AnalyzerParams
from analyzer.pipeline import analyze, image_info
from analyzer.thermal.reader import read_thermal
from analyzer.vision.panel_segmenter import propose_grid


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m analyzer", description="サーモ画像の解析エンジン")
    sub = parser.add_subparsers(dest="command", required=True)

    a = sub.add_parser("analyze", help="グリッドを使ってパネルごとの温度と発熱パターンを求める")
    a.add_argument("--thermal", required=True, help="サーモ画像（R-JPEG。開発・テスト用に .npy の温度行列も可）")
    a.add_argument("--rgb", help="同時撮影の RGB 画像（Phase 3 では使わない）")
    a.add_argument("--irradiance", type=float, help="日射量（W/m²）")
    a.add_argument("--irradiance-type", choices=["poa", "ghi", "unknown"], help="日射量の種類")
    a.add_argument("--panel-grids", default="[]", help="グリッドの配列（JSON）")
    a.add_argument("--module", default="{}", help="モジュール構成（JSON）")
    a.add_argument("--rules", required=True, help="ルールセット（JSON ファイル）")
    a.add_argument("--params", help="解析パラメータ（JSON ファイル。省略時は analyzer/config/default_params.json）")
    a.add_argument("--out", required=True, help="結果の JSON を書くファイル")

    p = sub.add_parser("propose-grid", help="パネル配列を自動で見つけてグリッドを提案する（解析はしない）")
    p.add_argument("--thermal", required=True)
    p.add_argument("--params")
    p.add_argument("--out", required=True)
    return parser


def run_analyze(args) -> tuple[AnalysisResult, int]:
    try:
        grids = TypeAdapter(list[GridSpec]).validate_json(args.panel_grids)
        module = ModuleSpec.model_validate_json(args.module)
        rules = RulesInput.model_validate_json(Path(args.rules).read_text(encoding="utf-8"))
        irradiance = IrradianceInput(value=args.irradiance, type=args.irradiance_type)
        params = AnalyzerParams.load(args.params)
    except (ValidationError, ValueError, OSError) as e:
        raise AnalyzerError("invalid_input", f"入力が不正です: {e}") from e

    if not grids:
        # グリッドが無ければ画像を読まずに終了コード 3
        return analyze(None, "", grids, module, rules, irradiance, params)

    thermal = read_thermal(args.thermal, params.dji_thermal_params)
    return analyze(thermal.temps, thermal.source, grids, module, rules, irradiance, params)


def run_propose(args) -> tuple[ProposalResult, int]:
    params = AnalyzerParams.load(args.params)
    thermal = read_thermal(args.thermal, params.dji_thermal_params)
    info = image_info(thermal.temps, thermal.source)
    try:
        proposal = propose_grid(thermal.temps, params)
    except AnalyzerError as e:
        e.image = info
        raise
    return ProposalResult(status="proposed", image=info, grid_proposal=proposal), EXIT_OK


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    result_class = AnalysisResult if args.command == "analyze" else ProposalResult
    try:
        result, code = run_analyze(args) if args.command == "analyze" else run_propose(args)
        if result.review_reason:
            print(f"{result.review_reason}: {result.message}", file=sys.stderr)
    except AnalyzerError as e:
        result = result_class(status=e.status, review_reason=e.reason, message=e.message, image=getattr(e, "image", None))
        code = e.exit_code
        print(f"{e.reason}: {e.message}", file=sys.stderr)
    except Exception as e:  # noqa: BLE001 — 想定外のエラーも終了コード 1 と理由を必ず返す
        result = result_class(status="failed", review_reason="unexpected_error", message=f"{type(e).__name__}: {e}")
        code = EXIT_ERROR
        print(f"unexpected_error: {type(e).__name__}: {e}", file=sys.stderr)

    try:
        Path(args.out).write_text(result.model_dump_json(indent=2), encoding="utf-8")
    except OSError as e:
        print(f"結果を書き込めません: {e}", file=sys.stderr)
        return EXIT_ERROR
    return code


if __name__ == "__main__":
    sys.exit(main())
