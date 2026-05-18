class Inspection < ApplicationRecord
  belongs_to :site
  has_one_attached :image
  has_many :alerts, dependent: :destroy

  SEVERITIES = %w[normal warning critical].freeze
  ANALYSIS_STATUSES = %w[pending analyzing completed failed].freeze

  validates :conducted_at, presence: true
  validates :severity, inclusion: { in: SEVERITIES }
  validates :analysis_status, inclusion: { in: ANALYSIS_STATUSES }

  scope :completed, -> { where(analysis_status: "completed") }
  scope :recent, -> { order(conducted_at: :desc) }

  def severity_label
    { "normal" => "正常", "warning" => "注意", "critical" => "重大" }[severity]
  end

  def severity_color_class
    { "normal" => "badge-success", "warning" => "badge-warning", "critical" => "badge-error" }[severity]
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
end
