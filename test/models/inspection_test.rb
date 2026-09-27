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

  test "analysis_status は定義済みの値のみ" do
    inspection = inspections(:pending)
    inspection.analysis_status = "needs_review"

    assert_not inspection.valid?, "needs_review はまだ定義されていない（Phase 2 で追加）"
  end

  test "現状: severity は常に必須で nil にできない（Phase 1 で completed のときだけ必須に変更）" do
    inspection = inspections(:failed)
    inspection.severity = nil

    assert_not inspection.valid?
    assert inspection.errors.of_kind?(:severity, :inclusion)
  end

  test "severity のラベルと色" do
    inspection = inspections(:completed_warning)

    assert_equal "注意", inspection.severity_label
    assert_equal "badge-warning", inspection.severity_color_class
  end
end
