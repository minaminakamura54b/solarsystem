# 点検の範囲（docs/IMPROVEMENT_PLAN.md Phase 7 の決定事項 2026-11-09・見直し R1）。
# - 対象のパネル: 点検の対象範囲（確定した架台）のパネル。対象範囲を確定していなければ、発電所に登録したパネルすべて
# - 写ったパネル: 解析できた画像（completed）の、位置合わせのグリッド（架台とつながったグリッド）に中心が入った対象のパネル
# - 手動のグリッド（架台とつながっていない）の画像は、どのパネルが写ったかを位置で決められないため、写ったパネルに数えない
# - まとめて除外の前に、除外する画像の位置（位置合わせのグリッド、無ければ位置合わせの下書き）から、
#   「ほかの解析できた画像に写っていないパネル」が何枚あるか（＝除外すると写っていないまま残るパネル）を出す
# パネルへの割り当ては AnalysisResultImporter と同じ（グリッドの行＝段、列＝列）
class InspectionCoverage
  Summary = Data.define(:registered, :covered, :layout_unlinked_images, :outside_layout_images, :scope_confirmed, :scope_blocks) do
    def uncovered = registered - covered
  end

  Impact = Data.define(:images, :newly_uncovered, :unknown_position)

  def initialize(inspection)
    @inspection = inspection
    @images = inspection.inspection_images.reload.to_a # 判定には常に最新の状態を使う
  end

  # 対象のパネル（対象範囲を確定していなければ発電所のすべて）
  def registered_keys
    @registered_keys ||= begin
      panels = @inspection.site.panels.where.not(pv_block_id: nil)
      panels = panels.where(pv_block_id: @inspection.scope_block_ids) if @inspection.scope_confirmed?
      panels.pluck(:pv_block_id, :block_row, :block_col).to_set
    end
  end

  def covered_keys
    @covered_keys ||= @images.select(&:completed?).flat_map { |img| GridGeometry.panel_keys(GridGeometry.layout_grids(img.panel_grids)) }.to_set & registered_keys
  end

  def summary
    completed = @images.select(&:completed?)
    Summary.new(
      registered: registered_keys.size,
      covered: covered_keys.size,
      layout_unlinked_images: completed.count { |img| GridGeometry.layout_grids(img.panel_grids).empty? },
      outside_layout_images: @images.count { |img| img.alignment.to_h["review_reason"] == "no_blocks_in_view" },
      scope_confirmed: @inspection.scope_confirmed?,
      scope_blocks: @inspection.scope_confirmed? ? Array(@inspection.scope_block_ids).size : @inspection.site.pv_blocks.count
    )
  end

  # images を除外したとき、写っていないまま残るパネルの数
  def exclusion_impact(images)
    footprints = images.map { |img| GridGeometry.panel_keys(footprint_grids(img)) }
    Impact.new(
      images: images.size,
      newly_uncovered: ((footprints.reduce(Set.new, :|) & registered_keys) - covered_keys).size,
      unknown_position: footprints.count(&:empty?)
    )
  end

  private

  def footprint_grids(image)
    grids = GridGeometry.layout_grids(image.panel_grids)
    grids.presence || GridGeometry.layout_grids(image.alignment.to_h["draft_grids"])
  end
end
