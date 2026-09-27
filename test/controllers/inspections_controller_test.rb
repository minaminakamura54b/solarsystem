require "test_helper"

# 現行の InspectionsController の挙動を記録するテスト。
# 「Phase 1 で変更」と書いたテストは、現状の問題のある挙動をそのまま記録したもので、
# Phase 1 で期待値を反転させる（docs/IMPROVEMENT_PLAN.md の Phase 1 を参照）。
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

  test "解析失敗の点検の詳細に失敗理由を表示する" do
    get inspection_path(inspections(:failed), site_id: @site.id)

    assert_response :success
    assert_match "解析に失敗しました", response.body
  end

  test "JSON でステータスを返す（自動更新のポーリング用）" do
    inspection = inspections(:analyzing)

    get inspection_path(inspection, format: :json, site_id: @site.id)

    assert_response :success
    body = response.parsed_body
    assert_equal inspection.id, body["id"]
    assert_equal "analyzing", body["analysis_status"]
  end

  test "解析中の詳細画面には自動更新が付く" do
    get inspection_path(inspections(:analyzing), site_id: @site.id)

    assert_select "[data-controller='auto-refresh']"
  end

  test "現状: pending の詳細画面には自動更新が付かない（Phase 1 で pending でも付くように変更）" do
    get inspection_path(inspections(:pending), site_id: @site.id)

    assert_response :success
    assert_select "[data-controller='auto-refresh']", count: 0
  end

  test "現状: GET の詳細表示で result の JSON を DB に書き戻す（Phase 1 で読み取り専用に変更）" do
    inspection = inspections(:completed_normal)
    inspection.update_columns(
      anomalies: [],
      result: { "severity" => "critical", "anomaly_count" => 3, "anomalies" => [ {}, {}, {} ], "summary" => "s" }.to_json
    )

    get inspection_path(inspection, site_id: @site.id)

    inspection.reload
    assert_equal "critical", inspection.severity, "GET なのに DB が更新される"
    assert_equal 3, inspection.anomaly_count
  end

  test "現状: GET の書き戻しで severity が無い JSON は normal で保存される（Phase 1 で読み取り専用に変更）" do
    inspection = inspections(:completed_warning)
    inspection.update_columns(anomalies: [], result: { "anomaly_count" => 1, "summary" => "s" }.to_json)

    get inspection_path(inspection, site_id: @site.id)

    assert_equal "normal", inspection.reload.severity, "warning だった点検が normal に上書きされる"
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

  test "現状: 画像なしでも点検を作成して解析ジョブを登録する（Phase 1 で作成不可に変更）" do
    assert_enqueued_with(job: AnalyzePanelImageJob) do
      post inspections_path(site_id: @site.id), params: { inspection: { conducted_at: Time.current } }
    end

    assert_not @site.inspections.order(:created_at).last.image.attached?
  end

  test "削除する" do
    assert_difference -> { Inspection.count }, -1 do
      delete inspection_path(inspections(:failed), site_id: @site.id)
    end

    assert_redirected_to inspections_path
  end
end
