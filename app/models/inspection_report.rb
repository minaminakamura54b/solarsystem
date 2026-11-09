# 報告書の版（docs/IMPROVEMENT_PLAN.md Phase 7）。発行後は変えない（改訂は新しい版で出し直す）
class InspectionReport < ApplicationRecord
  belongs_to :inspection
  has_one_attached :pdf # 顧客向けの報告書の PDF（版の固定コピーから作る。ReportPdf）
  has_one_attached :internal_pdf # 社内向けの作業記録の PDF（見直し R2。顧客には渡さない）

  validates :version_number, presence: true, uniqueness: { scope: :inspection_id }
  validates :issued_at, :content_digest, presence: true
  validates :revision_reason, presence: { message: "（改訂の理由）を入力してください" }, if: -> { version_number.to_i > 1 }
  validate :unchanged_after_issue, on: :update

  # 版は判断の記録なので削除しない
  before_destroy(prepend: true) { throw :abort }

  scope :latest_first, -> { order(version_number: :desc) }

  def title = "第 #{version_number} 版"

  def pdf_filename
    "熱異常スクリーニング報告書_#{snapshot['site_name']}_#{snapshot['inspection_date']}_第#{version_number}版.pdf"
  end

  def internal_pdf_filename
    "作業記録（社内向け）_#{snapshot['site_name']}_#{snapshot['inspection_date']}_第#{version_number}版.pdf"
  end

  private

  def unchanged_after_issue
    errors.add(:base, "発行した版は変えられません（改訂版を発行してください）") if (changed - %w[updated_at pdf_generated_at pdf_error internal_pdf_generated_at internal_pdf_error]).any?
  end
end
