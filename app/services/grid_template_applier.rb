# グリッドテンプレートを、撮影条件の近い画像に一括適用する
class GridTemplateApplier
  Result = Data.define(:applied, :has_grid, :out_of_tolerance, :missing_metadata, :not_ready) do
    def message
      parts = [ "#{applied.size} 枚に適用して解析を始めました" ]
      parts << "グリッド指定済みのため対象外 #{has_grid.size} 枚" if has_grid.any?
      parts << "撮影条件が許容差の外のため対象外 #{out_of_tolerance.size} 枚" if out_of_tolerance.any?
      parts << "高度・ジンバル角が不明のため対象外 #{missing_metadata.size} 枚" if missing_metadata.any?
      parts << "品質チェック未合格のため対象外 #{not_ready.size} 枚" if not_ready.any?
      parts.join("。")
    end
  end

  FIELDS = { "altitude_m" => :altitude_m, "gimbal_pitch_deg" => :gimbal_pitch, "gimbal_yaw_deg" => :gimbal_yaw }.freeze

  def initialize(template, tolerance)
    @template = template
    @tolerance = tolerance
  end

  def apply!
    buckets = { applied: [], has_grid: [], out_of_tolerance: [], missing_metadata: [], not_ready: [] }
    @template.inspection.inspection_images.each do |image|
      next if image.excluded?

      bucket =
        if !image.ready_for_analysis? then :not_ready
        elsif image.panel_grids.present? then :has_grid
        elsif missing_metadata?(image) then :missing_metadata
        elsif !within_tolerance?(image) then :out_of_tolerance
        else :applied
        end
      buckets[bucket] << image
    end

    buckets[:applied].each do |image|
      image.update!(panel_grids: [ grid ], analysis_status: "pending", review_reason: nil, error_message: nil)
      AnalyzeInspectionImageJob.perform_later(image.id)
    end
    Result.new(**buckets)
  end

  private

  def grid
    { "rows" => @template.rows, "cols" => @template.cols, "corners" => @template.corners,
      "panel_orientation" => @template.panel_orientation, "grid_template_id" => @template.id }
  end

  def missing_metadata?(image)
    FIELDS.values.any? { |attr| @template.public_send(attr).nil? || image.public_send(attr).nil? }
  end

  def within_tolerance?(image)
    FIELDS.all? do |key, attr|
      diff = (@template.public_send(attr) - image.public_send(attr)).abs
      diff = [ diff, 360 - diff ].min if attr == :gimbal_yaw # ヨー角は 360° で一周する
      diff <= @tolerance.fetch(key)
    end
  end
end
