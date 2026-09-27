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

  test "発電所一覧" do
    get sites_path
    assert_response :success
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
