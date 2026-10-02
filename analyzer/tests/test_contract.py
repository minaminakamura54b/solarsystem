import pytest
from pydantic import ValidationError

from analyzer.contract import GridSpec, IrradianceInput, RulesInput
from tests.fixtures.make_synthetic import DEFAULT_RULES


def test_ルールセットは全種類の閾値が必要():
    rules = {**DEFAULT_RULES, "severity_rules": DEFAULT_RULES["severity_rules"][:-1]}

    with pytest.raises(ValidationError, match="panel_row_group"):
        RulesInput.model_validate(rules)


def test_検出パラメータが欠けていれば不正():
    params = {k: v for k, v in DEFAULT_RULES["detection_params"].items() if k != "panel_mad_floor_c"}

    with pytest.raises(ValidationError):
        RulesInput.model_validate({**DEFAULT_RULES, "detection_params": params})


def test_グリッドの4隅は4点():
    with pytest.raises(ValidationError, match="4点"):
        GridSpec(rows=1, cols=1, corners=[(0, 0), (1, 0), (1, 1)])


def test_Railsが保存する余分な項目は無視する():
    grid = GridSpec.model_validate({"rows": 1, "cols": 2, "corners": [[0, 0], [1, 0], [1, 1], [0, 1]],
                                    "grid_template_id": 3, "start_panel_ref": {"row": "A"}})

    assert grid.cols == 2


def test_正規化できるのはPOAの日射量があるときだけ():
    assert IrradianceInput(value=800, type="poa").normalizable
    assert not IrradianceInput(value=800, type="ghi").normalizable
    assert not IrradianceInput(value=None, type="poa").normalizable
    assert not IrradianceInput().normalizable
