# 人が確定した critical の異常・異常群について、アラートを1件だけ作る（docs/IMPROVEMENT_PLAN.md Phase 4-7）。
# - 確定（confirmed / corrected）していなければ作らない（生ΔT で判定した異常も、確定したときだけ）
# - 異常群の構成パネルの異常ごとには作らない（群として1件）
# - 同じ異常・群には重複して作らない
# 呼び出すのは Phase 5 のレビュー操作（確定・修正）
class ConfirmedAnomalyAlert
  CONFIRMED = %w[confirmed corrected].freeze

  def self.call(record)
    new(record).call
  end

  def initialize(record)
    @record = record
  end

  # 作成したアラート（作らなかったときは nil）
  def call
    return nil unless CONFIRMED.include?(@record.review_status)
    return nil unless final_severity == "critical"
    return nil if @record.is_a?(Anomaly) && @record.anomaly_group_id.present?

    key = @record.is_a?(AnomalyGroup) ? { anomaly_group: @record } : { anomaly: @record }
    return nil if Alert.exists?(key)

    Alert.create!(
      **key, site: @record.inspection.site, inspection: @record.inspection, panel: panel,
      severity: "critical", title: title, message: message
    )
  end

  private

  def final_severity
    @record.respond_to?(:final_severity) && @record.final_severity.present? ? @record.final_severity : @record.severity
  end

  def panel
    @record.is_a?(Anomaly) ? @record.panel : nil
  end

  def label
    if @record.is_a?(AnomalyGroup)
      "隣接パネル群（#{@record.panel_count}枚）"
    else
      RuleSetsHelper::ANOMALY_TYPE_LABELS.fetch(@record.respond_to?(:final_anomaly_type) && @record.final_anomaly_type.presence || @record.anomaly_type, @record.anomaly_type)
    end
  end

  def title
    "#{@record.inspection.conducted_at.strftime('%Y/%m/%d')} 点検: 重大な異常（#{label}）を確定"
  end

  def message
    delta = @record.threshold_basis == "normalized" ? "正規化ΔT #{@record.normalized_delta_t&.to_f}℃" : "ΔT #{@record.delta_t&.to_f}℃（未正規化）"
    "画像 #{@record.inspection_image.sequence}・パネル #{@record.try(:panel_index_in_image) || Array(@record.try(:panel_indices)).join(',')}。#{delta}"
  end
end
