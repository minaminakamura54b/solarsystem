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

  class << self
    # テストで偽クライアントに差し替えるためのフック。本番では常に nil のまま使う
    attr_accessor :default_client
  end

  def initialize(inspection, client: nil)
    @inspection = inspection
    @client = client || self.class.default_client ||
      Anthropic::Client.new(access_token: ENV.fetch("ANTHROPIC_API_KEY"))
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
    return error_result("JSON の形式が想定と異なります", raw_text: text) unless result.is_a?(Hash)

    # severity が欠けている・想定外の値のときは normal で補わず、失敗として扱う
    unless Inspection::SEVERITIES.include?(result["severity"])
      return error_result("重大度（severity）が不正です: #{result["severity"].inspect}", raw_text: text)
    end

    anomalies = result.fetch("anomalies", [])
    return error_result("異常一覧（anomalies）の形式が不正です", raw_text: text) unless anomalies.is_a?(Array)

    # 件数・重大度・異常一覧が食い違う応答は信頼できないため、どれかを採用せず失敗として扱う
    # （件数だけを信じると、異常があってもアラートが出ない見逃しになる）
    if result.key?("anomaly_count") && Integer(result["anomaly_count"], exception: false) != anomalies.size
      return error_result("異常件数（anomaly_count: #{result["anomaly_count"].inspect}）と異常一覧の件数（#{anomalies.size}）が一致しません", raw_text: text)
    end
    if (result["severity"] == "normal") != anomalies.empty?
      return error_result("重大度（#{result["severity"]}）と異常一覧の件数（#{anomalies.size}）が矛盾しています", raw_text: text)
    end

    {
      severity: result["severity"],
      anomaly_count: anomalies.size,
      anomalies: anomalies,
      summary: result["summary"] || "",
      recommendation: result["recommendation"] || "",
      raw_text: text
    }
  rescue JSON::ParserError => e
    Rails.logger.error("ClaudePanelAnalyzer JSON parse error: #{e.message}")
    error_result("応答の JSON を解析できませんでした", raw_text: text)
  end

  # 失敗は severity を nil（判定なし）で返す。normal にはしない
  def error_result(message, raw_text: nil)
    { severity: nil, anomaly_count: 0, anomalies: [], summary: message, recommendation: "", error: message, raw_text: raw_text }
  end
end
