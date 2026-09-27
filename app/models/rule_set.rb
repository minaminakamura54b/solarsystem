# 重大度の閾値と検出パラメータの組（docs/IMPROVEMENT_PLAN.md 4.5）。
# 作成後は編集できない（active の切り替えだけできる）。閾値を変えるときは新しいルールセットを作る
class RuleSet < ApplicationRecord
  ANOMALY_TYPES = %w[hotspot multi_hotspot substring_bypass module_wide partial_module panel_row_group].freeze
  DETECTION_PARAM_KEYS = %w[
    panel_mad_k panel_mad_floor_c min_region_offset_c
    baseline_mad_k baseline_mad_floor_c baseline_min_panels baseline_min_ratio
    row_group_min_panels
  ].freeze

  # 作成フォームで検出パラメータを JSON 文字列として受け取るための仮想属性
  attr_accessor :detection_params_json

  has_many :severity_rules, -> { order(:id) }, inverse_of: :rule_set
  accepts_nested_attributes_for :severity_rules

  validates :version, presence: true, uniqueness: true
  validate :all_anomaly_types_present
  validate :detection_params_complete
  validate :only_active_can_change, on: :update

  # 判定の根拠として参照されるため削除しない
  before_destroy(prepend: true) { throw :abort }

  scope :recent, -> { order(created_at: :desc) }

  def self.active_set
    find_by(active: true)
  end

  # 他のルールセットを無効にしてから、このルールセットを有効にする
  def activate!
    transaction do
      RuleSet.where.not(id: id).where(active: true).update_all(active: false, updated_at: Time.current)
      update!(active: true)
    end
  end

  # 既存のルールセットを複製した、新しいルールセット（未保存）
  def duplicate(version:)
    RuleSet.new(version: version, detection_params: detection_params.deep_dup).tap do |copy|
      severity_rules.each do |rule|
        copy.severity_rules.build(rule.attributes.slice(*SeverityRule::COPYABLE_ATTRIBUTES))
      end
    end
  end

  def rule_for(anomaly_type)
    severity_rules.find { |r| r.anomaly_type == anomaly_type }
  end

  private

  def all_anomaly_types_present
    types = severity_rules.map(&:anomaly_type)
    missing = ANOMALY_TYPES - types
    errors.add(:base, "閾値が未設定の種類があります: #{missing.join(', ')}") if missing.any?
    errors.add(:base, "同じ種類の閾値が重複しています") if types.size != types.uniq.size
  end

  def detection_params_complete
    params = detection_params.is_a?(Hash) ? detection_params : {}
    missing = DETECTION_PARAM_KEYS.reject { |k| params[k].is_a?(Numeric) }
    errors.add(:detection_params, "に数値が未設定の項目があります: #{missing.join(', ')}") if missing.any?
  end

  def only_active_can_change
    changed_keys = changed - %w[active updated_at]
    errors.add(:base, "作成済みのルールセットは編集できません（新しいルールセットを作成してください）") if changed_keys.any?
  end
end
