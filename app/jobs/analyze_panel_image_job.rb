class AnalyzePanelImageJob < ApplicationJob
  queue_as :default

  def perform(inspection_id)
    inspection = Inspection.find_by(id: inspection_id)
    return unless inspection

    inspection.update!(analysis_status: "analyzing")

    result = ClaudePanelAnalyzer.new(inspection).analyze

    inspection.update!(
      analysis_status: result[:error] ? "failed" : "completed",
      severity: result[:severity],
      anomaly_count: result[:anomaly_count],
      anomalies: result[:anomalies],
      result: result[:summary],
      report: build_report(result)
    )

    inspection.site.panels.update_all(last_inspected_at: inspection.conducted_at)

    if result[:anomaly_count] > 0
      create_alert(inspection, result)
      update_panel_statuses(inspection, result)
    end
  rescue => e
    Rails.logger.error("AnalyzePanelImageJob failed: #{e.message}")
    inspection&.update!(analysis_status: "failed", result: "解析中にエラーが発生しました: #{e.message}")
  end

  private

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

  def create_alert(inspection, result)
    severity = result[:severity] == "critical" ? "critical" : "warning"
    Alert.create!(
      site: inspection.site,
      inspection: inspection,
      title: "#{inspection.conducted_at.strftime('%Y/%m/%d')} 点検で#{result[:anomaly_count]}件の異常を検出",
      message: result[:summary],
      severity: severity
    )
  end

  def update_panel_statuses(inspection, result)
    return if result[:anomalies].blank?
    panels = inspection.site.panels.order(:position_y, :position_x)
    total = panels.count
    return if total.zero?

    result[:anomalies].each_with_index do |anomaly, idx|
      panel = panels[idx % total]
      next unless panel
      new_status = anomaly["severity"] == "critical" ? "error" : "warning"
      panel.update!(status: new_status) if panel.status == "normal"
    end
  end
end
