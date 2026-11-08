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

# 基準温度の取り方を「画像内の位置の傾向」にした版（2026-11-08 ユーザー承認。暫定）。閾値は初期値と同じ。
# 自動では有効にしない（判定基準の画面で有効にする。元の方法に戻すときは 2026-09-initial を有効にする）。
# 次の点検データ（別の日・時間帯）で、今の方法との比べ方をもう一度行うまでは暫定
trend_version = "2026-11-trend-provisional"
unless RuleSet.exists?(version: trend_version)
  source = RuleSet.find_by!(version: initial_version)
  copy = source.duplicate(version: trend_version)
  copy.note = "暫定: 基準温度を画像内の位置（縦・横）の温度の傾向から取る（見る角度で画像の下側ほど温かく見える影響を除くため）。" \
              "閾値は 2026-09-initial と同じ。次の点検データ（別の日・時間帯）で今の方法と比べ直すまでは確定にしない。" \
              "元の方法に戻すときは 2026-09-initial を有効にする"
  copy.detection_params = source.detection_params.merge("baseline_method" => "position_trend", "trend_min_spread" => 0.2)
  copy.save!
  puts "ルールセット #{trend_version} を作成しました（まだ有効ではありません）"
end

# 架台・段の候補（案 X 改。2026-11-08 ユーザー承認）の閾値を加えた版。基準温度の取り方は 2026-11-trend-provisional と同じ。
# 自動では有効にしない。本番で有効にするのは、業者の報告書・次の点検データと比べてから（ユーザー指示）
row_version = "2026-11-trend-row-provisional"
unless RuleSet.exists?(version: row_version)
  source = RuleSet.find_by!(version: trend_version)
  copy = source.duplicate(version: row_version)
  copy.note = "暫定: 2026-11-trend-provisional に架台・段の候補（block_row）を加えた版。" \
              "候補の閾値 +0.8℃ は飛行 008 の 1 回分（夏の夕方・日射量の記録なし）から決めた暫定値で、次の点検データで見直す。" \
              "注意 +1.5℃・重大 +3.0℃ は依頼元と合意するまでの仮の値。本番では有効にしない（業者の報告書・次の点検データと比べてから）"
  copy.severity_rules.build(anomaly_type: "block_row", measure: "row_effect",
                            normalized_mild: 0.8, normalized_warning: 1.5, normalized_critical: 3.0,
                            raw_mild: 0.8, raw_warning: 1.5, raw_critical: 3.0)
  copy.save!
  puts "ルールセット #{row_version} を作成しました（まだ有効ではありません）"
end
