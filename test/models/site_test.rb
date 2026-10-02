require "test_helper"

class SiteTest < ActiveSupport::TestCase
  test "名前と所在地は必須" do
    site = Site.new(panel_count: 0, capacity_kw: 0, status: "active")

    assert_not site.valid?
    assert site.errors.of_kind?(:name, :blank)
    assert site.errors.of_kind?(:location, :blank)
  end

  test "パネルの状態別件数を返す" do
    assert_equal({ "normal" => 3 }, sites(:south).panel_status_summary)
  end

  test "最新の点検を返す" do
    assert_equal inspections(:pending), sites(:south).latest_inspection
  end
end

class SiteModuleSpecTest < ActiveSupport::TestCase
  setup do
    @site = sites(:south)
  end

  test "バイパス作動時の発熱パターンを JSON で設定できる" do
    @site.update!(bypass_pattern_json: '{"layout": "full_cell", "bands": 3}')

    assert_equal({ "layout" => "full_cell", "bands" => 3 }, @site.reload.bypass_pattern)
  end

  test "不正な JSON は保存できない" do
    assert_not @site.update(bypass_pattern_json: "{bands: 3")
    assert @site.errors[:bypass_pattern].any?
  end

  test "空欄なら未設定（nil）" do
    @site.update!(bypass_pattern_json: '{"bands": 3}')
    @site.update!(bypass_pattern_json: "")

    assert_nil @site.reload.bypass_pattern
  end

  test "セル構成は定義済みの値のみ" do
    assert_not @site.update(cell_layout: "quarter_cut")
    assert @site.update(cell_layout: "half_cut")
  end

  test "自動生成（auto）のパネルは仮配置" do
    assert panels(:p001).placeholder_layout?

    panels(:p001).update!(layout_source: "manual")
    assert_not panels(:p001).placeholder_layout?
  end
end
