require "test_helper"

class InspectionTest < ActiveSupport::TestCase
  test "fixtures は有効" do
    assert inspections(:completed_warning).valid?
  end

  test "conducted_at は必須" do
    inspection = inspections(:pending)
    inspection.conducted_at = nil

    assert_not inspection.valid?
  end

  test "analysis_status は定義済みの値のみ（needs_review を含む）" do
    inspection = inspections(:pending)
    inspection.analysis_status = "needs_review"
    assert inspection.valid?

    inspection.analysis_status = "excluded"
    assert_not inspection.valid?, "excluded は画像だけのステータス"
  end

  test "失敗・未解析なら severity は nil（判定なし）でよい" do
    %i[failed pending analyzing].each do |name|
      inspection = inspections(name)
      inspection.severity = nil
      assert inspection.valid?, "#{name} は severity nil で有効"
    end
  end

  test "completed なら severity は必須" do
    inspection = inspections(:completed_normal)
    inspection.severity = nil

    assert_not inspection.valid?
    assert inspection.errors.of_kind?(:severity, :blank)
  end

  test "severity は定義済みの値のみ" do
    inspection = inspections(:failed)
    inspection.severity = "high"

    assert_not inspection.valid?
  end

  test "severity のデフォルトは nil（normal ではない）" do
    assert_nil Inspection.new.severity
  end

  test "画像なしでは作成できない" do
    inspection = sites(:south).inspections.build(conducted_at: Time.current)

    assert_not inspection.save
    assert_includes inspection.errors[:base], "サーモ画像を1枚以上選択してください"
  end

  test "サーモ画像付きなら作成できる" do
    inspection = sites(:south).inspections.build(conducted_at: Time.current)
    image = inspection.inspection_images.build(sequence: 1, thermal_filename: "panel.png")
    image.thermal.attach(io: file_fixture("panel.png").open, filename: "panel.png", content_type: "image/png")

    assert inspection.save
  end

  test "画像の無い既存の点検も、ステータスは更新できる" do
    inspection = inspections(:analyzing)
    assert_not inspection.image.attached?

    assert inspection.update(analysis_status: "failed")
  end

  test "severity が nil なら「判定なし」とグレーのバッジ" do
    inspection = inspections(:failed)

    assert_equal "判定なし", inspection.severity_label
    assert_equal "badge-gray", inspection.severity_color_class
  end

  test "pending と analyzing は解析待ち・解析中（in_progress?）" do
    assert inspections(:pending).in_progress?
    assert inspections(:analyzing).in_progress?
    assert_not inspections(:completed_normal).in_progress?
    assert_not inspections(:failed).in_progress?
  end

  test "severity のラベルと色" do
    inspection = inspections(:completed_warning)

    assert_equal "注意", inspection.severity_label
    assert_equal "badge-warning", inspection.severity_color_class
  end
end
