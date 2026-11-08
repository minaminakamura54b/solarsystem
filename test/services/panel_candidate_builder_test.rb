require "test_helper"

# パネルの候補（同じパネルの同じ場所の異常を束ねる）。架台・解析結果・異常はすべて合成
class PanelCandidateBuilderTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg thermal_plain_T.jpg thermal_plain_T.jpg])
    @site = @inspection.site
    @blocks = register_blocks(@site, %w[A01 A02])
    @i1, @i2, @i3 = @inspection.inspection_images.order(:sequence).to_a
    analyzed_image(@i1, @blocks.values, y0: 0.75) # 画像の下側
    analyzed_image(@i2, @blocks.values, y0: 0.7)
    analyzed_image(@i3, @blocks.values, y0: 0.1)  # 画像の上側
  end

  def build = PanelCandidateBuilder.new(@inspection).call

  test "同じパネルの面状の発熱は 1 つに束ね、N 枚中 M 枚を記録する。下側でだけ出ていれば「写る位置で変わる」" do
    anomaly_at(@i1, 0, 2, 3)
    anomaly_at(@i2, 0, 2, 3, type: "module_wide")

    c = build.sole
    assert_equal [ "A01-2-03", "area", 2, 3 ], [ c.panel.number, c.kind, c.observed_count, c.visible_count ]
    assert_includes c.flags, "position_biased"
    assert_equal 2, c.anomalies.count
    assert_equal [ true, true, false ], c.observations.map { |o| o["positive"] }
    assert_equal PanelCandidateConfig.current.version, c.config_version
  end

  test "点状の発熱はパネルの中の位置が近ければ束ね、離れていれば分ける。3 枚以上に写って 1 枚だけなら「1 枚だけ」" do
    anomaly_at(@i1, 0, 1, 5, type: "hotspot", u: 0.2, v: 0.2)
    anomaly_at(@i2, 0, 1, 5, type: "hotspot", u: 0.25, v: 0.3)
    anomaly_at(@i3, 0, 1, 5, type: "hotspot", u: 0.8, v: 0.8)

    candidates = build.sort_by(&:observed_count)
    assert_equal [ 1, 2 ], candidates.map(&:observed_count)
    assert_includes candidates.first.flags, "single_view"
    assert_in_delta 0.8, candidates.first.location["u"], 0.05
  end

  test "点状の発熱が多くの架台の同じ位置に出ていれば「多くの架台の同じ位置」" do
    register_blocks(@site, %w[A01 A02 A03]) # 3 つの架台
    blocks = @site.pv_blocks.order(:label).to_a
    analyzed_image(@i1, blocks.first(2), y0: 0.4)
    analyzed_image(@i2, blocks.last(2), y0: 0.4)
    anomaly_at(@i1, 0, 1, 1, type: "multi_hotspot", u: 0.1, v: 0.5)
    anomaly_at(@i1, 1, 1, 1, type: "multi_hotspot", u: 0.1, v: 0.5)
    anomaly_at(@i2, 1, 1, 1, type: "multi_hotspot", u: 0.12, v: 0.5)
    anomaly_at(@i2, 0, 2, 6, type: "hotspot", u: 0.6, v: 0.6) # 別の位置

    flagged = build.select { |c| c.flags.include?("same_position") }
    assert_equal %w[A01-1-01 A02-1-01 A03-1-01], flagged.map { |c| c.panel.number }.sort
  end

  test "人が判断した候補は作り直さない。群の構成パネル・パネル未割り当ての異常は束ねない" do
    a = anomaly_at(@i1, 0, 2, 3)
    first = build.sole
    first.update!(review_status: "rejected", locked: true, rejection_reason: "glare")
    anomaly_at(@i2, 0, 1, 1).update!(panel: nil)
    group = @i2.anomaly_groups.create!(inspection: @inspection, group_type: "panel_row_group", panel_count: 3, panel_indices: [ 1, 2, 3 ])
    anomaly_at(@i2, 0, 1, 2, type: "module_wide", anomaly_group: group)

    assert_empty build
    assert_equal [ first.id ], @inspection.panel_candidates.pluck(:id)
    assert_equal first.id, a.reload.panel_candidate_id
  end

  test "点検の最後の画像の解析が終わったら、パネルの候補を作る" do
    anomaly_at(@i1, 0, 2, 3)
    @i3.update_columns(analysis_status: "pending", quality_report: { "status" => "ok", "checks" => [] })
    output = analyzer_output(anomalies: [])
    with_fake_analyzer(analyze: analyzer_result(output:)) do
      load_initial_rule_set
      AnalyzeInspectionImageJob.perform_now(@i3.id)
    end
    assert_equal [ "A01-2-03" ], @inspection.panel_candidates.map { |c| c.panel.number }
  end
end
