require "test_helper"

# Claude の所見・総括文の作成の状態（修正案 13）
class FindingsStatusTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
    @image.update_columns(analysis_status: "completed")
    @inspection.refresh_status!
    @anomaly = @image.anomalies.create!(inspection: @inspection, anomaly_type: "hotspot", severity: "warning", review_status: "confirmed", locked: true)
  end

  def complete! = assert InspectionReview.new(@inspection).complete!(all_images_checked: true).completed?

  test "失敗の理由は日本語の分類にする" do
    assert_match "API キーが無効です", FindingsStatus.reason_label("Claude API がエラーを返しました（HTTP 401 authentication_error）")
    assert_match "混み合っています", FindingsStatus.reason_label("Claude API がエラーを返しました（HTTP 429 rate_limit_error）")
    assert_match "Claude 側の障害", FindingsStatus.reason_label("Claude API がエラーを返しました（HTTP 529 overloaded_error）")
  end

  test "使わない点検は disabled、使うのに設定が足りなければ config_missing" do
    assert_equal :disabled, FindingsStatus.new(@inspection).state

    @inspection.update_columns(claude_enabled: true, claude_enabled_changed_at: 1.minute.ago)
    complete!
    assert_equal :config_missing, FindingsStatus.new(@inspection).state
  end

  test "作れなかった所見・総括文を理由つきで数え、作り直したら done" do
    @inspection.update_columns(claude_enabled: true, claude_enabled_changed_at: 1.minute.ago)
    complete!
    with_fake_claude(FakeAnthropicClient.raising(Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com/v1/messages")))) do
      ExplainInspectionJob.perform_now(@inspection.id)
      status = FindingsStatus.new(@inspection.reload)
      assert_equal :failed, status.state
      assert_equal 2, status.failures.size
      assert_match "接続できませんでした", status.failures.first.reason
    end

    with_fake_claude(fake_claude_for_findings) do
      ExplainInspectionJob.perform_now(@inspection.id, force: true)
      assert_equal :done, FindingsStatus.new(@inspection.reload).state
    end
  end

  test "レビュー完了の後に「使う」にしたら not_requested（「所見を作る」で作る）" do
    complete!
    @inspection.update_columns(claude_enabled: true, claude_enabled_changed_at: 1.minute.from_now)
    with_fake_claude(fake_claude_for_findings) do
      assert_equal :not_requested, FindingsStatus.new(@inspection.reload).state
    end
  end
end
