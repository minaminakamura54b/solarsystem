class Alert < ApplicationRecord
  belongs_to :site
  belongs_to :inspection, optional: true
  belongs_to :panel, optional: true

  SEVERITIES = %w[info warning critical].freeze

  validates :title, presence: true
  validates :severity, inclusion: { in: SEVERITIES }

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  def read?
    read_at.present?
  end

  def mark_as_read!
    update!(read_at: Time.current) unless read?
  end

  def severity_color_class
    { "info" => "badge-info", "warning" => "badge-warning", "critical" => "badge-error" }[severity]
  end

  def severity_label
    { "info" => "情報", "warning" => "注意", "critical" => "重大" }[severity]
  end
end