require "test_helper"

# 点検の画像から架台の地図の候補を作るジョブ。解析エンジンは偽のクライアント
class BuildBlockMapJobTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection(files: [ "thermal_plain_T.jpg", "thermal_plain_T.jpg" ])
    @site = @inspection.site
    @proposal = @site.block_map_proposals.create!(inspection: @inspection, params: { "module_width_m" => 1.134, "module_length_m" => 2.278 })
  end

  USABLE = { "usable" => true, "issues" => [], "lrf" => { "target_abs_alt_m" => 30.5 },
             "camera" => { "lat" => 35.0, "lng" => 139.0, "abs_alt_m" => 67.6, "image_up_azimuth_deg" => 359.5, "ifov_mrad" => 0.975, "width" => 640, "height" => 512 } }.freeze

  def block
    { "corners_latlng" => [ [ 35.00009, 139.0 ], [ 35.00009, 139.000127 ], [ 35.00005, 139.000127 ], [ 35.00005, 139.0 ] ],
      "corners_local" => [ [ 0, 10, 31.9 ], [ 11.6, 10, 31.9 ], [ 11.6, 6, 29.1 ], [ 0, 6, 29.1 ] ],
      "length_m" => 11.6, "height_m" => 4.0, "cols_estimate" => 10, "rows_estimate" => 2, "source" => "both",
      "low_confidence" => false, "adjusted" => false, "observations" => { "start" => 3, "end" => 4, "upper" => 5, "lower" => 6 } }
  end

  test "位置合わせに使える画像だけを渡し、候補を保存する。CSV はそのまま架台の登録に使える形" do
    first, second = @inspection.inspection_images.order(:sequence)
    first.update_columns(georef: USABLE)
    second.update_columns(georef: USABLE.merge("usable" => false, "issues" => [ "rtk_not_fixed" ]))
    output = { "schema_version" => "2.1", "status" => "proposed", "estimated" => { "panel_elevation_m" => 30.5 }, "fit" => {}, "blocks" => [ block ] }

    with_fake_analyzer(block_map: analyzer_result(output:)) do |client|
      BuildBlockMapJob.perform_now(@proposal.id)
      call = client.calls.sole.last
      assert_equal [ first.id.to_s ], call[:input][:images].map { |i| i[:id] }
      assert_equal [ true ], call[:files], "画像を一時ファイルに書き出して渡す"
      assert_equal 2.278, call[:input][:module][:length_m]
    end

    @proposal.reload
    assert_equal [ "proposed", 1 ], [ @proposal.status, @proposal.image_count ]
    importer = BlockLayoutImport.new(@site, @proposal.to_csv)
    assert importer.valid?, importer.errors.inspect
    assert_equal [ 2, 10, "image_map" ], importer.blocks.first.then { |b| [ b.rows, b.cols, b.source ] }
  end

  test "使える画像が無ければ解析エンジンを呼ばずに要確認" do
    with_fake_analyzer do |client|
      BuildBlockMapJob.perform_now(@proposal.id)
      assert_empty client.calls
    end
    assert_equal "needs_review", @proposal.reload.status
    assert_match "位置合わせに使える画像", @proposal.message
  end

  test "解析エンジンが作れなかったときは理由付きで要確認、出力が読めなければ失敗。パネル・Site は変えない" do
    @inspection.inspection_images.update_all(georef: USABLE)
    output = { "schema_version" => "2.1", "status" => "needs_review", "review_reason" => "panel_elevation_unknown", "message" => "パネル面の標高を決められません", "blocks" => [] }
    with_fake_analyzer(block_map: analyzer_result(exit_code: 1, output:)) { BuildBlockMapJob.perform_now(@proposal.id) }
    assert_equal [ "needs_review", "パネル面の標高を決められません" ], [ @proposal.reload.status, @proposal.message ]

    other = @site.block_map_proposals.create!(inspection: @inspection, params: @proposal.params)
    assert_no_changes -> { @site.panels.pluck(:status, :last_inspected_at) } do
      with_fake_analyzer(block_map: analyzer_result(exit_code: 1, error: "invalid_output")) { BuildBlockMapJob.perform_now(other.id) }
    end
    assert_equal "failed", other.reload.status
  end

  test "モジュールの寸法が無い候補は作らない" do
    proposal = @site.block_map_proposals.build(inspection: @inspection, params: {})
    assert_not proposal.valid?
    assert_match "モジュールの幅", proposal.errors.full_messages.join
  end
end
