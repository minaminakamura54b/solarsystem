require "test_helper"

# レビュー完了で所見・総括文を作り、点検詳細とレビュー画面に表示する（docs/IMPROVEMENT_PLAN.md Phase 6）
class FindingsFlowTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    load_initial_rule_set
    @inspection = analyzable_inspection
    @inspection.update_columns(claude_enabled: true) # Claude を「使う」にした点検（既定は使わない）
    @image = @inspection.inspection_images.first
    with_fake_analyzer(analyze: analyzer_result(output: analyzer_output)) { AnalyzeInspectionImageJob.perform_now(@image.id) }
    @anomaly = @image.anomalies.sole
  end

  def confirm_and_complete
    patch confirm_inspection_anomaly_path(@inspection, @anomaly, site_id: @site.id)
    post complete_review_inspection_path(@inspection, site_id: @site.id), params: { all_images_checked: "1" }
  end

  test "レビューを完了すると所見のジョブを登録する。完了できなかったときは登録しない" do
    assert_no_enqueued_jobs only: ExplainInspectionJob do
      post complete_review_inspection_path(@inspection, site_id: @site.id), params: { all_images_checked: "1" }
    end

    assert_enqueued_with(job: ExplainInspectionJob, args: [ @inspection.id ]) { confirm_and_complete }
    assert_match "所見と総括文を Claude で作成します", flash[:notice]
  end

  test "Claude を使わない点検（既定）は、所見のジョブを登録せず、人が所見と総括文を書いて保存できる" do
    @inspection.update_columns(claude_enabled: false)
    assert_no_enqueued_jobs(only: ExplainInspectionJob) { confirm_and_complete }
    assert_match "所見と総括文は「所見・総括」の欄に書いてください", flash[:notice]

    get inspection_path(@inspection, site_id: @site.id)
    assert_match "所見・総括（人が書く）", response.body
    assert_select "#claude", text: /使わない/
    assert_select "#transmissions", text: /送ったことはありません/

    patch findings_inspection_path(@inspection, site_id: @site.id),
          params: { manual_summary: "  確定した熱異常は 1 件でした。 ", anomaly_findings: { @anomaly.id => "セルの割れの可能性があります" } }
    assert_redirected_to inspection_path(@inspection, anchor: "findings")
    assert_equal "確定した熱異常は 1 件でした。", @inspection.reload.manual_summary
    assert_equal "セルの割れの可能性があります", @anomaly.reload.manual_finding
    assert_equal "confirmed", @anomaly.review_status, "判定・レビューの状態は変えない"

    snapshot = ReportSnapshotBuilder.new(@inspection).build
    assert_equal "確定した熱異常は 1 件でした。", snapshot.dig("summary", "text")
    assert_equal [ "manual", "セルの割れの可能性があります" ], snapshot["items"].first.values_at("explanation_state", "explanation")
    assert_not snapshot["claude_used"]
  end

  test "「使う」にするには顧客との取り決めの確認が要る。切り替えると Claude で作り、送った内容を記録する" do
    @inspection.update_columns(claude_enabled: false)
    patch claude_setting_inspection_path(@inspection, site_id: @site.id), params: { claude_enabled: "1" }
    assert_not @inspection.reload.claude_enabled?

    patch claude_setting_inspection_path(@inspection, site_id: @site.id), params: { claude_enabled: "1", agreement_confirmed: "1" }
    assert @inspection.reload.claude_enabled?
    assert @inspection.claude_enabled_changed_at

    confirm_and_complete
    with_fake_claude(fake_claude_for_findings) { perform_enqueued_jobs(only: ExplainInspectionJob) }
    logs = @inspection.external_transmissions.order(:id).to_a
    assert_equal %w[anomaly_explanation inspection_summary], logs.map(&:purpose)
    assert_equal %w[sent sent], logs.map(&:status)
    assert_equal @anomaly, logs.first.target
    assert_includes logs.last.input_text, "確定した異常: 1 件"
    get inspection_path(@inspection, site_id: @site.id)
    assert_select "#transmissions", text: /点検の総括文/

    patch claude_setting_inspection_path(@inspection, site_id: @site.id), params: { claude_enabled: "0" }
    assert_not @inspection.reload.claude_enabled?
    assert_no_difference -> { ExternalTransmission.count } do
      post explain_inspection_path(@inspection, site_id: @site.id)
      with_fake_claude(fake_claude_for_findings) { perform_enqueued_jobs(only: ExplainInspectionJob) }
    end
  end

  test "完了後の点検詳細に総括文と所見を表示し、判定に使っていないことを示す" do
    with_fake_claude(fake_claude_for_findings) do
      perform_enqueued_jobs(only: ExplainInspectionJob) { confirm_and_complete }
    end

    get inspection_path(@inspection, site_id: @site.id)

    assert_response :success
    assert_select "#findings"
    assert_match "確定した熱異常は 1 件でした。", response.body
    assert_match "サブストリング 2 本分の帯状の発熱", response.body
    assert_match "バイパスダイオードの故障", response.body
    assert_match "判定には使っていません", response.body
    assert_select "#findings button", text: "所見を作り直す"

    get review_path
    assert_match "所見（Claude）", response.body
  end

  test "所見を作った後にデータが変わると、古い所見であることを表示する。失敗はエラーとして表示する" do
    with_fake_claude(fake_claude_for_findings) do
      perform_enqueued_jobs(only: ExplainInspectionJob) { confirm_and_complete }
    end
    @anomaly.update_columns(evidence_level: "A")
    @inspection.update_columns(summary_error: "Claude API に接続できませんでした（APIConnectionError）")

    get inspection_path(@inspection, site_id: @site.id)

    assert_match "この所見を作った後に、異常のデータが変わっています", response.body
    assert_match "総括文を作れませんでした: Claude API に接続できませんでした", response.body
  end

  test "所見を作り直すと force で登録する。レビュー未完了の点検では登録しない" do
    assert_no_enqueued_jobs only: ExplainInspectionJob do
      post explain_inspection_path(@inspection, site_id: @site.id)
    end
    assert_match "レビューを完了した点検だけ", flash[:alert]

    confirm_and_complete
    assert_enqueued_with(job: ExplainInspectionJob, args: [ @inspection.id, { force: true } ]) do
      post explain_inspection_path(@inspection, site_id: @site.id)
    end
    assert_redirected_to inspection_path(@inspection, anchor: "findings")
  end

  test "レビュー前の点検詳細には所見の欄を出さない" do
    get inspection_path(@inspection, site_id: @site.id)

    assert_response :success
    assert_select "#findings", count: 0
  end

  private

  def review_path = review_inspection_path(@inspection, image: @image.sequence, site_id: @site.id)
end
