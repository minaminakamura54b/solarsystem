# レビューを完了した点検の総括文を Claude に書かせる（docs/IMPROVEMENT_PLAN.md Phase 6。AnomalyExplainer と同じ方式）。
# - 入力は保存済みの集計（件数・重大度・重要度・撮影条件・確定した架台の段・点検の範囲）だけ。Claude が書いた個々の所見は入力にしない
# - 解析できなかった範囲（写っていないパネル・除外した画像・配置図に無い所の画像・判断の材料が足りない段）があれば
#   「解析できなかった範囲: あり」と内訳を渡し、総括文で必ず触れさせる（v3。Phase 7 の決定事項 2026-11-09）
# - v4（見直し R3）: 総括文と発電所に対する対応は顧客向け（平易な言葉・入力の事実から言えることだけ）、撮影・解析の改善点は
#   社内向けの internal_improvements に分ける。入力は【顧客向けの事実】（平易な言葉）と【社内向けの技術的な情報】に分け、版名は入れない
# - 重要度・件数は人が確認した値をそのまま渡し、出力には含めない（スキーマに無く、返ってきても保存しない）
# - 書き込むのは総括文の列だけ。重要度・状態には触れない
class InspectionSummaryWriter
  PROMPT_VERSION = "inspection_summary_v4".freeze
  PROMPT_PATH = Rails.root.join("app/prompts/#{PROMPT_VERSION}.txt")
  MAX_LISTED = 50 # 入力に1件ずつ書く異常の上限（超えた分は件数だけ）

  SCHEMA = {
    type: "object",
    properties: {
      summary_text: { type: "string" },
      priority_actions: { type: "array", items: { type: "string" } },
      internal_improvements: { type: "array", items: { type: "string" } }
    },
    required: %w[summary_text priority_actions internal_improvements],
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
                              summary_additional_checks: nil, summary_internal_improvements: strings(result["internal_improvements"]).first(6),
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
            groups.map { |g| item_line(g.group_type, g.severity, g, "#{g.panel_count} 枚の並び", nil) } +
            rows.map { |r| row_line(r) }
    severities = anomalies.map(&:effective_severity) + groups.map(&:severity) + rows.map(&:severity)
    types = anomalies.map(&:effective_type) + groups.map(&:group_type) + [ "block_row" ] * rows.size
    provisional = RuleSet.where(version: anomalies.map(&:rule_version).compact.uniq).or(RuleSet.where(active: true)).any?(&:provisional?)

    [
      "【顧客向けの事実】",
      "点検日: #{inspection.conducted_at.to_date.iso8601}",
      *scope_lines(inspection),
      "画像: 解析に使った #{used.size} 枚 / 使わなかった #{images.size - used.size} 枚",
      irradiance_line(used),
      conditions_line(used),
      ("判定基準: 暫定の判定基準を使用" if provisional),
      "点検全体の結果（ルールで確定・人が確認済み。変更しない）: #{INSPECTION_SEVERITY_LABELS.fetch(inspection.severity.to_s, inspection.severity.to_s)}",
      "重大度の段階: #{AnomalyExplainer::SEVERITY_SCALE}（各異常の重大度はルールで確定・人が確認済み。変更しない）",
      "確定した異常: #{items.size} 件（隣り合う複数のパネルの発熱・架台の段全体の温度の高さは 1 件と数える）",
      ("重大度別: #{count_line(severities) { |sev| SEVERITY_LABELS.fetch(sev.to_s, sev.to_s) }}" if items.any?),
      ("種類別: #{count_line(types) { |t| ReportWording.anomaly_type(t) }}" if items.any?),
      ("異常の一覧:\n#{items.first(MAX_LISTED).map { |l| "- #{l}" }.join("\n")}" if items.any?),
      ("（ほか #{items.size - MAX_LISTED} 件は一覧を省略）" if items.size > MAX_LISTED),
      "確認中のまま残った候補: #{inspection.candidate_count} 件（結果に含めていない）",
      *coverage_lines(inspection, images),
      "",
      "【社内向けの技術的な情報】（顧客向けの文には使わない）",
      *technical_lines(inspection, images, used)
    ].compact.join("\n")
  end

  private

  def digest_for(input)
    Digest::SHA256.hexdigest("#{PROMPT_VERSION}\n#{input}")
  end

  def record_failure(inspection, digest, message)
    attrs = { summary_error: message, updated_at: @now }
    if digest && inspection.summary_input_digest != digest
      attrs.merge!(summary_text: nil, summary_priority_actions: nil, summary_additional_checks: nil, summary_internal_improvements: nil,
                   summary_prompt_version: nil, summary_input_digest: nil, summary_generated_at: nil)
    end
    inspection.update_columns(attrs)
  end

  def strings(value)
    Array(value).map(&:to_s).reject(&:blank?)
  end

  def item_line(type, severity, record, panel, evidence)
    parts = [ ReportWording.anomaly_type(type), "重大度 #{SEVERITY_LABELS.fetch(severity.to_s, '不明')}" ]
    parts << "周りとの温度差 #{record.delta_t.to_f.round(1)}℃" if record.delta_t
    parts << "パネル #{panel || '特定できず'}"
    parts << ReportWording.evidence(evidence) if evidence
    parts.join(" / ")
  end

  def row_line(row)
    [ ReportWording.anomaly_type("block_row"), "重大度 #{SEVERITY_LABELS.fetch(row.severity.to_s, '不明')}",
      "段全体の周りとの温度差 #{format('%+.1f', row.effect_c.to_f)}℃", "架台 #{row.label}（#{row.pv_block.cols} 枚）" ].join(" / ")
  end

  def scope_lines(inspection)
    scope = InspectionScope.new(inspection).description
    scope ? [ "点検した範囲: #{scope}" ] : []
  end

  # 点検の範囲（InspectionCoverage）と、解析できなかった範囲の有無・内訳（顧客向けの言葉）
  def coverage_lines(inspection, images)
    coverage = InspectionCoverage.new(inspection).summary
    excluded = images.select(&:excluded?)
    insufficient = inspection.block_row_findings.insufficient.to_a
    lines = []
    lines << if coverage.registered.positive?
      "解析できたパネル: 対象のパネル #{coverage.registered} 枚のうち #{coverage.covered} 枚（解析できなかったパネル #{coverage.uncovered} 枚）"
    else
      "解析できたパネル: 配置図が登録されていないため、パネルの枚数では数えていない"
    end
    if excluded.any?
      reasons = excluded.group_by { |img| ReportWording.unused_reason(unused_key(img)) }.map { |label, list| "#{label} #{list.size} 枚" }
      lines << "解析に使わなかった画像: #{excluded.size} 枚（#{reasons.join('、')}）"
    end
    lines << "配置図に登録されていない所が写った画像（点検の対象外）: #{coverage.outside_layout_images} 枚" if coverage.outside_layout_images.positive?
    if insufficient.any?
      reasons = insufficient.group_by { |r| ReportWording.insufficient_row_reason(r.insufficient_reason) }.map { |label, list| "#{label} #{list.size} 段" }
      lines << "段全体の温度を比べられなかった段: #{insufficient.size} 段（#{reasons.join('、')}。パネルごとの温度の比較は行っている）"
    end
    parts = []
    parts << "解析できなかったパネル #{coverage.uncovered} 枚" if coverage.uncovered.positive?
    parts << "解析に使わなかった画像 #{excluded.size} 枚" if excluded.any?
    parts << "配置図に登録されていない所が写った画像 #{coverage.outside_layout_images} 枚" if coverage.outside_layout_images.positive?
    parts << "段全体の温度を比べられなかった段 #{insufficient.size} 段" if insufficient.any?
    lines << (parts.any? ? "解析できなかった範囲: あり（#{parts.join('・')}）" : "解析できなかった範囲: なし")
  end

  # 社内向けの改善点を考えるための技術的な情報（顧客向けの文には使わない）
  def technical_lines(inspection, images, used)
    lines = []
    excluded = images.select(&:excluded?)
    lines << "使わなかった画像の技術的な理由: #{excluded.group_by { |img| BulkImageExclusion.reason_label(img) }.map { |l, list| "#{l} #{list.size} 枚" }.join('、')}" if excluded.any?
    quality = used.flat_map { |i| Array(i.quality_report.to_h["checks"]).select { |c| %w[warning rejected].include?(c["result"]) } }.group_by { |c| c["message"] }
    lines << "品質チェックの注意: #{quality.map { |m, list| "#{m}（#{list.size} 枚）" }.join('、')}" if quality.any?
    insufficient = inspection.block_row_findings.insufficient.to_a
    lines << "段全体を判断できなかった理由: #{insufficient.group_by(&:insufficient_reason).map { |r, list| "#{r} #{list.size} 段" }.join('、')}" if insufficient.any?
    lines << "点検の対象範囲: #{inspection.scope_confirmed? ? '確定済み' : '未確定（発電所全体として数えている）'}"
    lines << "日射量の記録: #{used.any? { |i| i.irradiance_w_m2 } ? 'あり' : 'なし'}・気象の記録: #{used.any? { |i| i.air_temp_c || i.wind_speed_m_s } ? 'あり' : 'なし'}"
    lines
  end

  def unused_key(img)
    img.review_reason == "alignment_failed" ? "alignment_failed:#{img.alignment.to_h['review_reason']}" : img.review_reason.to_s
  end

  def count_line(values)
    values.tally.map { |value, count| "#{yield(value)} #{count} 件" }.join("、")
  end

  def irradiance_line(images)
    values = images.filter_map { |i| i.irradiance_w_m2&.to_f }
    return "日射量: 記録なし（日射量での補正はしていない）" if values.empty?

    types = images.map { |i| { "poa" => "パネル面" }.fetch(i.irradiance_type.to_s, "パネル面以外（補正していない）") }.tally
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
