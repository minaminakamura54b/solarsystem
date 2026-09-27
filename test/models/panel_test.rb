require "test_helper"

class PanelTest < ActiveSupport::TestCase
  test "パネル番号は発電所内で一意" do
    duplicate = Panel.new(site: sites(:south), number: "P001", position_x: 5, position_y: 5)

    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:number, :taken)
  end

  test "別の発電所なら同じ番号を使える" do
    panel = Panel.new(site: sites(:east), number: "P001", position_x: 0, position_y: 0)

    assert panel.valid?
  end

  test "status は定義済みの値のみ" do
    panel = panels(:p001)
    panel.status = "broken"

    assert_not panel.valid?
  end

  test "by_position は行（y）→列（x）の順に並べる" do
    assert_equal %w[P001 P002 P003], sites(:south).panels.by_position.map(&:number)
  end
end
