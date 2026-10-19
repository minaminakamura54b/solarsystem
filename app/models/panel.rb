class Panel < ApplicationRecord
  belongs_to :site
  has_many :alerts, dependent: :nullify
  # 異常が紐付いたパネルは消さない（実配置の置き換えでは、先に紐付けを外して履歴に残す。PanelLayoutImport）
  has_many :anomalies, dependent: :restrict_with_exception

  STATUSES = %w[normal warning error stopped].freeze

  validates :number, presence: true, uniqueness: { scope: :site_id }
  validates :position_x, :position_y, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :abnormal, -> { where.not(status: "normal") }
  scope :by_position, -> { order(:position_y, :position_x) }

  # 発電所の登録時に自動生成した仮配置（実際の配置ではない）
  def placeholder_layout?
    layout_source == "auto"
  end

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
