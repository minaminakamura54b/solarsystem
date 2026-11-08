# 架台・段の候補（案 X 改。2026-11-08 ユーザー承認）。作り直しは BlockRowEffect、レビューは BlockRowReview。
# status = insufficient（判断の材料が足りない）は正常ではない（理由つきで表示する）
class BlockRowFinding < ApplicationRecord
  belongs_to :inspection
  belongs_to :pv_block
  belongs_to :rule_set, optional: true

  STATUSES = %w[evaluated insufficient].freeze
  validates :status, inclusion: { in: STATUSES }

  scope :candidates, -> { where(status: "evaluated").where.not(severity: nil) }
  scope :insufficient, -> { where(status: "insufficient") }

  def candidate? = status == "evaluated" && severity.present?
  def pending? = review_status == "pending"
  def label = "#{pv_block.label} #{block_row} 段目"
end
