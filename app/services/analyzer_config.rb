# config/analyzer.yml の読み込み
class AnalyzerConfig
  attr_reader :command, :working_dir, :timeout_seconds, :schema_version, :stale_after_minutes, :template_match,
              :locked_overlap_iou, :measurement_ranges

  def self.current
    new(Rails.application.config_for(:analyzer))
  end

  def initialize(values)
    values = values.to_h.with_indifferent_access
    @command = Array(values.fetch(:command)).map(&:to_s)
    @working_dir = Rails.root.join(values.fetch(:working_dir)).to_s
    @timeout_seconds = values.fetch(:timeout_seconds).to_f
    @schema_version = values.fetch(:schema_version).to_s
    @stale_after_minutes = values.fetch(:stale_after_minutes).to_i
    @template_match = values.fetch(:template_match).to_h.transform_keys(&:to_s).transform_values(&:to_f)
    @allow_npy_thermal = values.fetch(:allow_npy_thermal, false)
    @locked_overlap_iou = values.fetch(:locked_overlap_iou, 0.5).to_f
    @measurement_ranges = values.fetch(:measurement_ranges, {}).to_h.to_h { |key, range| [ key.to_s, range.map(&:to_f) ] }
  end

  # 測定パラメータ（emissivity など）が SDK の受け付ける範囲にあるか
  def measurement_in_range?(key, value)
    low, high = measurement_ranges.fetch(key.to_s)
    value.to_f.between?(low, high)
  end

  def allow_npy_thermal?
    @allow_npy_thermal == true
  end
end
