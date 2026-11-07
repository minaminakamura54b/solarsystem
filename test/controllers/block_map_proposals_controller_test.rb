require "test_helper"

# 架台の地図の候補の画面
class BlockMapProposalsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @inspection = analyzable_inspection
    @site = @inspection.site
  end

  test "点検の画面から候補づくりを始める（ジョブを登録する）。寸法が無ければ始めない" do
    assert_enqueued_with(job: BuildBlockMapJob) do
      post site_block_map_proposals_path(@site), params: { inspection_id: @inspection.id, module_width_m: 1.134, module_length_m: 2.278, rows: 2 }
    end
    proposal = @site.block_map_proposals.last
    assert_redirected_to site_block_map_proposal_path(@site, proposal)
    assert_equal({ "module_width_m" => 1.134, "module_length_m" => 2.278, "rows" => 2, "facing_azimuth_deg" => 180.0 }, proposal.params)

    assert_no_enqueued_jobs(only: BuildBlockMapJob) do
      post site_block_map_proposals_path(@site), params: { inspection_id: @inspection.id }
    end
    assert_redirected_to inspection_path(@inspection)
  end

  test "候補の画面に配置図と、登録の確認画面へ進むフォームを出す。確認画面ではまだ登録しない" do
    frame = GeoFrame.new(35.0, 139.0)
    latlng = [ [ 0, 4 ], [ 11.6, 4 ], [ 11.6, 0 ], [ 0, 0 ] ].map { |e, n| frame.to_latlng(e, n) }
    result = { "estimated" => {}, "fit" => {}, "blocks" => [ { "corners_latlng" => latlng, "corners_local" => [ [ 0, 4, 31 ], [ 11.6, 4, 31 ], [ 11.6, 0, 29 ], [ 0, 0, 29 ] ],
                                                              "cols_estimate" => 10, "rows_estimate" => 2, "low_confidence" => true, "adjusted" => false, "observations" => { "start" => 1 } } ] }
    proposal = @site.block_map_proposals.create!(inspection: @inspection, status: "proposed", result:, params: { "module_width_m" => 1.16, "module_length_m" => 2.0 })

    get site_block_map_proposal_path(@site, proposal)
    assert_response :success
    assert_select "svg polygon", 1
    assert_match "確認が必要 1 個", response.body

    post preview_site_block_layout_path(@site), params: { csv_text: proposal.to_csv }
    assert_response :success
    assert_match "架台</th><td>1 個", response.body
    assert_equal 0, @site.pv_blocks.count
  end
end
