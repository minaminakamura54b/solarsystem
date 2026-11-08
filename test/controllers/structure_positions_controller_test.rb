require "test_helper"

# 発電所ごとの部材の位置の一覧と削除
class StructurePositionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    @position = @site.structure_positions.create!(block_row: 1, block_col: 1, u_bin: 0, v_bin: 2, bins: 4, note: "テスト")
  end

  test "一覧に位置と説明を出し、削除できる" do
    get site_structure_positions_path(@site)
    assert_response :success
    assert_select "#position_#{@position.id}", text: %r{1 段目・1 列目のパネル・パネルの中の区画（横 1/4・縦 3/4）}
    assert_match "自動では却下せず、検出も変えません", response.body

    delete site_structure_position_path(@site, @position)
    assert_redirected_to site_structure_positions_path(@site)
    assert_equal 0, @site.structure_positions.count
  end
end
