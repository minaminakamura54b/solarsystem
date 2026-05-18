module ApplicationHelper
  def extract_recommendation(report)
    return nil if report.blank? || report.strip.start_with?("{")

    lines = report.split("\n")
    idx = lines.index { |l| l.include?("推奨アクション") }
    return nil unless idx

    lines[idx + 1..].reject(&:blank?).join("\n").strip.presence
  end
end
