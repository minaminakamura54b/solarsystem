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
