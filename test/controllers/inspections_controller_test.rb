require "test_helper"

# InspectionsController のテスト
class InspectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
  end

  test "一覧を表示する" do
    get inspections_path(site_id: @site.id)

    assert_response :success
    assert_select "tr#inspection_#{inspections(:completed_warning).id}"
  end

  test "解析完了の点検の詳細を表示する" do
    get inspection_path(inspections(:completed_warning), site_id: @site.id)

    assert_response :success
    assert_select ".badge", text: "注意"
  end

  test "解析失敗の点検の詳細に error_message の失敗理由を表示し、正常とは表示しない" do
    get inspection_path(inspections(:failed), site_id: @site.id)

    assert_response :success
    assert_match "解析に失敗しました", response.body
    assert_match "Claude API エラー: overloaded", response.body
    assert_match "正常とは限りません", response.body
    assert_select ".badge", text: "正常", count: 0
  end

  test "error_message の無い古い失敗データは result を表示する" do
    inspection = inspections(:failed)
    inspection.update_columns(error_message: nil)

    get inspection_path(inspection, site_id: @site.id)

    assert_match "解析中にエラーが発生しました", response.body
  end

  test "JSON でステータスを返す（自動更新のポーリング用）" do
    inspection = inspections(:analyzing)

    get inspection_path(inspection, format: :json, site_id: @site.id)

    assert_response :success
    body = response.parsed_body
    assert_equal inspection.id, body["id"]
    assert_equal "analyzing", body["analysis_status"]
  end

  test "JSON でステータスを返す（pending でも返す）" do
    get inspection_path(inspections(:pending), format: :json, site_id: @site.id)

    assert_response :success
    assert_equal "pending", response.parsed_body["analysis_status"]
  end

  test "解析中の詳細画面には自動更新が付く" do
    get inspection_path(inspections(:analyzing), site_id: @site.id)

    assert_select "[data-controller='auto-refresh']"
  end

  test "pending の詳細画面にも自動更新が付く" do
    get inspection_path(inspections(:pending), site_id: @site.id)

    assert_response :success
    assert_select "[data-controller='auto-refresh']"
  end

  test "完了・失敗の詳細画面には自動更新が付かない" do
    %i[completed_normal failed].each do |name|
      get inspection_path(inspections(name), site_id: @site.id)
      assert_select "[data-controller='auto-refresh']", count: 0
    end
  end

  test "詳細表示では DB に書き込まない（result に古い JSON があっても）" do
    inspection = inspections(:completed_normal)
    inspection.update_columns(
      anomalies: [],
      result: { "severity" => "critical", "anomaly_count" => 3, "anomalies" => [ { "type" => "旧データの異常" } ], "summary" => "旧データの概要" }.to_json,
      updated_at: 1.day.ago
    )
    before = inspection.reload.attributes

    get inspection_path(inspection, site_id: @site.id)

    assert_response :success
    assert_equal before, inspection.reload.attributes
    assert_match "旧データの異常", response.body, "表示用には古い JSON の異常一覧を使う"
    assert_match "旧データの概要", response.body
  end

  test "詳細表示で severity の無い古い JSON があっても normal で上書きしない" do
    inspection = inspections(:completed_warning)
    inspection.update_columns(anomalies: [], result: { "anomaly_count" => 1, "summary" => "s" }.to_json)

    get inspection_path(inspection, site_id: @site.id)

    assert_equal "warning", inspection.reload.severity
    assert_select ".badge", text: "注意"
  end

  test "画像付きで作成すると解析ジョブを登録して詳細へ移動する" do
    assert_difference -> { @site.inspections.count }, 1 do
      assert_enqueued_with(job: AnalyzePanelImageJob) do
        post inspections_path(site_id: @site.id), params: {
          inspection: { image: fixture_file_upload("panel.png", "image/png"), conducted_at: Time.current }
        }
      end
    end

    inspection = @site.inspections.order(:created_at).last
    assert inspection.image.attached?
    assert_redirected_to inspection_path(inspection)
  end

  test "画像なしでは点検を作成せず、解析ジョブも登録しない" do
    assert_no_difference -> { Inspection.count } do
      assert_no_enqueued_jobs(only: AnalyzePanelImageJob) do
        post inspections_path(site_id: @site.id), params: { inspection: { conducted_at: Time.current } }
      end
    end

    assert_response :unprocessable_entity
    assert_match "画像を選択してください", response.body
  end

  test "削除する" do
    assert_difference -> { Inspection.count }, -1 do
      delete inspection_path(inspections(:failed), site_id: @site.id)
    end

    assert_redirected_to inspections_path
  end
end
