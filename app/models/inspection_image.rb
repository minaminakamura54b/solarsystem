# 点検（セッション）に含まれる画像1枚（サーモ画像の原本と、任意で同時撮影の RGB）。
# docs/IMPROVEMENT_PLAN.md 4.1 / セクション2
class InspectionImage < ApplicationRecord
  ANALYSIS_STATUSES = %w[pending analyzing completed needs_review failed excluded].freeze
  IRRADIANCE_TYPES = WeatherReading::IRRADIANCE_TYPES

  belongs_to :inspection
  has_one_attached :thermal # R-JPEG の原本。変換・縮小しない
  has_one_attached :rgb
  has_many :anomalies, dependent: :destroy
  has_many :anomaly_groups, dependent: :destroy

  validates :sequence, presence: true, uniqueness: { scope: :inspection_id }
  validates :analysis_status, inclusion: { in: ANALYSIS_STATUSES }
  validates :irradiance_type, inclusion: { in: IRRADIANCE_TYPES }, allow_nil: true
  validates :exclusion_note, presence: { message: "（除外の理由）を入力してください" }, if: :excluded?
  validate :thermal_must_be_attached, on: :create

  scope :ordered, -> { order(:sequence) }

  ANALYSIS_STATUSES.each do |status|
    define_method("#{status}?") { analysis_status == status }
  end

  # 品質チェックがまだ終わっていない（メタデータ読み取り・品質チェックのジョブ待ち）
  def quality_pending?
    quality_report.nil? && !excluded?
  end

  def quality_status
    quality_report&.dig("status")
  end

  # needs_review / failed の画像だけを、理由付きで「この点検では使わない」にできる
  def exclude!(note)
    raise ArgumentError, "除外できるのは要確認・失敗の画像だけです" unless needs_review? || failed?

    update!(analysis_status: "excluded", exclusion_note: note.presence)
    inspection.refresh_status!
  end

  # 除外を取り消し、品質チェック結果に応じたステータスに戻す
  def unexclude!
    raise ArgumentError, "除外されていません" unless excluded?

    update!(analysis_status: status_from_quality, exclusion_note: nil)
    inspection.refresh_status!
  end

  # 品質チェックの結果から決まるステータス
  def status_from_quality
    return "failed" if error_message.present? && quality_report.nil?
    return "needs_review" if quality_status == "rejected"

    "pending"
  end

  private

  def thermal_must_be_attached
    if !thermal.attached?
      errors.add(:base, "サーモ画像を添付してください")
    elsif !thermal.blob.content_type.to_s.start_with?("image/")
      errors.add(:base, "#{thermal.blob.filename} は画像ファイルではありません")
    end
  end
end
