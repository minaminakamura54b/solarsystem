import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

from analyzer.contract import GridSpec, IrradianceInput, ModuleSpec, RulesInput
from analyzer.params import AnalyzerParams
from analyzer.pipeline import analyze
from tests.fixtures.make_synthetic import DEFAULT_RULES

ANALYZER_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def params():
    return AnalyzerParams.load()


@pytest.fixture
def rules():
    return RulesInput.model_validate(DEFAULT_RULES)


@pytest.fixture
def run_analysis(params, rules):
    """合成の温度行列をそのまま解析する。戻り値は (AnalysisResult, 終了コード)。"""

    def _run(scene, module=None, irradiance=None, grids=None, analyzer_params=None):
        return analyze(
            scene.temps,
            "npy",
            [GridSpec.model_validate(g) for g in (scene.grids if grids is None else grids)],
            ModuleSpec.model_validate(module or {}),
            rules,
            IrradianceInput.model_validate(irradiance or {}),
            analyzer_params or params,
        )

    return _run


@pytest.fixture
def cli(tmp_path):
    """python -m analyzer を別プロセスで実行する。戻り値は (終了コード, 出力 JSON, stderr)。"""

    rules_path = tmp_path / "rules.json"
    rules_path.write_text(json.dumps(DEFAULT_RULES), encoding="utf-8")

    def _run(*args, rules=True):
        out = tmp_path / "out.json"
        command = [sys.executable, "-m", "analyzer", *args, "--out", str(out)]
        if rules and args and args[0] == "analyze":
            command += ["--rules", str(rules_path)]
        proc = subprocess.run(command, cwd=ANALYZER_ROOT, capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})
        data = json.loads(out.read_text(encoding="utf-8")) if out.exists() else None
        return proc.returncode, data, proc.stderr

    return _run


@pytest.fixture
def save_npy(tmp_path):
    def _save(temps, name="thermal.npy"):
        path = tmp_path / name
        np.save(path, temps)
        return path

    return _save
