require "test_helper"

# 実配置の登録の画面（docs/IMPROVEMENT_PLAN.md Phase 5b）
class PanelLayoutsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south) # 仮配置のパネル P001〜P003
  end

  def csv_upload(text, name = "layout.csv")
    Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: name)
  end

  CSV_TEXT = "panel_number,position_x,position_y,pcs_number\nA-01,0,0,PCS1\nA-02,1,0,PCS1\n".freeze

  test "登録画面に英語と日本語の列名の対応表と雛形のリンクを出す。雛形は英語の列名" do
    get new_site_panel_layout_path(@site)

    assert_response :success
    assert_select "td code", text: "pcs_number"
    assert_select "td", text: "パワコン番号"
    assert_select "a[href='#{template_site_panel_layout_path(@site, format: :csv)}']"

    get template_site_panel_layout_path(@site, format: :csv)
    assert_equal "text/csv", response.media_type
    assert response.body.start_with?("panel_number,position_x,position_y")
  end

  test "確認画面では何も変えず、件数と割り当てを外す異常の件数を表示する" do
    inspection = analyzable_inspection # 南発電所
    inspection.inspection_images.first.anomalies.create!(inspection: inspection, anomaly_type: "hotspot", severity: "warning",
                                                          review_status: "confirmed", locked: true, panel: panels(:p001))

    post preview_site_panel_layout_path(@site), params: { file: csv_upload(CSV_TEXT) }

    assert_response :success
    assert_match "新しく登録する実配置のパネル</th><td>2 枚", response.body
    assert_match "削除する仮配置のパネル</th><td>3 枚", response.body
    assert_match "1 件（仮配置のパネル 1 件・CSV に無い実配置のパネル 0 件）", response.body
    assert_select "input[name=plan_digest]"
    assert_equal %w[P001 P002 P003], @site.panels.order(:number).map(&:number)
  end

  test "エラーがある CSV は 422 で理由を表示し、何も変えない" do
    post preview_site_panel_layout_path(@site), params: { file: csv_upload("panel_number,position_x\nA,0\n") }

    assert_response :unprocessable_entity
    assert_select "#errors li", text: "必須の列がありません: position_y / Y位置"
    assert_equal 3, @site.panels.count

    post preview_site_panel_layout_path(@site)
    assert_select "#errors li", text: "CSV ファイルを選んでください"
  end

  test "確定すると置き換え、ダッシュボードの「仮配置」の表示が消える" do
    get dashboard_path(site_id: @site.id)
    assert_match "仮配置です。", response.body

    importer = PanelLayoutImport.new(@site, CSV_TEXT)
    post site_panel_layout_path(@site), params: { csv_text: CSV_TEXT, plan_digest: importer.plan.digest }

    assert_redirected_to site_panel_layout_path(@site)
    assert_equal %w[A-01 A-02], @site.panels.order(:number).map(&:number)
    assert_equal 2, @site.reload.panel_count
    get dashboard_path(site_id: @site.id)
    assert_no_match "仮配置", response.body
  end

  test "確認画面の後にデータが変わっていたら 409 で確認画面を出し直す" do
    post site_panel_layout_path(@site), params: { csv_text: CSV_TEXT, plan_digest: "old" }

    assert_response :conflict
    assert_match "確認画面を表示した後に", response.body
    assert_equal 3, @site.panels.count
  end

  test "割り当てが外れた異常を一覧・点検詳細・レビュー画面・ダッシュボードに表示する" do
    inspection = analyzable_inspection # 南発電所
    image = inspection.inspection_images.first
    target = image.anomalies.create!(inspection: inspection, anomaly_type: "hotspot", severity: "warning",
                                     review_status: "confirmed", locked: true, panel: panels(:p002))
    importer = PanelLayoutImport.new(@site, CSV_TEXT)
    post site_panel_layout_path(@site), params: { csv_text: CSV_TEXT, plan_digest: importer.plan.digest }
    assert_match "パネルの割り当てが外れた異常が 1 件あります", flash[:notice]

    get site_panel_layout_path(@site)
    assert_select "#reassign_anomaly_#{target.id} td", text: "P002（仮配置）"

    get inspection_path(inspection, site_id: @site.id)
    assert_match "配置の置き換えでパネルの割り当てが外れた異常が 1 件あります", response.body

    get review_inspection_path(inspection, image: image.sequence, site_id: @site.id)
    assert_match "元: P002・仮配置", response.body


    get dashboard_path(site_id: @site.id)
    assert_match "割り当てが外れた異常が 1 件あります", response.body

    patch assign_panel_inspection_anomaly_path(inspection, target, site_id: @site.id), params: { panel_id: @site.panels.find_by!(number: "A-01").id }
    get review_inspection_path(inspection, image: image.sequence, site_id: @site.id)
    assert_match "パネルの割り当ての履歴（2 件）", response.body
    assert_match "未割り当て → A-01", response.body
    assert_no_match "元: P002・仮配置", response.body
    get dashboard_path(site_id: @site.id)
    assert_no_match "割り当てが外れた異常", response.body
  end
end
