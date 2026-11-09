require "test_helper"

# 点検の対象範囲（見直し R1）
class InspectionScopeTest < ActiveSupport::TestCase
  setup do
    @site = sites(:south)
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg] * 2)
    @blocks = register_blocks(@site, %w[A01 A02 A03 B01])
    @i1, @i2 = @inspection.inspection_images.order(:sequence).to_a
    analyzed_image(@i1, [ @blocks["A01"] ], y0: 0.4)
    # 使わなかった画像の位置合わせの下書きに写った架台も案に入れる（広めに）
    draft = { "rows" => 2, "cols" => 10, "corners" => [ [ 0.85, 0.4 ], [ 1.25, 0.4 ], [ 1.25, 0.6 ], [ 0.85, 0.6 ] ], "source" => "layout", "pv_block_id" => @blocks["A02"].id }
    @i2.update_columns(analysis_status: "excluded", exclusion_note: "x", alignment: { "review_reason" => "no_along_anchor", "draft_grids" => [ draft ] })
  end

  test "案は、解析できた画像と、使わなかった画像の下書きに少しでも写った架台" do
    assert_equal [ @blocks["A01"].id, @blocks["A02"].id ].sort, InspectionScope.new(@inspection).proposal.sort
  end

  test "確定すると、写ったパネル・写っていないパネルは対象範囲の中で数える。取り消すと発電所全体" do
    assert_equal 80, InspectionCoverage.new(@inspection).summary.registered

    InspectionScope.new(@inspection).confirm!([ @blocks["A01"].id, @blocks["A02"].id ], source: "proposal")
    @inspection.reload
    summary = InspectionCoverage.new(@inspection).summary
    assert_equal [ 40, 20, 20 ], [ summary.registered, summary.covered, summary.uncovered ]
    assert_equal "proposal", @inspection.scope_source
    assert_equal "架台 A01〜A02（2 基・パネル 40 枚）", InspectionScope.new(@inspection).description

    InspectionScope.new(@inspection).clear!
    assert_not @inspection.reload.scope_confirmed?
    assert_match "発電所全体（架台 A01〜A03、B01", InspectionScope.new(@inspection).description
  end

  test "案と違う架台を選んだら manual。ほかの発電所の架台・空は確定できない" do
    InspectionScope.new(@inspection).confirm!([ @blocks["B01"].id ], source: "proposal")
    assert_equal "manual", @inspection.reload.scope_source
    assert_raises(InspectionScope::Error) { InspectionScope.new(@inspection).confirm!([ 999_999 ], source: "manual") }
  end

  test "報告書の範囲・表紙・宛先・備考。社内メモは報告書の本文に載せない" do
    @site.update!(client_name: "株式会社テストエナジー")
    @inspection.update_columns(weather_note: "社内だけのメモ", report_remarks: "北側は立ち入りできず")
    s = ReportSnapshotBuilder.new(@inspection).build

    assert_equal "株式会社テストエナジー", s["default_addressee"]
    assert_equal "北側は立ち入りできず", s["report_remarks"]
    assert_equal "社内だけのメモ", s["internal_note"]
    assert_not s["conditions"].key?("weather_note")
    assert_includes s["warnings"], "点検の対象範囲が確定していません（発電所全体として数えています）"
  end
end
