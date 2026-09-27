require "test_helper"

# 主要画面が表示できることだけを確認するスモークテスト
class PagesSmokeTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
  end

  test "トップページ" do
    get root_path
    assert_response :success
  end

  test "ダッシュボード" do
    get dashboard_path(site_id: @site.id)
    assert_response :success
  end

  test "ダッシュボードの直近の点検で、失敗した点検を正常と表示しない" do
    Alert.delete_all
    Inspection.where.not(id: inspections(:failed).id).delete_all

    get dashboard_path(site_id: @site.id)

    assert_response :success
    assert_select "td .badge", count: 0
    assert_select "td", text: "-"
  end

  test "発電所一覧" do
    get sites_path
    assert_response :success
  end

  test "発電所の新規・編集フォーム（モジュール仕様を含む）" do
    get new_site_path
    assert_response :success
    assert_select "textarea[name='site[bypass_pattern_json]']"

    get edit_site_path(@site)
    assert_response :success
    assert_select "select[name='site[cell_layout]']"
  end

  test "判定基準（ルールセットが無くても表示できる）" do
    get rule_sets_path
    assert_response :success
    assert_match "db:seed", response.body
  end

  test "アラート一覧" do
    get alerts_path(site_id: @site.id)
    assert_response :success
  end

  test "売電実績一覧" do
    get revenues_path(site_id: @site.id)
    assert_response :success
  end

  test "新規点検" do
    get new_inspection_path(site_id: @site.id)
    assert_response :success
  end
end
