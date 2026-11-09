# 点検の範囲（docs/IMPROVEMENT_PLAN.md Phase 7 の決定事項 2026-11-09）。
# - 写ったパネル: 解析できた画像（completed）の、位置合わせのグリッド（架台とつながったグリッド）に中心が入った登録パネル
# - 手動のグリッド（架台とつながっていない）の画像は、どのパネルが写ったかを位置で決められないため、写ったパネルに数えない
# - まとめて除外の前に、除外する画像の位置（位置合わせのグリッド、無ければ位置合わせの下書き）から、
#   「ほかの解析できた画像に写っていないパネル」が何枚あるか（＝除外すると写っていないまま残るパネル）を出す
# パネルへの割り当ては AnalysisResultImporter と同じ（グリッドの行＝段、列＝列）
class InspectionCoverage
  LAYOUT_SOURCES = AnalysisResultImporter::BASIS.keys.freeze

  Summary = Data.define(:registered, :covered, :layout_unlinked_images, :outside_layout_images) do
    def uncovered = registered - covered
  end

  Impact = Data.define(:images, :newly_uncovered, :unknown_position)

  def initialize(inspection)
    @inspection = inspection
    @images = inspection.inspection_images.reload.to_a # 判定には常に最新の状態を使う
  end

  def registered_keys
    @registered_keys ||= @inspection.site.panels.where.not(pv_block_id: nil).pluck(:pv_block_id, :block_row, :block_col).to_set
  end

  def covered_keys
    @covered_keys ||= @images.select(&:completed?).flat_map { |img| keys_in(layout_grids(img.panel_grids)) }.to_set & registered_keys
  end

  def summary
    completed = @images.select(&:completed?)
    Summary.new(
      registered: registered_keys.size,
      covered: covered_keys.size,
      layout_unlinked_images: completed.count { |img| layout_grids(img.panel_grids).empty? },
      outside_layout_images: @images.count { |img| img.alignment.to_h["review_reason"] == "no_blocks_in_view" }
    )
  end

  # images を除外したとき、写っていないまま残るパネルの数
  def exclusion_impact(images)
    footprints = images.map { |img| keys_in(footprint_grids(img)) }
    Impact.new(
      images: images.size,
      newly_uncovered: ((footprints.reduce(Set.new, :|) & registered_keys) - covered_keys).size,
      unknown_position: footprints.count(&:empty?)
    )
  end

  private

  def footprint_grids(image)
    grids = layout_grids(image.panel_grids)
    grids.presence || layout_grids(image.alignment.to_h["draft_grids"])
  end

  def layout_grids(grids)
    Array(grids).select { |g| g["pv_block_id"].present? && LAYOUT_SOURCES.include?(g["source"]) }
  end

  def keys_in(grids)
    grids.flat_map do |g|
      rows, cols, corners = g["rows"].to_i, g["cols"].to_i, g["corners"]
      next [] unless corners.is_a?(Array) && corners.size == 4

      (0...rows).flat_map do |r|
        (0...cols).filter_map do |c|
          x, y = bilinear(corners, (c + 0.5) / cols, (r + 0.5) / rows)
          [ g["pv_block_id"].to_i, r + 1, c + 1 ] if x.between?(0, 1) && y.between?(0, 1)
        end
      end
    end
  end

  # 4 隅（上端の始まり・上端の終わり・下端の終わり・下端の始まり）の中の (u, v) の位置
  def bilinear(c, u, v)
    top = [ c[0][0] + (c[1][0] - c[0][0]) * u, c[0][1] + (c[1][1] - c[0][1]) * u ]
    bottom = [ c[3][0] + (c[2][0] - c[3][0]) * u, c[3][1] + (c[2][1] - c[3][1]) * u ]
    [ top[0] + (bottom[0] - top[0]) * v, top[1] + (bottom[1] - top[1]) * v ]
  end
end
