class Inspection < ApplicationRecord
  belongs_to :site
  has_one_attached :image
  has_many :alerts, dependent: :destroy

  SEVERITIES = %w[normal warning critical].freeze
  ANALYSIS_STATUSES = %w[pending analyzing completed failed].freeze

  validates :conducted_at, presence: true
  # severity は解析が完了したときだけ必須。失敗・未解析は nil（判定なし）で、normal にはしない
  validates :severity, inclusion: { in: SEVERITIES }, allow_nil: true
  validates :severity, presence: true, if: :completed?
  validates :analysis_status, inclusion: { in: ANALYSIS_STATUSES }
  validate :image_must_be_attached, on: :create

  scope :completed, -> { where(analysis_status: "completed") }
  scope :recent, -> { order(conducted_at: :desc) }

  def severity_label
    { "normal" => "正常", "warning" => "注意", "critical" => "重大" }.fetch(severity, "判定なし")
  end

  def severity_color_class
    { "normal" => "badge-success", "warning" => "badge-warning", "critical" => "badge-error" }.fetch(severity, "badge-gray")
  end

  def pending?
    analysis_status == "pending"
  end

  def analyzing?
    analysis_status == "analyzing"
  end

  def completed?
    analysis_status == "completed"
  end

  def failed?
    analysis_status == "failed"
  end

  # 解析待ち・解析中（自動更新の対象）
  def in_progress?
    pending? || analyzing?
  end

  private

  def image_must_be_attached
    errors.add(:base, "画像を選択してください") unless image.attached?
  end
end
