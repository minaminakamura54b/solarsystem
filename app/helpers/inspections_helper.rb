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
    return "レビュー待ち" if inspection.needs_review? && inspection.review_reason == "review_pending"

    INSPECTION_STATUS_LABELS.fetch(inspection.analysis_status, inspection.analysis_status)
  end

  # 解析エンジン・ジョブが付ける要確認・失敗の理由（品質チェックの理由は quality_report の message を使う）
  REVIEW_REASON_MESSAGES = {
    "grid_required" => "グリッド（パネル配列の4隅と行数・列数）の指定が必要です",
    "sdk_unavailable" => "DJI Thermal SDK が無いため温度データを取得できません",
    "unsupported_format" => "このサーモ画像の形式にはまだ対応していません",
    "insufficient_baseline" => "基準温度を出すための正常パネルが足りません（パネル群全体が温まっている可能性があります）",
    "timeout" => "解析エンジンが時間内に終わりませんでした",
    "stale_analysis" => "解析が長時間終わらなかったため中断しました",
    "stale_quality_check" => "品質チェックが長時間終わらなかったため中断しました",
    "no_rule_set" => "有効な判定基準（ルールセット）がありません",
    "invalid_output" => "解析エンジンの出力を読めませんでした",
    "command_not_found" => "解析エンジンを起動できませんでした"
  }.freeze

  def image_status_label(image)
    case image.analysis_status
    when "pending" then image.quality_pending? ? "品質チェック中" : "解析待ち"
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
    check = Array(image.quality_report&.dig("checks")).find { |c| c["key"] == image.review_reason && c["result"] == "rejected" }
    return check["message"] if check

    REVIEW_REASON_MESSAGES[image.review_reason] || image.error_message.presence || image.review_reason
  end

  def inspection_review_message(inspection)
    {
      "review_pending" => "すべての画像の解析が終わりました。異常の候補の確認（レビュー）が必要です",
      "images_need_review" => "要確認の画像があります"
    }[inspection.review_reason]
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

end
