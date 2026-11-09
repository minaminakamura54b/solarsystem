# 報告書の版（docs/IMPROVEMENT_PLAN.md Phase 7）。発行後は変えない（改訂は新しい版で出し直す）
class InspectionReport < ApplicationRecord
  belongs_to :inspection

  validates :version_number, presence: true, uniqueness: { scope: :inspection_id }
  validates :issued_at, :content_digest, presence: true
  validates :revision_reason, presence: { message: "（改訂の理由）を入力してください" }, if: -> { version_number.to_i > 1 }
  validate :unchanged_after_issue, on: :update

  # 版は判断の記録なので削除しない
  before_destroy(prepend: true) { throw :abort }

  scope :latest_first, -> { order(version_number: :desc) }

  def title = "第 #{version_number} 版"

  private

  def unchanged_after_issue
    errors.add(:base, "発行した版は変えられません（改訂版を発行してください）") if (changed - %w[updated_at]).any?
  end
end
