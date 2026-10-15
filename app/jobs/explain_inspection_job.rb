# レビューを完了した点検について、確定した異常・群の所見と点検の総括文を Claude に書かせる（docs/IMPROVEMENT_PLAN.md Phase 6）。
# レビュー完了のときと「所見を作り直す」のときに登録する（2026-10-15 ユーザー承認）。
# 入力が前回と同じ異常は作り直さない（force: true のときは作り直す）。1件が失敗しても残りは続ける。
# 所見の成否は、点検・異常の判定や状態（severity・analysis_status・Panel・Site）に影響しない
class ExplainInspectionJob < ApplicationJob
  queue_as :default

  def perform(inspection_id, force: false)
    inspection = Inspection.find_by(id: inspection_id)
    return unless inspection&.completed? && inspection.reviewed_at.present?

    output = ClaudeStructuredOutput.new
    explainer = AnomalyExplainer.new(output: output)
    targets(inspection).each { |record| explainer.explain(record, force: force) }

    # 所見を書いている間にレビューが取り消されていたら、総括文は作らない
    InspectionSummaryWriter.new(output: output).write(inspection, force: force) if inspection.reload.completed?
  end

  private

  def targets(inspection)
    confirmed = InspectionReview::CONFIRMED
    inspection.anomalies.where(review_status: confirmed).countable
              .includes(:panel, :inspection_image, inspection: :site).order(:id).to_a +
      inspection.anomaly_groups.where(review_status: confirmed)
                .includes(:inspection_image, inspection: :site, anomalies: :panel).order(:id).to_a
  end
end
