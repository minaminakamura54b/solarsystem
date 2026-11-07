require "test_helper"

# 架台の登録の画面（docs/LAYOUT_OVERLAY_DESIGN.md の A）
class BlockLayoutsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    frame = GeoFrame.new(35.0, 139.0)
    pts = [ [ 0, 4 ], [ 11.6, 4 ], [ 11.6, 0 ], [ 0, 0 ] ].map { |e, n| frame.to_latlng(e, n) }
    @csv = "block_label,rows,cols,corner1_lat,corner1_lng,corner2_lat,corner2_lng,corner3_lat,corner3_lng,corner4_lat,corner4_lng\n" \
           "A01,2,10,#{pts.flatten.map { |v| format('%.8f', v) }.join(',')}\n"
  end

  def upload(text) = Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "blocks.csv")

  test "登録画面に列名の対応表と雛形を出す。雛形はそのまま取り込める形" do
    get new_site_block_layout_path(@site)
    assert_response :success
    assert_select "td code", text: "corner1_lat"

    get template_site_block_layout_path(@site, format: :csv)
    assert_equal "text/csv", response.media_type
    assert BlockLayoutImport.new(@site, response.body).valid?
  end

  test "確認画面では何も変えず、配置図と件数を出す。確定すると架台とパネルを置き換える" do
    post preview_site_block_layout_path(@site), params: { file: upload(@csv) }

    assert_response :success
    assert_select "svg polygon", 1
    assert_match "パネル</th><td>20 枚", response.body
    assert_equal 0, @site.pv_blocks.count

    digest = css_select("input[name=plan_digest]").first["value"]
    post site_block_layout_path(@site), params: { csv_text: @csv, plan_digest: digest }

    assert_redirected_to new_site_block_layout_path(@site)
    assert_equal 1, @site.pv_blocks.count
    assert_equal 20, @site.panels.count
    get export_site_block_layout_path(@site, format: :csv)
    assert_match "A01,2,10,", response.body
  end

  test "CSV にエラーがあれば何も変えずにエラーを出す" do
    post preview_site_block_layout_path(@site), params: { file: upload("block_label,rows\nA,2\n") }

    assert_response :unprocessable_entity
    assert_select "#errors li", minimum: 1
    assert_equal 3, @site.panels.count
  end
end
