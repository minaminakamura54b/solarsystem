class ClaudePanelAnalyzer
  MODEL = "claude-opus-4-7"

  SYSTEM_PROMPT = <<~PROMPT
    あなたは太陽光発電パネルの異常検知専門AIです。
    ドローンで撮影されたパネル画像を解析し、以下の異常を検出してください：
    - ホットスポット（熱異常）
    - クラック・破損
    - 汚染・堆積物
    - 接続不良・影響
    - その他の異常

    必ずJSON形式で回答してください。フォーマットは以下の通りです：
    {
      "severity": "normal" | "warning" | "critical",
      "anomaly_count": 数値,
      "anomalies": [
        {
          "type": "異常種別",
          "location": "画像内の位置（例：左上、中央など）",
          "description": "詳細説明",
          "severity": "warning" | "critical"
        }
      ],
      "summary": "全体サマリー（1〜2文）",
      "recommendation": "推奨アクション"
    }
  PROMPT

  def initialize(inspection)
    @inspection = inspection
    @client = Anthropic::Client.new(access_token: ENV.fetch("ANTHROPIC_API_KEY"))
  end

  def analyze
    return error_result("画像が添付されていません") unless @inspection.image.attached?

    image_data = download_image_base64
    return error_result("画像の読み込みに失敗しました") unless image_data

    response = @client.messages(
      parameters: {
        model: MODEL,
        max_tokens: 1024,
        system: SYSTEM_PROMPT,
        messages: [
          {
            role: "user",
            content: [
              {
                type: "image",
                source: {
                  type: "base64",
                  media_type: image_content_type,
                  data: image_data
                }
              },
              {
                type: "text",
                text: "この太陽光パネル画像を解析して、異常があれば報告してください。"
              }
            ]
          }
        ]
      }
    )

    parse_response(response.dig("content", 0, "text"))
  rescue Anthropic::Error => e
    error_result("Claude API エラー: #{e.message}")
  rescue => e
    error_result("解析エラー: #{e.message}")
  end

  private

  def download_image_base64
    @inspection.image.download.then { |data| Base64.strict_encode64(data) }
  rescue => e
    Rails.logger.error("Image download failed: #{e.message}")
    nil
  end

  def image_content_type
    @inspection.image.content_type || "image/jpeg"
  end

  def parse_response(text)
    # コードブロック記法を除去
    cleaned = text.gsub(/```json\s*/i, "").gsub(/```/, "").strip

    # JSON部分を抽出（[\s\S]でマルチライン対応）
    json_text = cleaned.match(/\{[\s\S]*\}/)&.to_s
    return error_result("JSON形式の応答が得られませんでした") unless json_text

    result = JSON.parse(json_text)
    {
      severity: result["severity"] || "normal",
      anomaly_count: result["anomaly_count"].to_i,
      anomalies: result["anomalies"] || [],
      summary: result["summary"] || "",
      recommendation: result["recommendation"] || "",
      raw_text: text
    }
  rescue JSON::ParserError => e
    Rails.logger.error("ClaudePanelAnalyzer JSON parse error: #{e.message}")
    { severity: "normal", anomaly_count: 0, anomalies: [], summary: text, recommendation: "", raw_text: text }
  end

  def error_result(message)
    { severity: "normal", anomaly_count: 0, anomalies: [], summary: message, recommendation: "", error: message }
  end
end
