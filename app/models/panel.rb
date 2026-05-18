class Panel < ApplicationRecord
  belongs_to :site
  has_many :alerts, dependent: :nullify

  STATUSES = %w[normal warning error stopped].freeze

  validates :number, presence: true, uniqueness: { scope: :site_id }
  validates :position_x, :position_y, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :abnormal, -> { where.not(status: "normal") }
  scope :by_position, -> { order(:position_y, :position_x) }

  def status_color
    case status
    when "normal"  then "#22c55e"
    when "warning" then "#f59e0b"
    when "error"   then "#ef4444"
    when "stopped" then "#6b7280"
    end
  end

  def status_label
    { "normal" => "正常", "warning" => "注意", "error" => "異常", "stopped" => "停止" }[status]
  end
end
