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

  CELL_LAYOUTS = %w[full_cell half_cut other].freeze
  validates :cell_layout, inclusion: { in: CELL_LAYOUTS }, allow_blank: true
  validates :module_rated_w, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :substring_count, numericality: { only_integer: true, greater_than: 0 }
  validate :bypass_pattern_json_valid

  enum :status, { active: "active", inactive: "inactive", maintenance: "maintenance" }, prefix: true

  scope :active, -> { where(status: "active") }

  # フォームで編集する bypass_pattern の JSON 文字列
  def bypass_pattern_json
    @bypass_pattern_json || (bypass_pattern.present? ? JSON.pretty_generate(bypass_pattern) : "")
  end

  def bypass_pattern_json=(value)
    @bypass_pattern_json = value.to_s
    @bypass_pattern_json_error = nil
    if @bypass_pattern_json.strip.empty?
      self.bypass_pattern = nil
    else
      parsed = JSON.parse(@bypass_pattern_json)
      parsed.is_a?(Hash) ? self.bypass_pattern = parsed : @bypass_pattern_json_error = "はオブジェクト（{ ... }）で入力してください"
    end
  rescue JSON::ParserError => e
    @bypass_pattern_json_error = "の JSON を読めません: #{e.message}"
  end

  def cell_layout=(value)
    super(value.presence)
  end

  # パネルがすべて自動生成の仮配置か
  def panels_placeholder_layout?
    panels.exists? && !panels.where.not(layout_source: "auto").exists?
  end

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

  private

  def bypass_pattern_json_valid
    errors.add(:bypass_pattern, @bypass_pattern_json_error) if @bypass_pattern_json_error
  end
end
