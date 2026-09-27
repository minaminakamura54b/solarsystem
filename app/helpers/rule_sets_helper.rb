module RuleSetsHelper
  ANOMALY_TYPE_LABELS = {
    "hotspot" => "ホットスポット", "multi_hotspot" => "複数ホットスポット",
    "substring_bypass" => "サブストリングのバイパス", "module_wide" => "モジュール全体",
    "partial_module" => "部分的な発熱", "panel_row_group" => "隣接パネル群"
  }.freeze

  MEASURE_LABELS = {
    "region_max" => "高温領域の最高温度", "region_mean" => "高温領域の平均温度", "panel_mean" => "パネル平均温度"
  }.freeze

  def anomaly_type_label(type)
    ANOMALY_TYPE_LABELS.fetch(type, type)
  end

  def measure_label(measure)
    MEASURE_LABELS.fetch(measure, measure)
  end
end
