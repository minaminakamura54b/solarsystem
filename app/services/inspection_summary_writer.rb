# レビューを完了した点検の総括文を Claude に書かせる（docs/IMPROVEMENT_PLAN.md Phase 6。AnomalyExplainer と同じ方式）。
# - 入力は保存済みの集計（件数・重大度・重要度・撮影条件・確定した架台の段・点検の範囲）だけ。Claude が書いた個々の所見は入力にしない
# - 解析できなかった範囲（写っていないパネル・除外した画像・配置図に無い所の画像・判断の材料が足りない段）があれば
#   「解析できなかった範囲: あり」と内訳を渡し、総括文で必ず触れさせる（v3。Phase 7 の決定事項 2026-11-09）
# - 重要度・件数は人が確認した値をそのまま渡し、出力には含めない（スキーマに無く、返ってきても保存しない）
# - 書き込むのは総括文の列だけ。重要度・状態には触れない
class InspectionSummaryWriter
  PROMPT_VERSION = "inspection_summary_v3".freeze
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

    result = @output.request(system: PROMPT_PATH.read, input: input, schema: SCHEMA,
                             audit: { inspection: inspection, purpose: "inspection_summary", prompt_version: PROMPT_VERSION })
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
    rows = inspection.block_row_findings.candidates.where(review_status: "confirmed").includes(:pv_block).to_a
    items = anomalies.map { |a| item_line(a.effective_type, a.effective_severity, a, a.panel&.number, a.evidence_level) } +
            groups.map { |g| item_line(g.group_type, g.severity, g, "#{g.panel_count} 枚", nil) } +
            rows.map { |r| row_line(r) }
    severities = anomalies.map(&:effective_severity) + groups.map(&:severity) + rows.map(&:severity)
    types = anomalies.map(&:effective_type) + groups.map(&:group_type) + [ "block_row" ] * rows.size

    [
      "点検日: #{inspection.conducted_at.to_date.iso8601}",
      "画像: 判定に使った #{used.size} 枚 / 除外した #{images.size - used.size} 枚",
      irradiance_line(used),
      conditions_line(used),
      "モジュール: #{AnomalyExplainer::CELL_LAYOUTS[inspection.site.cell_layout] || 'セル構成不明'}・サブストリング #{inspection.site.substring_count}",
      "点検全体の重要度（ルールで確定・人が確認済み。変更しない）: #{INSPECTION_SEVERITY_LABELS.fetch(inspection.severity.to_s, inspection.severity.to_s)}",
      "重大度の段階: #{AnomalyExplainer::SEVERITY_SCALE}（各異常の重大度はルールで確定・人が確認済み。変更しない）",
      "確定した異常: #{items.size} 件（隣接パネル群・架台の段は 1 件と数える）",
      ("重大度別: #{count_line(severities) { |s| SEVERITY_LABELS.fetch(s.to_s, s.to_s) }}" if items.any?),
      ("種類別: #{count_line(types) { |t| RuleSetsHelper::ANOMALY_TYPE_LABELS.fetch(t, t) }}" if items.any?),
      ("異常の一覧:\n#{items.first(MAX_LISTED).map { |l| "- #{l}" }.join("\n")}" if items.any?),
      ("（ほか #{items.size - MAX_LISTED} 件は一覧を省略）" if items.size > MAX_LISTED),
      "未確定のまま残った候補: #{inspection.candidate_count} 件（重要度に含めていない）",
      *coverage_lines(inspection, images)
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

  def row_line(row)
    [ RuleSetsHelper::ANOMALY_TYPE_LABELS["block_row"], "重大度 #{SEVERITY_LABELS.fetch(row.severity.to_s, '不明')}",
      "段の効果 #{format('%+.1f', row.effect_c.to_f)}℃", "架台 #{row.label}（#{row.pv_block.cols} 枚）" ].join(" / ")
  end

  # 点検の範囲（InspectionCoverage）と、解析できなかった範囲の有無・内訳
  def coverage_lines(inspection, images)
    coverage = InspectionCoverage.new(inspection).summary
    excluded = images.select(&:excluded?)
    insufficient = inspection.block_row_findings.insufficient.count
    lines = []
    lines << if coverage.registered.positive?
      "点検の範囲: 登録したパネル #{coverage.registered} 枚のうち、解析できた画像に写ったパネル #{coverage.covered} 枚（写っていない #{coverage.uncovered} 枚）"
    else
      "点検の範囲: 配置図（架台とパネル）が登録されていないため、写ったパネルの数は出していない"
    end
    lines << "手動のグリッドで解析した画像（写ったパネルの数に含めていない）: #{coverage.layout_unlinked_images} 枚" if coverage.layout_unlinked_images.positive?
    if excluded.any?
      reasons = excluded.group_by { |img| BulkImageExclusion.reason_label(img) }.map { |label, list| "#{label} #{list.size} 枚" }
      lines << "除外した画像（判定に使っていない）: #{excluded.size} 枚（#{reasons.join('、')}）"
    end
    lines << "配置図に登録されていない所に写った画像（点検の対象外）: #{coverage.outside_layout_images} 枚" if coverage.outside_layout_images.positive?
    lines << "判断の材料が足りない架台の段（写った位置が偏っているなど）: #{insufficient} 段" if insufficient.positive?
    parts = []
    parts << "写っていないパネル #{coverage.uncovered} 枚" if coverage.uncovered.positive?
    parts << "除外した画像 #{excluded.size} 枚" if excluded.any?
    parts << "配置図に登録されていない所に写った画像 #{coverage.outside_layout_images} 枚" if coverage.outside_layout_images.positive?
    parts << "判断の材料が足りない架台の段 #{insufficient} 段" if insufficient.positive?
    lines << (parts.any? ? "解析できなかった範囲: あり（#{parts.join('・')}）" : "解析できなかった範囲: なし")
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
