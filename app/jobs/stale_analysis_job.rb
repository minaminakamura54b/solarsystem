# 長時間 analyzing（または品質チェック待ち）のまま残った画像・旧方式の点検を failed にする定期ジョブ
# （docs/IMPROVEMENT_PLAN.md Phase 4-9、docs/ARCHITECTURE.md の既知の問題 I）。
# ワーカーが途中で落ちるとジョブの rescue に到達せず、ステータスが残って画面の自動更新が止まらないため。
# パネル・アラートは変更しない。時間は config/analyzer.yml の stale_after_minutes
class StaleAnalysisJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    limit = now - AnalyzerConfig.current.stale_after_minutes.minutes
    affected = []

    InspectionImage.where(analysis_status: "analyzing").where(updated_at: ...limit).find_each do |image|
      fail_image(image, "stale_analysis", "解析が長時間終わらなかったため中断しました", now)
      affected << image.inspection
    end
    InspectionImage.where(analysis_status: "pending", quality_report: nil).where(updated_at: ...limit).find_each do |image|
      fail_image(image, "stale_quality_check", "品質チェックが長時間終わらなかったため中断しました", now)
      affected << image.inspection
    end
    affected.uniq.each(&:refresh_status!)

    # 旧方式（Claude の画像判定）の点検
    Inspection.where(analysis_status: "analyzing").where(updated_at: ...limit).find_each do |inspection|
      next unless inspection.legacy?

      inspection.update_columns(analysis_status: "failed", severity: nil, error_message: "解析が長時間終わらなかったため中断しました", updated_at: now)
    end
  end

  private

  def fail_image(image, reason, message, now)
    image.update_columns(analysis_status: "failed", review_reason: reason, error_message: message, updated_at: now)
  end
end
