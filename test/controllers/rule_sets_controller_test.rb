require "test_helper"

class RuleSetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @initial = load_initial_rule_set
  end

  def rule_params(rule_set, overrides = {})
    rules = rule_set.severity_rules.map.with_index do |rule, i|
      [ i.to_s, rule.attributes.slice(*SeverityRule::COPYABLE_ATTRIBUTES).merge(overrides.fetch(rule.anomaly_type, {})) ]
    end.to_h
    { severity_rules_attributes: rules, detection_params_json: rule_set.detection_params.to_json }
  end

  test "一覧と詳細を表示する" do
    get rule_sets_path
    assert_response :success
    assert_select "tr#rule_set_#{@initial.id} .badge", text: "有効"

    get rule_set_path(@initial)
    assert_response :success
    assert_match "ホットスポット", response.body
  end

  test "複製フォームは元の閾値を初期値にする" do
    get new_rule_set_path(from: @initial.id)

    assert_response :success
    assert_select "input[name='rule_set[severity_rules_attributes][0][normalized_critical]'][value='15.0']"
  end

  test "新しいバージョンを作成できる（まだ有効にはならない）" do
    assert_difference -> { RuleSet.count }, 1 do
      post rule_sets_path, params: { rule_set: { version: "2026-10-v2", note: "依頼元と合意" }.merge(rule_params(@initial, "hotspot" => { "normalized_critical" => "20" })) }
    end

    created = RuleSet.find_by!(version: "2026-10-v2")
    assert_redirected_to rule_set_path(created)
    assert_not created.active?
    assert_equal 20, created.rule_for("hotspot").normalized_critical
    assert @initial.reload.active?
  end

  test "閾値の順序が不正なら作成しない" do
    assert_no_difference -> { RuleSet.count } do
      post rule_sets_path, params: { rule_set: { version: "bad" }.merge(rule_params(@initial, "hotspot" => { "normalized_warning" => "30" })) }
    end

    assert_response :unprocessable_entity
    assert_match "mild &lt; warning &lt; critical", response.body
  end

  test "検出パラメータの JSON が不正なら作成しない" do
    params = rule_params(@initial).merge(detection_params_json: "{broken")

    assert_no_difference -> { RuleSet.count } do
      post rule_sets_path, params: { rule_set: { version: "bad-json" }.merge(params) }
    end

    assert_response :unprocessable_entity
    assert_match "JSON を読めません", response.body
  end

  test "有効にすると他のルールセットは無効になる" do
    copy = @initial.duplicate(version: "v2")
    copy.save!

    patch activate_rule_set_path(copy)

    assert copy.reload.active?
    assert_not @initial.reload.active?
  end

  test "編集・削除のルートは無い" do
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/rule_sets/#{@initial.id}/edit") }
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/rule_sets/#{@initial.id}", method: :delete) }
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/rule_sets/#{@initial.id}", method: :patch) }
  end
end
