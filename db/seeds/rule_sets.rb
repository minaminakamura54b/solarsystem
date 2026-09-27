# 重大度の閾値の初期値（docs/IMPROVEMENT_PLAN.md 4.5）。
# 暫定値（商用製品の公開基準を参考にした値）であり、案件ごとに依頼元と合意して新しいバージョンを作ること。
# 何度実行しても同じ結果になる。既存のルールセットは変更しない
initial_version = "2026-09-initial"

unless RuleSet.exists?(version: initial_version)
  thresholds = {
    # anomaly_type        measure        mild warning critical
    "hotspot"          => [ "region_max",  2.0, 5.0, 15.0 ],
    "multi_hotspot"    => [ "region_max",  1.0, 2.5, 7.5 ],
    "substring_bypass" => [ "region_mean", 1.5, 3.0, 8.0 ],
    "module_wide"      => [ "panel_mean",  1.5, 3.0, 8.0 ],
    "partial_module"   => [ "region_mean", 1.5, 3.0, 8.0 ],
    "panel_row_group"  => [ "panel_mean",  1.5, 2.0, 5.0 ]
  }

  rule_set = RuleSet.new(
    version: initial_version,
    note: "初期値（暫定）。生ΔT の閾値は正規化ΔT と同じ値を仮に入れている。依頼元と合意して見直すこと",
    detection_params: {
      "panel_mad_k" => 4, "panel_mad_floor_c" => 0.3, "min_region_offset_c" => 1.0,
      "baseline_mad_k" => 3, "baseline_mad_floor_c" => 0.5,
      "baseline_min_panels" => 6, "baseline_min_ratio" => 0.5,
      "row_group_min_panels" => 3
    }
  )
  thresholds.each do |type, (measure, mild, warning, critical)|
    rule_set.severity_rules.build(
      anomaly_type: type, measure: measure,
      normalized_mild: mild, normalized_warning: warning, normalized_critical: critical,
      raw_mild: mild, raw_warning: warning, raw_critical: critical
    )
  end
  rule_set.save!
  puts "ルールセット #{initial_version} を作成しました"
end

unless RuleSet.exists?(active: true)
  RuleSet.find_by!(version: initial_version).activate!
  puts "ルールセット #{initial_version} を有効にしました"
end
