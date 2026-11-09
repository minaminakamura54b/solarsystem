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

  test "基準温度の取り方を位置の傾向にした暫定の版をシードで作る（自動では有効にしない。閾値は初期値と同じ）" do
    trend = RuleSet.find_by!(version: "2026-11-trend-provisional")

    assert_not trend.active?
    assert_equal "position_trend", trend.baseline_method
    assert_equal "image_median", @initial.baseline_method, "省略時は画像全体の中央値"
    assert_match "暫定", trend.note
    assert_equal @initial.severity_rules.map(&:snapshot).map { |h| h.except("version") }, trend.severity_rules.map(&:snapshot).map { |h| h.except("version") }
    assert_equal "position_trend", trend.to_analyzer_rules["detection_params"]["baseline_method"]
  end

  test "基準温度の取り方は image_median か position_trend だけ" do
    copy = @initial.duplicate(version: "bad-method")
    copy.detection_params = copy.detection_params.merge("baseline_method" => "other")
    assert_not copy.valid?
    assert_match "baseline_method", copy.errors.full_messages.join
  end

  test "架台・段の閾値（block_row）は無くてもよい種類。入れた版では解析エンジンには渡さない" do
    row = RuleSet.find_by!(version: "2026-11-trend-row-provisional")
    rule = row.rule_for("block_row")

    assert_equal [ "row_effect", 0.8, 1.5, 3.0 ], [ rule.measure, rule.raw_mild.to_f, rule.raw_warning.to_f, rule.raw_critical.to_f ]
    assert_match "暫定値", row.note
    assert_match "仮の値", row.note
    assert_not row.active?
    assert_nil @initial.rule_for("block_row")
    assert_not_includes row.to_analyzer_rules["severity_rules"].map { |r| r["anomaly_type"] }, "block_row"
    assert @initial.valid?, "block_row の無い版も有効なまま"
  end

  test "暫定の 2 つの版はシードで暫定の印が付き、初期値には付かない。複製した版は暫定のまま" do
    assert RuleSet.find_by!(version: "2026-11-trend-provisional").provisional?
    assert RuleSet.find_by!(version: "2026-11-trend-row-provisional").provisional?
    assert_not @initial.provisional?
    assert RuleSet.find_by!(version: "2026-11-trend-provisional").duplicate(version: "copy").provisional
  end

  test "暫定の印は付けられるが、ほかの項目は変えない（作成後は編集できない）" do
    @initial.mark_provisional!

    assert @initial.reload.provisional?
    assert_equal "2026-09-initial", @initial.version
  end
end
