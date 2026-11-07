require "test_helper"

# 登録した架台との位置合わせ（docs/LAYOUT_OVERLAY_DESIGN.md の B）。解析エンジンは偽のクライアント
class AlignLayoutJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @inspection = analyzable_inspection(grids: [])
    @image = @inspection.inspection_images.first
    @site = @inspection.site
    frame = GeoFrame.new(35.0, 139.0)
    pts = [ [ 0, 4 ], [ 11.6, 4 ], [ 11.6, 0 ], [ 0, 0 ] ].map { |e, n| frame.to_latlng(e, n) }
    csv = "block_label,rows,cols,corner1_lat,corner1_lng,corner2_lat,corner2_lng,corner3_lat,corner3_lng,corner4_lat,corner4_lng,upper_elevation_m,lower_elevation_m\n" \
          "A01,2,10,#{pts.flatten.map { |v| format('%.8f', v) }.join(',')},31.6,29.4\n"
    importer = BlockLayoutImport.new(@site, csv)
    importer.apply!(expected_digest: importer.plan.digest)
    @block = @site.pv_blocks.sole
    lat, lng = frame.to_latlng(5, 2)
    @image.update_columns(georef: { "usable" => true, "issues" => [], "lrf" => { "target_abs_alt_m" => 30.5 },
                                    "camera" => { "lat" => lat, "lng" => lng, "abs_alt_m" => 67.6, "image_up_azimuth_deg" => 0.0, "ifov_mrad" => 0.975, "width" => 640, "height" => 512 } })
  end

  def grid(source = "layout")
    { "rows" => 2, "cols" => 10, "corners" => [ [ 0.2, 0.3 ], [ 0.8, 0.3 ], [ 0.8, 0.5 ], [ 0.2, 0.5 ] ], "panel_orientation" => "portrait",
      "source" => source, "pv_block_id" => @block.id, "block_label" => "A01" }
  end

  def output(status: "aligned", review_reason: nil, message: nil)
    { "schema_version" => "2.1", "status" => status, "review_reason" => review_reason, "message" => message,
      "residual" => { "panel_width_ratio" => 0.06 }, "correction" => { "tx_px" => 3.0 }, "matches" => { "long" => 2, "short" => 1 },
      "blocks_in_view" => 1, "grids" => status == "aligned" ? [ grid ] : [], "draft_grids" => [ grid ] }
  end

  test "品質チェックの後、架台を登録した発電所の位置合わせに使える画像は、位置合わせを待つ（グリッドの提案は作らない）" do
    assert_enqueued_with(job: AlignLayoutJob, args: [ @image.id ]) { InspectionImagePipeline.after_quality(@image) }
    assert_no_enqueued_jobs(only: GridProposalJob) { InspectionImagePipeline.after_quality(@image.reload) }
    assert_equal "pending", @image.reload.analysis_status
  end

  test "位置合わせに使えない画像は、理由を残して手動のグリッドを待つ" do
    @image.update_columns(georef: { "usable" => false, "issues" => [ "rtk_not_fixed" ] })
    assert_no_enqueued_jobs(only: AlignLayoutJob) { InspectionImagePipeline.after_quality(@image) }
    @image.reload
    assert_equal [ "needs_review", "grid_required" ], [ @image.analysis_status, @image.review_reason ]
    assert_equal "unavailable", @image.alignment["status"]
    assert_match "RTK", @image.alignment["message"]
  end

  test "位置合わせできたらグリッドを保存して解析へ進む。近くの架台と標高を渡す" do
    with_fake_analyzer(align: analyzer_result(output: output)) do |client|
      assert_enqueued_with(job: AnalyzeInspectionImageJob, args: [ @image.id ]) { AlignLayoutJob.perform_now(@image.id) }
      input = client.calls.sole.last[:input]
      assert client.calls.sole.last[:thermal_exists]
      assert_equal [ @block.id ], input[:blocks].map { |b| b[:id] }
      assert_equal [ 31.6, 29.4 ], input[:blocks].first.values_at(:upper_elevation_m, :lower_elevation_m)
      assert_equal 0.25, input[:max_residual_panel_width_ratio]
    end
    @image.reload
    assert_equal [ grid ], @image.panel_grids
    assert_equal "aligned", @image.alignment["status"]
    assert_nil @image.alignment["draft_grids"]
    assert_equal LayoutOverlayConfig.current.version, @image.alignment["config_version"]
  end

  test "位置合わせできなければ要確認（alignment_failed）にして下書きを残す。正常にはせず、パネル・Site も変えない" do
    out = output(status: "needs_review", review_reason: "no_along_anchor", message: "架台の端が写っておらず")
    assert_no_changes -> { @site.panels.pluck(:status, :last_inspected_at) } do
      with_fake_analyzer(align: analyzer_result(exit_code: 0, output: out)) { AlignLayoutJob.perform_now(@image.id) }
    end
    @image.reload
    assert_equal [ "needs_review", "alignment_failed" ], [ @image.analysis_status, @image.review_reason ]
    assert_equal [ grid ], @image.alignment["draft_grids"]
    assert_empty @image.panel_grids
    assert_nil @inspection.reload.severity

    @image.update_columns(analysis_status: "pending", alignment: nil)
    with_fake_analyzer(align: analyzer_result(exit_code: 1, error: "invalid_output")) { AlignLayoutJob.perform_now(@image.id) }
    assert_equal [ "needs_review", "alignment_failed", "failed" ], [ @image.reload.analysis_status, @image.review_reason, @image.alignment["status"] ]
  end

  test "位置合わせで作ったグリッドの異常は、グリッドの行・列から架台のパネルに割り当て、根拠を残す" do
    @image.update_columns(panel_grids: [ grid ], alignment: { "residual" => { "panel_width_ratio" => 0.06 } })
    out = analyzer_output(anomalies: [ analyzer_anomaly("panel_index" => 13) ]) # 2 段目の 4 列目
    AnalysisResultImporter.new(@image, out, load_initial_rule_set).import!

    anomaly = @image.anomalies.sole
    assert_equal "A01-2-04", anomaly.panel.number
    history = anomaly.panel_assignment_history.last
    assert_equal [ "layout", "A01-2-04", 0.06 ], history.values_at("assigned_by", "panel_number", "alignment_residual_ratio")
  end

  test "手動のグリッド（架台の ID なし）の異常は自動で割り当てない" do
    @image.update_columns(panel_grids: [ grid.except("source", "pv_block_id") ])
    AnalysisResultImporter.new(@image, analyzer_output(anomalies: [ analyzer_anomaly("panel_index" => 3) ]), load_initial_rule_set).import!
    assert_nil @image.anomalies.sole.panel_id
  end

  test "下書きを人が直して保存したグリッドは架台の ID を残し、出どころを layout_adjusted にする" do
    saved = InspectionImage.normalize_grids([ grid ], site: @site).sole
    assert_equal [ @block.id, "layout_adjusted", "A01" ], saved.values_at("pv_block_id", "source", "block_label")
    assert_raises(ArgumentError) { InspectionImage.normalize_grids([ grid.merge("pv_block_id" => 999_999) ], site: @site) }
  end
end
