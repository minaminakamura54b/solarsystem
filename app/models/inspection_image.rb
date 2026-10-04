# 点検（セッション）に含まれる画像1枚（サーモ画像の原本と、任意で同時撮影の RGB）。
# docs/IMPROVEMENT_PLAN.md 4.1 / セクション2
class InspectionImage < ApplicationRecord
  ANALYSIS_STATUSES = %w[pending analyzing completed needs_review failed excluded].freeze
  IRRADIANCE_TYPES = WeatherReading::IRRADIANCE_TYPES

  belongs_to :inspection
  has_one_attached :thermal # R-JPEG の原本。変換・縮小しない
  has_one_attached :rgb
  has_one_attached :preview # 画面表示用の画像（.npy の合成データなど、ブラウザで表示できないサーモ画像のとき）
  has_many :anomalies, dependent: :destroy
  has_many :anomaly_groups, dependent: :destroy

  validates :sequence, presence: true, uniqueness: { scope: :inspection_id }
  validates :analysis_status, inclusion: { in: ANALYSIS_STATUSES }
  validates :irradiance_type, inclusion: { in: IRRADIANCE_TYPES }, allow_nil: true
  validates :exclusion_note, presence: { message: "（除外の理由）を入力してください" }, if: :excluded?
  validate :thermal_must_be_attached, on: :create
  validate :panel_grids_format

  scope :ordered, -> { order(:sequence) }

  ANALYSIS_STATUSES.each do |status|
    define_method("#{status}?") { analysis_status == status }
  end

  # 品質チェックがまだ終わっていない（メタデータ読み取り・品質チェックのジョブ待ち）
  def quality_pending?
    quality_report.nil? && !excluded?
  end

  # 品質チェックに合格（ok / warning）していて、解析に進める
  def ready_for_analysis?
    !excluded? && thermal.attached? && %w[ok warning].include?(quality_status)
  end

  # 画面に表示する画像（プレビューがあればそれ、無ければサーモ画像そのもの）
  def display_image
    preview.attached? ? preview : thermal
  end

  # 画像のピクセルサイズ（グリッド入力画面で使う）
  def pixel_size
    [ width || raw_analysis&.dig("image", "width"), height || raw_analysis&.dig("image", "height") ]
  end

  def anomaly_candidates_count
    anomalies.where(review_status: "pending").count
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
    InspectionImagePipeline.after_quality(self)
    inspection.refresh_status!
  end

  # 品質チェックの結果から決まるステータス（合格なら pending。その後の段階は InspectionImagePipeline が決める）
  def status_from_quality
    return "failed" if error_message.present? && quality_report.nil?
    return "needs_review" if quality_status == "rejected"

    "pending"
  end

  GRID_ORIENTATIONS = %w[portrait landscape].freeze

  # グリッド入力画面から受け取ったグリッドを正規化する（不正なら ArgumentError）
  def self.normalize_grids(grids)
    raise ArgumentError, "グリッドは配列で指定してください" unless grids.is_a?(Array)

    grids.map.with_index(1) do |grid, n|
      grid = grid.to_h.stringify_keys
      rows = Integer(grid["rows"], exception: false)
      cols = Integer(grid["cols"], exception: false)
      corners = Array(grid["corners"]).map { |pt| Array(pt).map { |v| Float(v, exception: false) } }
      raise ArgumentError, "グリッド #{n}: 行数・列数は1以上の整数にしてください" unless rows&.positive? && cols&.positive? && rows <= 200 && cols <= 200
      unless corners.size == 4 && corners.all? { |pt| pt.size == 2 && pt.all? { |v| v && v.between?(-1, 2) } }
        raise ArgumentError, "グリッド #{n}: 4隅の座標が不正です"
      end
      orientation = grid["panel_orientation"].presence || "landscape"
      raise ArgumentError, "グリッド #{n}: パネルの向きが不正です" unless GRID_ORIENTATIONS.include?(orientation)

      {
        "rows" => rows, "cols" => cols, "corners" => corners.map { |x, y| [ x.round(6), y.round(6) ] },
        "panel_orientation" => orientation, "grid_template_id" => grid["grid_template_id"].presence&.to_i
      }.compact
    end
  end

  private

  def thermal_must_be_attached
    if !thermal.attached?
      errors.add(:base, "サーモ画像を添付してください")
    elsif npy_thermal?
      errors.add(:base, ".npy は開発・テスト環境でのみ登録できます") unless AnalyzerConfig.current.allow_npy_thermal?
    elsif !thermal.blob.content_type.to_s.start_with?("image/")
      errors.add(:base, "#{thermal.blob.filename} は画像ファイルではありません")
    end
  end

  # 合成の温度行列（.npy）。開発・テスト用（config/analyzer.yml の allow_npy_thermal）
  def npy_thermal?
    thermal.attached? && thermal.blob.filename.extension.to_s.casecmp?("npy")
  end

  def panel_grids_format
    return if panel_grids.blank?

    self.class.normalize_grids(panel_grids)
  rescue ArgumentError => e
    errors.add(:panel_grids, e.message)
  end
end
