# 1パネル単位の異常（docs/IMPROVEMENT_PLAN.md 4.3）。作成は Phase 4 以降
class Anomaly < ApplicationRecord
  ANOMALY_TYPES = %w[hotspot multi_hotspot substring_bypass module_wide partial_module other].freeze
  SEVERITIES = %w[mild warning critical].freeze
  REVIEW_STATUSES = %w[pending confirmed corrected rejected].freeze
  EVIDENCE_LEVELS = %w[A B C].freeze

  belongs_to :inspection_image
  belongs_to :inspection
  belongs_to :anomaly_group, optional: true
  belongs_to :panel, optional: true
  belongs_to :rule_set, optional: true

  validates :anomaly_type, inclusion: { in: ANOMALY_TYPES }
  validates :severity, inclusion: { in: SEVERITIES }, allow_nil: true
  validates :review_status, inclusion: { in: REVIEW_STATUSES }
  validates :evidence_level, inclusion: { in: EVIDENCE_LEVELS }, allow_nil: true
  validates :detection, inclusion: { in: %w[local baseline manual] }, allow_nil: true # manual = レビューで人が追加した見逃し
  validates :rejection_reason, inclusion: { in: AnomalyReview::REJECTION_REASONS.keys }, allow_nil: true

  scope :candidates, -> { where(review_status: "pending") }
  # 件数・重大度の集計に使う異常（群の構成パネルは群を1件として数えるため除く。docs/IMPROVEMENT_PLAN.md 4.4）
  scope :countable, -> { where(anomaly_group_id: nil) }

  # 修正後の値（無ければ元の値）
  def effective_type = final_anomaly_type.presence || anomaly_type
  def effective_bbox = final_bbox.presence || bbox
  def effective_severity = final_severity.presence || severity

  # 実配置の置き換えで外れた、最後のパネルの紐付け（panel_assignment_history の reason layout_replaced）
  def last_layout_unassignment
    panel_assignment_history.reverse.find { |entry| entry["reason"] == "layout_replaced" } || {}
  end
end
