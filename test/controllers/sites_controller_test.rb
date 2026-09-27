require "test_helper"

class SitesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
  end

  test "モジュール仕様を更新できる（更新後は発電所一覧に戻る）" do
    patch site_path(@site), params: { site: {
      module_model: "XX-400M", module_rated_w: 400, cell_layout: "full_cell", substring_count: 3,
      bypass_pattern_json: '{"layout": "full_cell", "bands": 3}'
    } }

    assert_redirected_to sites_path
    @site.reload
    assert_equal "XX-400M", @site.module_model
    assert_equal 400, @site.module_rated_w
    assert_equal({ "layout" => "full_cell", "bands" => 3 }, @site.bypass_pattern)
  end

  test "発熱パターンの JSON が不正なら更新しない" do
    patch site_path(@site), params: { site: { bypass_pattern_json: "{bands" } }

    assert_response :unprocessable_entity
    assert_nil @site.reload.bypass_pattern
  end

  test "発電所を作成するとパネルを仮配置（auto）で自動生成する" do
    post sites_path, params: { site: { name: "新発電所", location: "長野県", panel_count: 4, capacity_kw: 1.6, status: "active" } }

    site = Site.find_by!(name: "新発電所")
    assert_equal 4, site.panels.count
    assert site.panels.all? { |p| p.layout_source == "auto" && p.status == "normal" }
  end

  test "ダッシュボードに仮配置であることを表示する" do
    get dashboard_path(site_id: @site.id)

    assert_match "仮配置です", response.body
  end
end
