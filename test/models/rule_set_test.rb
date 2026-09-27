require "test_helper"

class RuleSetTest < ActiveSupport::TestCase
  setup do
    @initial = load_initial_rule_set
  end

  test "シードの初期値は有効で、全種類の閾値がそろっている" do
    assert @initial.active?
    assert_equal RuleSet::ANOMALY_TYPES.sort, @initial.severity_rules.map(&:anomaly_type).sort

    hotspot = @initial.rule_for("hotspot")
    assert_equal [ 2, 5, 15 ], [ hotspot.normalized_mild, hotspot.normalized_warning, hotspot.normalized_critical ].map(&:to_i)
    assert_equal "region_max", hotspot.measure
  end

  test "シードは何度実行しても増えない" do
    assert_no_difference -> { RuleSet.count } do
      load_initial_rule_set
    end
  end

  test "複製すると同じ閾値の新しいルールセット（未保存）になる" do
    copy = @initial.duplicate(version: "v2")

    assert copy.new_record?
    assert_not copy.active?
    assert copy.save
    assert_equal @initial.rule_for("hotspot").normalized_critical, copy.rule_for("hotspot").normalized_critical
  end

  test "mild < warning < critical でなければ保存できない" do
    copy = @initial.duplicate(version: "v2")
    copy.rule_for("hotspot").normalized_warning = 20

    assert_not copy.save
    assert copy.rule_for("hotspot").errors[:base].any? { |m| m.include?("mild < warning < critical") }
  end

  test "生ΔT の系列も順序を検証する" do
    copy = @initial.duplicate(version: "v2")
    copy.rule_for("module_wide").raw_mild = 3

    assert_not copy.save
  end

  test "閾値の無い種類があれば保存できない" do
    copy = @initial.duplicate(version: "v2")
    copy.severity_rules.delete(copy.rule_for("panel_row_group"))

    assert_not copy.save
    assert copy.errors[:base].any? { |m| m.include?("panel_row_group") }
  end

  test "検出パラメータが欠けていれば保存できない" do
    copy = @initial.duplicate(version: "v2")
    copy.detection_params = copy.detection_params.except("panel_mad_floor_c")

    assert_not copy.save
    assert copy.errors[:detection_params].any?
  end

  test "作成済みのルールセットは編集できない（active の切り替えだけできる）" do
    assert_not @initial.update(version: "changed")
    assert_not @initial.update(note: "changed")
    assert_raises(ActiveRecord::ReadOnlyRecord) { @initial.rule_for("hotspot").update!(normalized_critical: 99) }
  end

  test "削除できない" do
    assert_not @initial.destroy
    assert RuleSet.exists?(@initial.id)
  end

  test "有効にできるのは常に1つだけ" do
    copy = @initial.duplicate(version: "v2")
    copy.save!

    copy.activate!

    assert copy.reload.active?
    assert_not @initial.reload.active?
    assert_equal copy, RuleSet.active_set
  end
end
