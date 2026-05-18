class Site < ApplicationRecord
  has_many :panels, dependent: :destroy
  has_many :inspections, dependent: :destroy
  has_many :revenues, dependent: :destroy
  has_many :alerts, dependent: :destroy

  validates :name, presence: true
  validates :location, presence: true
  validates :panel_count, numericality: { greater_than_or_equal_to: 0 }
  validates :capacity_kw, numericality: { greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: %w[active inactive maintenance] }

  enum :status, { active: "active", inactive: "inactive", maintenance: "maintenance" }, prefix: true

  scope :active, -> { where(status: "active") }

  def panel_status_summary
    panels.group(:status).count
  end

  def latest_inspection
    inspections.order(conducted_at: :desc).first
  end

  def unread_alerts_count
    alerts.where(read_at: nil).count
  end

  def recent_revenue(months: 7)
    revenues.where(year: (Date.today - months.months)..Date.today)
            .order(:year, :month)
  end
end
