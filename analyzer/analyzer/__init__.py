"""サーモ画像の解析エンジン（docs/IMPROVEMENT_PLAN.md セクション5）。

異常か正常かの判定（severity）はしない。パネルごとの温度・基準温度との差・発熱パターンを出力し、
重大度は Rails の SeverityRuleEngine がルールセットの閾値で付ける。
"""

ANALYZER_VERSION = "thermal_rules_v1"
SCHEMA_VERSION = "2.0"
