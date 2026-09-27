class AnalyzePanelImageJob < ApplicationJob
  queue_as :default

  def perform(inspection_id)
    inspection = Inspection.find_by(id: inspection_id)
    return unless inspection

    inspection.update!(analysis_status: "analyzing", error_message: nil)

    result = ClaudePanelAnalyzer.new(inspection).analyze

    # 失敗時は結果・パネル・アラートを一切変更しない
    return mark_failed(inspection, result[:error]) if result[:error]

    # 結果の保存・パネル更新・アラート作成は、途中で失敗したら何も残さない
    ActiveRecord::Base.transaction do
      inspection.update!(
        analysis_status: "completed",
        severity: result[:severity],
        anomaly_count: result[:anomaly_count],
        anomalies: result[:anomalies],
        result: result[:summary],
        report: build_report(result)
      )

      inspection.site.panels.update_all(last_inspected_at: inspection.conducted_at)

      upsert_alert(inspection, result) if result[:anomaly_count] > 0
    end
  rescue => e
    Rails.logger.error("AnalyzePanelImageJob failed: #{e.message}")
    mark_failed(inspection, "解析中にエラーが発生しました: #{e.message}") if inspection
  end

  private

  # トランザクションの外で確実に failed にする。
  # validation やロールバックの影響を受けないよう update_columns で書き込む
  def mark_failed(inspection, message)
    inspection.update_columns(
      analysis_status: "failed",
      severity: nil,
      error_message: message,
      updated_at: Time.current
    )
  end

  def build_report(result)
    lines = []
    lines << "## AI解析レポート"
    lines << ""
    lines << "### 概要"
    lines << result[:summary]
    lines << ""
    if result[:anomalies].any?
      lines << "### 検出された異常"
      result[:anomalies].each_with_index do |a, i|
        lines << "#{i + 1}. **#{a['type']}** (#{a['location']})"
        lines << "   #{a['description']}"
      end
      lines << ""
    end
    lines << "### 推奨アクション"
    lines << result[:recommendation]
    lines.join("\n")
  end

  # 1つの点検につきアラートは1件。再解析では最新の結果で更新し、重大度が上がったら未読に戻す。
  # 再解析で異常が0件になっても、既存のアラートは消さない（呼び出し側で anomaly_count > 0 のときだけ呼ぶ）
  def upsert_alert(inspection, result)
    severity = result[:severity] == "critical" ? "critical" : "warning"
    alert = inspection.alerts.order(:created_at).first_or_initialize(site: inspection.site)
    escalated = alert.persisted? && alert.severity == "warning" && severity == "critical"

    alert.assign_attributes(
      title: "#{inspection.conducted_at.strftime('%Y/%m/%d')} 点検で#{result[:anomaly_count]}件の異常を検出",
      message: result[:summary],
      severity: severity
    )
    alert.read_at = nil if escalated
    alert.save!
  end
end
