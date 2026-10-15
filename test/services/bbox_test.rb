require "test_helper"

class BboxTest < ActiveSupport::TestCase
  def box(x1, y1, x2, y2) = { "x1" => x1, "y1" => y1, "x2" => x2, "y2" => y2 }

  test "同じ bbox の IoU は 1" do
    assert_in_delta 1.0, Bbox.iou(box(0.1, 0.1, 0.2, 0.2), box(0.1, 0.1, 0.2, 0.2))
  end

  test "半分ずれると IoU は 1/3" do
    assert_in_delta 1.0 / 3, Bbox.iou(box(0.0, 0.0, 0.2, 0.1), box(0.1, 0.0, 0.3, 0.1)), 1e-6
  end

  test "重ならなければ 0、片方が不正でも 0" do
    assert_equal 0.0, Bbox.iou(box(0, 0, 0.1, 0.1), box(0.5, 0.5, 0.6, 0.6))
    assert_equal 0.0, Bbox.iou(box(0, 0, 0.1, 0.1), nil)
  end

  test "パネル全体の中の小さな領域は IoU が小さい（別の異常として残る）" do
    assert Bbox.iou(box(0.1, 0.1, 0.2, 0.2), box(0.14, 0.14, 0.15, 0.15)) < 0.5
  end

  test "normalize は座標の順序をそろえ 0〜1 に収める" do
    assert_equal box(0.1, 0.0, 0.5, 1.0), Bbox.normalize(box(0.5, -0.2, 0.1, 1.3))
  end
end
