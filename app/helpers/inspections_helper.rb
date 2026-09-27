module InspectionsHelper
  INSPECTION_STATUS_LABELS = {
    "pending" => "待機中", "analyzing" => "解析中", "completed" => "完了",
    "needs_review" => "要確認", "failed" => "失敗"
  }.freeze

  IMAGE_STATUS_BADGES = {
    "analyzing" => "badge-info", "completed" => "badge-success",
    "needs_review" => "badge-warning", "failed" => "badge-error", "excluded" => "badge-gray"
  }.freeze

  def inspection_status_label(inspection)
    return "解析待ち（解析エンジン未接続）" if waiting_for_analyzer_only?(inspection)

    INSPECTION_STATUS_LABELS.fetch(inspection.analysis_status, inspection.analysis_status)
  end

  def image_status_label(image)
    case image.analysis_status
    when "pending" then image.quality_pending? ? "品質チェック中" : "解析待ち（解析エンジン未接続）"
    when "analyzing" then "解析中"
    when "completed" then "解析完了"
    when "needs_review" then "要確認"
    when "failed" then "失敗"
    when "excluded" then "除外"
    end
  end

  def image_status_badge_class(image)
    IMAGE_STATUS_BADGES.fetch(image.analysis_status, "badge-gray")
  end

  # 要確認の理由（品質チェックの rejected 項目のメッセージ）
  def image_review_message(image)
    return image.error_message if image.failed?

    check = Array(image.quality_report&.dig("checks")).find { |c| c["key"] == image.review_reason }
    check&.dig("message") || image.review_reason
  end

  def quality_check_icon(result)
    { "ok" => "✓", "warning" => "△", "rejected" => "✕" }.fetch(result, "?")
  end

  def radiometric_label(image)
    case image.is_radiometric
    when true then "あり（仮判定）"
    when false then "なし"
    else "不明"
    end
  end

  def irradiance_label(image)
    return "-" if image.irradiance_w_m2.nil?

    type = { "poa" => "POA", "ghi" => "GHI", "unknown" => "種類不明" }.fetch(image.irradiance_type.to_s, "種類不明")
    "#{image.irradiance_w_m2.to_f.round} W/m²（#{type}）"
  end

  private

  def waiting_for_analyzer_only?(inspection)
    return false if inspection.legacy?

    active = inspection.inspection_images.reject(&:excluded?)
    active.any? && active.all? { |i| i.pending? && !i.quality_pending? }
  end
end
