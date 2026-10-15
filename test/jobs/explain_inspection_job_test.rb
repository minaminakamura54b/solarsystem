require "test_helper"

class ExplainInspectionJobTest < ActiveJob::TestCase
  setup do
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
    @image.update_columns(analysis_status: "completed")
    @inspection.refresh_status!
    @confirmed = @image.anomalies.create!(inspection: @inspection, anomaly_type: "hotspot", severity: "warning",
                                          review_status: "confirmed", locked: true)
    @rejected = @image.anomalies.create!(inspection: @inspection, anomaly_type: "hotspot", severity: "critical",
                                         review_status: "rejected", rejection_reason: "glare", locked: true)
    @pending = @image.anomalies.create!(inspection: @inspection, anomaly_type: "hotspot", severity: "mild", review_status: "pending")
    @group = @image.anomaly_groups.create!(inspection: @inspection, group_type: "panel_row_group", panel_count: 2,
                                           panel_indices: [ 1, 2 ], severity: "mild", review_status: "confirmed", locked: true)
    @member = @image.anomalies.create!(inspection: @inspection, anomaly_group: @group, anomaly_type: "module_wide",
                                       severity: "mild", review_status: "confirmed", locked: true)
  end

  def complete!
    InspectionReview.new(@inspection).complete!(all_images_checked: true, acknowledge_pending: true)
  end

  test "確定した異常・群だけに所見を付け、総括文を作る（却下・未確定・群の構成パネルには付けない）" do
    complete!
    client = fake_claude_for_findings(anomaly_extra: { severity: "normal" })

    with_fake_claude(client) { ExplainInspectionJob.perform_now(@inspection.id) }

    assert @confirmed.reload.report_text.present?
    assert @group.reload.report_text.present?
    assert_nil @rejected.reload.report_text
    assert_nil @pending.reload.report_text
    assert_nil @member.reload.report_text
    assert @inspection.reload.summary_text.present?
    assert_equal 3, client.requests.size
    assert_equal [ "completed", "warning" ], [ @inspection.analysis_status, @inspection.severity ]
    assert_equal "warning", @confirmed.severity
  end

  test "2回目は入力が変わっていなければ呼ばない。force なら作り直す" do
    complete!
    with_fake_claude(fake_claude_for_findings) { ExplainInspectionJob.perform_now(@inspection.id) }

    client = fake_claude_for_findings
    with_fake_claude(client) { ExplainInspectionJob.perform_now(@inspection.id) }
    assert_empty client.requests

    with_fake_claude(client) { ExplainInspectionJob.perform_now(@inspection.id, force: true) }
    assert_equal 3, client.requests.size
  end

  test "レビューを完了していない点検では何もしない" do
    client = fake_claude_for_findings

    with_fake_claude(client) { ExplainInspectionJob.perform_now(@inspection.id) }

    assert_empty client.requests
    assert_nil @confirmed.reload.report_text
  end

  test "API が失敗しても、点検・異常・パネル・発電所の状態は変えない" do
    complete!
    panel = @inspection.site.panels.create!(number: "P-1", position_x: 0, position_y: 0)
    @confirmed.update_columns(panel_id: panel.id)
    before = [ panel.reload.attributes, @inspection.site.reload.attributes, @inspection.reload.attributes.slice("analysis_status", "severity", "reviewed_at") ]
    error = Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com/v1/messages"))

    with_fake_claude(FakeAnthropicClient.raising(error)) { ExplainInspectionJob.perform_now(@inspection.id) }

    assert @confirmed.reload.explanation_error.present?
    assert @group.reload.explanation_error.present?
    assert @inspection.reload.summary_error.present?
    after = [ panel.reload.attributes, @inspection.site.reload.attributes, @inspection.attributes.slice("analysis_status", "severity", "reviewed_at") ]
    assert_equal before, after
    assert_equal "warning", @confirmed.severity
  end
end
