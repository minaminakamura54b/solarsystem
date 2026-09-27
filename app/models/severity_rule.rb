# ルールセット内の、異常の種類ごとの閾値。作成後は編集できない
class SeverityRule < ApplicationRecord
  MEASURES = %w[region_max region_mean panel_mean].freeze
  SERIES = %w[normalized raw].freeze
  COPYABLE_ATTRIBUTES = %w[
    anomaly_type measure
    normalized_mild normalized_warning normalized_critical
    raw_mild raw_warning raw_critical
  ].freeze

  belongs_to :rule_set, inverse_of: :severity_rules

  validates :anomaly_type, inclusion: { in: RuleSet::ANOMALY_TYPES }
  validates :measure, inclusion: { in: MEASURES }
  validates(*COPYABLE_ATTRIBUTES.grep(/_(mild|warning|critical)\z/), presence: true, numericality: { greater_than: 0 })
  validate :thresholds_ascending

  def readonly?
    persisted? || super
  end

  private

  # 各系列で mild < warning < critical
  def thresholds_ascending
    SERIES.each do |series|
      values = %w[mild warning critical].map { |level| public_send("#{series}_#{level}") }
      next if values.any?(&:nil?)
      next if values.each_cons(2).all? { |a, b| a < b }

      label = series == "normalized" ? "正規化ΔT" : "生ΔT"
      errors.add(:base, "#{anomaly_type} の#{label}の閾値は mild < warning < critical にしてください")
    end
  end
end
