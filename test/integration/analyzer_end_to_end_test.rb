require "test_helper"

# Rails から本物の解析エンジン（analyzer/、uv）を呼ぶテスト。合成シーン（.npy）だけを使う。
# 開発機・CI とも uv と analyzer/ の依存関係（uv sync）が必要
class AnalyzerEndToEndTest < ActiveSupport::TestCase
  setup do
    load_initial_rule_set
    @dir = Rails.root.join("tmp", "e2e_scenes_#{Process.pid}")
    config = AnalyzerConfig.current
    command = config.command.first(config.command.index("python") + 1)
    assert system(*command, "scripts/make_dev_scenes.py", "--out", @dir.to_s, chdir: config.working_dir, out: File::NULL),
           "合成シーンを作れません（uv と analyzer/ の uv sync が必要です）"
    @scenes = JSON.parse(File.read(@dir.join("scenes.json")))
  end

  teardown do
    FileUtils.rm_rf(@dir) if @dir
  end

  def image_for(scene_index, grids:)
    scene = @scenes[scene_index]
    inspection = sites(:south).inspections.build(conducted_at: Time.current)
    image = inspection.inspection_images.build(sequence: 1, thermal_filename: "#{scene['name']}.npy")
    image.thermal.attach(io: File.open(@dir.join("#{scene['name']}.npy")), filename: "#{scene['name']}.npy")
    inspection.save!
    image.update_columns(quality_report: { "status" => "ok", "checks" => [] }, panel_grids: grids,
                         irradiance_w_m2: 800, irradiance_type: "poa", width: scene["width"], height: scene["height"])
    image
  end

  test "グリッドを指定した合成シーンを解析し、異常と重大度を保存する" do
    image = image_for(0, grids: InspectionImage.normalize_grids(@scenes[0]["expected_grids"]))

    AnalyzeInspectionImageJob.perform_now(image.id)

    image.reload
    assert_equal "completed", image.analysis_status, image.error_message
    assert_equal 24, image.raw_analysis["panels"].size
    anomaly = image.anomalies.sole
    assert_equal [ "hotspot", "local", 8 ], [ anomaly.anomaly_type, anomaly.detection, anomaly.panel_index_in_image ]
    assert_equal "critical", anomaly.severity
    assert_equal "2026-09-initial", anomaly.rule_version
  end

  test "モジュール仕様があれば、2/3 の帯は substring_bypass（帯2本）とその中のホットスポット" do
    image = image_for(1, grids: InspectionImage.normalize_grids(@scenes[1]["expected_grids"]))
    image.inspection.site.update!(cell_layout: "full_cell", substring_count: 3,
                                  bypass_pattern_json: '{"bands": 3, "band_axis": "short_side", "band_area_ratio": 0.333, "tolerance": 0.12}')

    AnalyzeInspectionImageJob.perform_now(image.id)

    types = image.reload.anomalies.order(:id).map { |a| [ a.anomaly_type, a.active_bands ] }
    assert_equal [ [ "substring_bypass", 2 ], [ "hotspot", nil ] ], types
  end

  test "隣接パネル群は群として保存し、候補は群を1件と数える" do
    image = image_for(2, grids: InspectionImage.normalize_grids(@scenes[2]["expected_grids"]))

    AnalyzeInspectionImageJob.perform_now(image.id)

    group = image.reload.anomaly_groups.sole
    assert_equal [ 1, 2, 3, 4 ], group.panel_indices
    assert_equal 4, group.anomalies.count
    assert_equal 1, image.inspection.candidate_count
  end

  test "グリッドの提案を保存する（解析には使わない）" do
    image = image_for(3, grids: [])

    GridProposalJob.perform_now(image.id)

    proposal = image.reload.grid_proposal
    assert_equal [ 3, 5 ], [ proposal["rows"], proposal["cols"] ]
    assert_empty image.panel_grids
  end

  test "基準パネルが足りなければ needs_review（insufficient_baseline）" do
    # シーン3（1行目の6枚のうち4枚がモジュール全体の発熱）の1行目だけをグリッドにする
    # → 正常パネル2枚 < 必要な max(6, 6 × 0.5) = 6 枚
    grid = InspectionImage.normalize_grids(@scenes[2]["expected_grids"]).first
    (x0, y0), (x1, _), (_, y2), = grid["corners"]
    y_row = y0 + (y2 - y0) / 4.0
    image = image_for(2, grids: [ grid.merge("rows" => 1, "corners" => [ [ x0, y0 ], [ x1, y0 ], [ x1, y_row ], [ x0, y_row ] ]) ])

    AnalyzeInspectionImageJob.perform_now(image.id)

    image.reload
    assert_equal [ "needs_review", "insufficient_baseline" ], [ image.analysis_status, image.review_reason ], image.error_message
    assert_empty image.anomalies
  end
end
