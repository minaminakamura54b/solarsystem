# レビューを完了した点検の総括文を Claude に書かせる（docs/IMPROVEMENT_PLAN.md Phase 6。AnomalyExplainer と同じ方式）。
# - 入力は保存済みの集計（件数・重大度・重要度・撮影条件など）だけ。Claude が書いた個々の所見は入力にしない
# - 重要度・件数は人が確認した値をそのまま渡し、出力には含めない（スキーマに無く、返ってきても保存しない）
# - 書き込むのは総括文の列だけ。重要度・状態には触れない
class InspectionSummaryWriter
  PROMPT_VERSION = "inspection_summary_v2".freeze
  PROMPT_PATH = Rails.root.join("app/prompts/#{PROMPT_VERSION}.txt")
  MAX_LISTED = 50 # 入力に1件ずつ書く異常の上限（超えた分は件数だけ）

  SCHEMA = {
    type: "object",
    properties: {
      summary_text: { type: "string" },
      priority_actions: { type: "array", items: { type: "string" } },
      additional_checks: { type: "array", items: { type: "string" } }
    },
    required: %w[summary_text priority_actions additional_checks],
    additionalProperties: false
  }.freeze

  SEVERITY_LABELS = { "mild" => "軽微", "warning" => "注意", "critical" => "重大" }.freeze
  INSPECTION_SEVERITY_LABELS = { "normal" => "正常（確定した異常なし）" }.merge(SEVERITY_LABELS).freeze

  def initialize(output: ClaudeStructuredOutput.new, now: Time.current)
    @output = output
    @now = now
  end

  # 戻り値: :explained / :skipped / :failed
  def write(inspection, force: false)
    raise ArgumentError, "レビューを完了していない点検の総括文は作りません" unless inspection.completed? && inspection.reviewed_at.present?

    input = input_text(inspection)
    digest = digest_for(input)
    return :skipped if !force && inspection.summary_input_digest == digest && inspection.summary_generated_at.present? && inspection.summary_error.blank?

    result = @output.request(system: PROMPT_PATH.read, input: input, schema: SCHEMA)
    summary_text = result["summary_text"].to_s
    raise ClaudeStructuredOutput::Error, "Claude の応答に総括文（summary_text）がありません" if summary_text.blank?

    inspection.update_columns(summary_text: summary_text,
                              summary_priority_actions: strings(result["priority_actions"]).first(5),
                              summary_additional_checks: strings(result["additional_checks"]),
                              summary_prompt_version: PROMPT_VERSION, summary_input_digest: digest,
                              summary_generated_at: @now, summary_error: nil, updated_at: @now)
    :explained
  rescue ClaudeStructuredOutput::Error => e
    record_failure(inspection, digest, e.message)
    :failed
  end

  def current?(inspection)
    inspection.summary_generated_at.present? && inspection.summary_input_digest == digest_for(input_text(inspection))
  end

  def input_text(inspection)
    images = inspection.inspection_images.to_a
    used = images.reject(&:excluded?)
    anomalies = inspection.anomalies.where(review_status: InspectionReview::CONFIRMED).countable
                          .includes(:panel).order(:inspection_image_id, :id).to_a
    groups = inspection.anomaly_groups.where(review_status: InspectionReview::CONFIRMED).order(:inspection_image_id, :id).to_a
    items = anomalies.map { |a| item_line(a.effective_type, a.effective_severity, a, a.panel&.number, a.evidence_level) } +
            groups.map { |g| item_line(g.group_type, g.severity, g, "#{g.panel_count} 枚", nil) }
    severities = anomalies.map(&:effective_severity) + groups.map(&:severity)
    types = anomalies.map(&:effective_type) + groups.map(&:group_type)

    [
      "点検日: #{inspection.conducted_at.to_date.iso8601}",
      "画像: 判定に使った #{used.size} 枚 / 除外した #{images.size - used.size} 枚",
      irradiance_line(used),
      conditions_line(used),
      "モジュール: #{AnomalyExplainer::CELL_LAYOUTS[inspection.site.cell_layout] || 'セル構成不明'}・サブストリング #{inspection.site.substring_count}",
      "点検全体の重要度（ルールで確定・人が確認済み。変更しない）: #{INSPECTION_SEVERITY_LABELS.fetch(inspection.severity.to_s, inspection.severity.to_s)}",
      "重大度の段階: #{AnomalyExplainer::SEVERITY_SCALE}（各異常の重大度はルールで確定・人が確認済み。変更しない）",
      "確定した異常: #{items.size} 件（隣接パネル群は 1 件と数える）",
      ("重大度別: #{count_line(severities) { |s| SEVERITY_LABELS.fetch(s.to_s, s.to_s) }}" if items.any?),
      ("種類別: #{count_line(types) { |t| RuleSetsHelper::ANOMALY_TYPE_LABELS.fetch(t, t) }}" if items.any?),
      ("異常の一覧:\n#{items.first(MAX_LISTED).map { |l| "- #{l}" }.join("\n")}" if items.any?),
      ("（ほか #{items.size - MAX_LISTED} 件は一覧を省略）" if items.size > MAX_LISTED),
      "未確定のまま残った候補: #{inspection.candidate_count} 件（重要度に含めていない）"
    ].compact.join("\n")
  end

  private

  def digest_for(input)
    Digest::SHA256.hexdigest("#{PROMPT_VERSION}\n#{input}")
  end

  def record_failure(inspection, digest, message)
    attrs = { summary_error: message, updated_at: @now }
    if digest && inspection.summary_input_digest != digest
      attrs.merge!(summary_text: nil, summary_priority_actions: nil, summary_additional_checks: nil,
                   summary_prompt_version: nil, summary_input_digest: nil, summary_generated_at: nil)
    end
    inspection.update_columns(attrs)
  end

  def strings(value)
    Array(value).map(&:to_s).reject(&:blank?)
  end

  def item_line(type, severity, record, panel, evidence)
    parts = [ RuleSetsHelper::ANOMALY_TYPE_LABELS.fetch(type, type), "重大度 #{SEVERITY_LABELS.fetch(severity.to_s, '不明')}" ]
    parts << "ΔT #{record.delta_t.to_f.round(1)}℃" if record.delta_t
    parts << "パネル #{panel || '未割り当て'}"
    parts << "証拠レベル #{evidence}" if evidence
    parts.join(" / ")
  end

  def count_line(values)
    values.tally.map { |value, count| "#{yield(value)} #{count} 件" }.join("、")
  end

  def irradiance_line(images)
    values = images.filter_map { |i| i.irradiance_w_m2&.to_f }
    return "日射量: 不明（未正規化）" if values.empty?

    types = images.map { |i| { "poa" => "POA" }.fetch(i.irradiance_type.to_s, "POA 以外（未正規化）") }.tally
    "日射量: #{values.min.round}〜#{values.max.round} W/m²（#{types.map { |t, n| "#{t} #{n} 枚" }.join('、')}）"
  end

  def conditions_line(images)
    temps = images.filter_map { |i| i.air_temp_c&.to_f }
    winds = images.filter_map { |i| i.wind_speed_m_s&.to_f }
    parts = []
    parts << "気温 #{temps.min.round(1)}〜#{temps.max.round(1)}℃" if temps.any?
    parts << "風速 #{winds.min.round(1)}〜#{winds.max.round(1)} m/s" if winds.any?
    "撮影時の気象: #{parts.join('、').presence || '不明'}"
  end
end
