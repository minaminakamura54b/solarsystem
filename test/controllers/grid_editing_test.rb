require "test_helper"

# グリッドの指定・テンプレート・再解析・再判定（docs/IMPROVEMENT_PLAN.md Phase 4-1、4-5）
class GridEditingTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    load_initial_rule_set
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg lowres_T.jpg])
    @first, @second = @inspection.inspection_images.to_a
  end

  def grids_json(*grids)
    (grids.presence || [ SAMPLE_GRID ]).to_json
  end

  test "グリッド入力画面を表示する（前後の画像へのリンク・提案の読み込み）" do
    @first.update_columns(grid_proposal: { "rows" => 3, "cols" => 5, "corners" => SAMPLE_GRID["corners"], "panel_orientation" => "landscape" })

    get grid_inspection_inspection_image_path(@inspection, @first, site_id: @site.id)

    assert_response :success
    assert_select "[data-controller='grid-editor']"
    assert_select "#grid-next-link"
    assert_select "#grid-prev-link", count: 0
    assert_match "自動抽出の提案を読み込む（3行 × 5列）", response.body
  end

  test "グリッドを保存すると解析ジョブを登録する" do
    assert_enqueued_with(job: AnalyzeInspectionImageJob, args: [ @first.id ]) do
      patch grids_inspection_inspection_image_path(@inspection, @first, site_id: @site.id), params: { panel_grids: grids_json }
    end

    @first.reload
    assert_equal 1, @first.panel_grids.size
    assert_equal 4, @first.panel_grids.first["rows"]
    assert_equal "pending", @first.analysis_status
    assert_match "グリッド 1 個を保存し、解析を始めました", flash[:notice]
  end

  test "1つの画像に2つのグリッドを保存できる" do
    second_grid = SAMPLE_GRID.merge("corners" => [ [ 0.75, 0.2 ], [ 0.95, 0.2 ], [ 0.95, 0.48 ], [ 0.75, 0.48 ] ], "cols" => 2)

    patch grids_inspection_inspection_image_path(@inspection, @first, site_id: @site.id), params: { panel_grids: grids_json(SAMPLE_GRID, second_grid) }

    assert_equal [ 6, 2 ], @first.reload.panel_grids.map { |g| g["cols"] }
  end

  test "不正なグリッドは保存しない" do
    bad = SAMPLE_GRID.merge("corners" => [ [ 0, 0 ], [ 1, 0 ], [ 1, 1 ] ])

    assert_no_enqueued_jobs do
      patch grids_inspection_inspection_image_path(@inspection, @first, site_id: @site.id), params: { panel_grids: grids_json(bad) }
    end

    assert_empty @first.reload.panel_grids
    assert_match "4隅の座標が不正です", flash[:alert]
  end

  test "グリッドを空にすると needs_review（grid_required）に戻す" do
    @first.update_columns(panel_grids: [ SAMPLE_GRID ])

    patch grids_inspection_inspection_image_path(@inspection, @first, site_id: @site.id), params: { panel_grids: "[]" }

    assert_equal [ "needs_review", "grid_required" ], [ @first.reload.analysis_status, @first.review_reason ]
  end

  test "品質チェックに合格していない画像は、グリッドを保存しても解析しない" do
    @first.update_columns(quality_report: { "status" => "rejected" }, analysis_status: "needs_review")

    assert_no_enqueued_jobs only: AnalyzeInspectionImageJob do
      patch grids_inspection_inspection_image_path(@inspection, @first, site_id: @site.id), params: { panel_grids: grids_json }
    end
    assert_match "解析はしません", flash[:notice]
  end

  test "テンプレートとして保存し、撮影条件の近いグリッド未指定の画像に一括適用する" do
    @first.update_columns(altitude_m: 30.0, gimbal_pitch: -90.0, gimbal_yaw: 10.0)
    @second.update_columns(altitude_m: 31.5, gimbal_pitch: -88.0, gimbal_yaw: 358.0) # ヨーは 360° をまたいで 12° 差 → 許容差 5° の外
    third = @inspection.inspection_images.create!(sequence: 3, thermal_filename: "c.jpg",
                                                  thermal: { io: file_fixture("thermal_plain_T.jpg").open, filename: "c_T.jpg" })
    third.update_columns(quality_report: { "status" => "ok" }, altitude_m: 29.0, gimbal_pitch: -91.0, gimbal_yaw: 13.0)

    post inspection_grid_templates_path(@inspection, site_id: @site.id),
         params: { source_image_id: @first.id, name: "A列", grid: SAMPLE_GRID.to_json }
    template = @inspection.grid_templates.sole
    assert_equal [ "A列", 30.0 ], [ template.name, template.altitude_m.to_f ]

    assert_enqueued_jobs 2, only: AnalyzeInspectionImageJob do
      post apply_inspection_grid_template_path(@inspection, template, site_id: @site.id)
    end

    assert_equal template.id, @first.reload.panel_grids.sole["grid_template_id"]
    assert_equal template.id, third.reload.panel_grids.sole["grid_template_id"]
    assert_empty @second.reload.panel_grids, "許容差の外"
    assert_match "2 枚に適用して解析を始めました", flash[:notice]
    assert_match "撮影条件が許容差の外のため対象外 1 枚", flash[:notice]
  end

  test "一括適用は、グリッド指定済みの画像を上書きしない" do
    custom = SAMPLE_GRID.merge("rows" => 2)
    @first.update_columns(altitude_m: 30, gimbal_pitch: -90, gimbal_yaw: 0, panel_grids: [ custom ])
    @second.update_columns(altitude_m: 30, gimbal_pitch: -90, gimbal_yaw: 0)
    template = @inspection.grid_templates.create!(name: "T", rows: 4, cols: 6, corners: SAMPLE_GRID["corners"],
                                                  altitude_m: 30, gimbal_pitch: -90, gimbal_yaw: 0)

    post apply_inspection_grid_template_path(@inspection, template, site_id: @site.id)

    assert_equal 2, @first.reload.panel_grids.sole["rows"]
    assert_equal 4, @second.reload.panel_grids.sole["rows"]
    assert_match "グリッド指定済みのため対象外 1 枚", flash[:notice]
  end

  test "再解析は品質チェック合格・グリッド指定済みの画像だけ" do
    @first.update_columns(panel_grids: [ SAMPLE_GRID ], analysis_status: "completed")

    assert_enqueued_with(job: AnalyzeInspectionImageJob, args: [ @first.id ]) do
      post reanalyze_inspection_inspection_image_path(@inspection, @first, site_id: @site.id)
    end
    assert_equal "pending", @first.reload.analysis_status

    assert_no_enqueued_jobs do
      post reanalyze_inspection_inspection_image_path(@inspection, @second, site_id: @site.id)
    end
    assert flash[:alert].present?
  end

  test "再判定は未確定の異常だけを、現在の判定基準で判定し直す" do
    anomaly = @first.anomalies.create!(inspection: @inspection, anomaly_type: "hotspot", measure: "region_max",
                                       delta_t: 6, normalized_delta_t: 6, threshold_basis: "normalized", severity: "mild")

    post rejudge_inspection_path(@inspection, site_id: @site.id)

    assert_equal "warning", anomaly.reload.severity
    assert_match "1 件を判定基準「2026-09-initial」で判定し直しました", flash[:notice]
    assert_match "再解析が必要です", flash[:notice]
  end

  test "点検の詳細に、解析結果と候補の件数を表示する" do
    @first.update_columns(panel_grids: [ SAMPLE_GRID ])
    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output)) { AnalyzeInspectionImageJob.perform_now(@first.id) }

    get inspection_path(@inspection, site_id: @site.id)

    assert_response :success
    assert_match "解析結果（基準温度 40.0℃", response.body
    assert_match "ホットスポット", response.body
    assert_select "a", text: "グリッドを編集（1個）"
  end
end
