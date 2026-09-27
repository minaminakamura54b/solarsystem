class Inspection < ApplicationRecord
  belongs_to :site
  has_one_attached :image # 旧方式（画像1枚・Claude 判定）の点検だけが使う
  has_one_attached :report_pdf
  has_many :alerts, dependent: :destroy
  has_many :inspection_images, -> { ordered }, dependent: :destroy, inverse_of: :inspection
  has_many :weather_readings, -> { chronological }, dependent: :destroy
  has_many :grid_templates, dependent: :destroy
  has_many :anomaly_groups, dependent: :destroy
  has_many :anomalies, dependent: :destroy

  SEVERITIES = %w[normal warning critical].freeze
  ANALYSIS_STATUSES = %w[pending analyzing completed needs_review failed].freeze

  validates :conducted_at, presence: true
  # severity は解析が完了したときだけ必須。失敗・未解析は nil（判定なし）で、normal にはしない
  validates :severity, inclusion: { in: SEVERITIES }, allow_nil: true
  validates :severity, presence: true, if: :completed?
  validates :analysis_status, inclusion: { in: ANALYSIS_STATUSES }
  validate :images_must_be_present, on: :create

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

  def needs_review?
    analysis_status == "needs_review"
  end

  # 旧方式（画像1枚を Claude に判定させる方式）で作られた点検。新方式の点検は必ず画像（inspection_images）を持つ
  def legacy?
    inspection_images.empty?
  end

  # 画面を自動更新すべきか。
  # 旧方式は解析待ち・解析中の間。新方式は、品質チェック待ちの画像がある間
  # （品質チェック済みで解析エンジンを待っている画像は、Phase 4 までは自動更新の対象にしない）
  def in_progress?
    return pending? || analyzing? if legacy?

    inspection_images.any?(&:quality_pending?) || inspection_images.any?(&:analyzing?)
  end

  # 画像のステータスから点検全体のステータスを集計する（docs/IMPROVEMENT_PLAN.md セクション2）。
  # excluded の画像は集計に含めない。判定（severity）は Phase 4 以降で確定済みの異常から付ける
  def aggregated_status
    statuses = inspection_images.map(&:analysis_status) - [ "excluded" ]
    return "needs_review" if statuses.empty? && inspection_images.any?
    return "pending" if statuses.empty?
    return "analyzing" if statuses.intersect?(%w[pending analyzing])
    return "failed" if statuses.include?("failed")
    return "needs_review" if statuses.include?("needs_review")

    "completed"
  end

  def refresh_status!
    status = aggregated_status
    # completed にするときは確定済みの異常から severity を付ける必要がある（Phase 4 で実装）。
    # Phase 2 では画像が completed になる経路がないため、ここでは completed にしない
    return if status == analysis_status || status == "completed"

    update_columns(analysis_status: status, updated_at: Time.current)
  end

  # 品質チェックに合格し、解析エンジン（Phase 4 で接続）を待っている画像の数
  def images_waiting_for_analyzer
    inspection_images.count { |i| i.pending? && !i.quality_pending? }
  end

  def image_status_counts
    inspection_images.map(&:analysis_status).tally
  end

  # フォームに表示するエラー。画像ごとのエラーは「画像 N（ファイル名）: 理由」にする
  def display_error_messages
    own = errors.reject { |e| e.attribute == :inspection_images }.map(&:full_message)
    images = inspection_images.flat_map do |image|
      image.errors.full_messages.map { |m| "画像 #{image.sequence}（#{image.thermal_filename}）: #{m}" }
    end
    own + images
  end

  private

  def images_must_be_present
    errors.add(:base, "サーモ画像を1枚以上選択してください") if inspection_images.empty? && !image.attached?
  end
end
