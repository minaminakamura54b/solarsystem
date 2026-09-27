# 複数パネルにまたがる異常（docs/IMPROVEMENT_PLAN.md 4.4）。作成は Phase 4 以降
class AnomalyGroup < ApplicationRecord
  GROUP_TYPES = %w[panel_row_group].freeze
  REVIEW_STATUSES = %w[pending confirmed corrected rejected].freeze

  belongs_to :inspection_image
  belongs_to :inspection
  belongs_to :rule_set, optional: true
  has_many :anomalies, dependent: :nullify

  validates :group_type, inclusion: { in: GROUP_TYPES }
  validates :review_status, inclusion: { in: REVIEW_STATUSES }
end
