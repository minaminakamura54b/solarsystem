# ルールセットの閾値で異常・異常群に重大度（mild / warning / critical）を付ける（docs/IMPROVEMENT_PLAN.md Phase 4-5）。
# 判定に使った値は threshold_basis による（normalized = 正規化ΔT、raw = 生ΔT）。
# 人が確定・修正・却下した異常（locked）は変えない。判定時のルールセットとその閾値のコピーを保存する
class SeverityRuleEngine
  def initialize(rule_set)
    @rule_set = rule_set
  end

  # 重大度を付ける（保存はしない）。locked なら何もしない
  def apply(record)
    return record if record.locked?

    rule = @rule_set.rule_for(record.is_a?(AnomalyGroup) ? record.group_type : record.anomaly_type)
    record.severity = rule && severity(rule, record)
    record.rule_set = @rule_set
    record.rule_version = @rule_set.version
    record.rule_snapshot = rule&.snapshot
    record
  end

  # 点検内の未確定の異常・群を、このルールセットで判定し直す（明示的な操作のときだけ呼ぶ）。
  # mild を下げても新しい候補は増えない（解析エンジンは mild 未満を出力しないため。増やすには再解析が必要）
  def rejudge!(inspection)
    count = 0
    ActiveRecord::Base.transaction do
      (inspection.anomalies.where(locked: false) + inspection.anomaly_groups.where(locked: false)).each do |record|
        apply(record).save!
        count += 1
      end
    end
    count
  end

  # mild 未満なら nil（判定時より mild を上げて判定し直した場合に起こりうる）
  def severity(rule, record)
    basis = record.threshold_basis == "normalized" ? "normalized" : "raw"
    value = basis == "normalized" ? record.normalized_delta_t : record.delta_t
    return nil if value.nil?

    if value >= rule.public_send("#{basis}_critical") then "critical"
    elsif value >= rule.public_send("#{basis}_warning") then "warning"
    elsif value >= rule.public_send("#{basis}_mild") then "mild"
    end
  end
end
