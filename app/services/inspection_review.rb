# 点検の「レビュー完了」（docs/IMPROVEMENT_PLAN.md Phase 5。2026-10-15 ユーザー承認）。
# - 解析中・要確認・失敗の画像が残っていれば完了できない（除外するか解析を終える）
# - 「すべての画像を確認し、見逃しがない」ことの確認が必須（候補0件でも、人が異常なしを確認してから完了）
# - 未確定の候補が残っていれば警告し、残っていることを確認したときだけ完了できる。残った候補は重要度に入れない
# - 重要度 = 確定・修正した異常・群の最大重大度（mild / warning / critical）。無ければ normal
class InspectionReview
  CONFIRMED = %w[confirmed corrected].freeze
  SEVERITY_ORDER = %w[mild warning critical].freeze

  Result = Data.define(:completed, :errors, :warnings) do
    def completed? = completed
  end

  def initialize(inspection, now: Time.current)
    @inspection = inspection
    @now = now
  end

  # 完了できない理由
  def blockers
    images = @inspection.inspection_images.reload.reject(&:excluded?) # 判定には常に最新の状態を使う
    return [ "解析済みの画像がありません" ] if images.none?(&:completed?)

    labels = { "pending" => "解析待ち", "analyzing" => "解析中", "needs_review" => "要確認", "failed" => "失敗" }
    images.reject(&:completed?).group_by(&:analysis_status).map do |status, list|
      "#{labels.fetch(status, status)}の画像が #{list.size} 枚あります（画像 #{list.map(&:sequence).join('、')}。除外するか解析を終えてください）"
    end
  end

  def pending_candidates
    @inspection.candidate_count
  end

  def complete!(all_images_checked:, acknowledge_pending: false)
    errors = blockers
    errors << "「すべての画像を確認し、見逃しがない」ことを確認してください" unless all_images_checked
    warnings = []
    if pending_candidates.positive?
      warnings << "未確定の候補が #{pending_candidates} 件残っています。残った候補は重要度に入れず、候補のまま残ります"
      errors << "未確定の候補が残っていることを確認してください" unless acknowledge_pending
    end
    return Result.new(completed: false, errors: errors, warnings: warnings) if errors.any?

    @inspection.update_columns(analysis_status: "completed", severity: final_severity, review_reason: nil,
                               reviewed_at: @now, updated_at: @now)
    Result.new(completed: true, errors: [], warnings: warnings)
  end

  # 完了済みの点検をレビュー待ちに戻す（レビュー操作・再解析などで内容が変わったとき）
  def reopen!
    return unless @inspection.reload.completed? && @inspection.reviewed_at.present?

    @inspection.update_columns(analysis_status: "needs_review", review_reason: "review_pending", severity: nil,
                               reviewed_at: nil, updated_at: @now)
  end

  def final_severity
    severities = @inspection.anomalies.where(review_status: CONFIRMED).countable.map { |a| a.final_severity.presence || a.severity }
    severities += @inspection.anomaly_groups.where(review_status: CONFIRMED).map(&:severity)
    severities.compact.max_by { |s| SEVERITY_ORDER.index(s) || -1 } || "normal"
  end
end
