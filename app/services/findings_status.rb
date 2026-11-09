# Claude の所見・総括文の作成の状態（修正案 13。2026-11-09 ユーザー承認）。
# レビュー完了の画面・点検の画面で「作れなかった」ことに気づけるようにする。判定・重大度には関係しない
# - disabled: Claude を使わない点検（人が書く）
# - config_missing: 「使う」だがモデル名か API キーが無い（外部には何も送らない）
# - not_requested: レビュー完了の後に「使う」にしたなど、まだ作るように頼んでいない（「所見を作る」で作る）
# - pending: 作成中（送信中の記録がある）か、作るように頼んだが結果がまだない
# - failed: 作れなかったもの（総括文・所見）がある
# - done: 総括文と、確定した異常・群の所見がすべて今のデータから作られている
class FindingsStatus
  Failure = Data.define(:label, :reason)

  attr_reader :state, :failures

  # 失敗の理由を、画面に出す日本語の分類にする（エラーの文に含まれる HTTP の状態や、設定の不足から）
  def self.reason_label(message)
    case message.to_s
    when /HTTP 401/ then "API キーが無効です（SOLARSIGHT_ANTHROPIC_API_KEY を確かめてください）"
    when /HTTP 403/ then "この API キーでは使えません（権限・組織の設定を確かめてください）"
    when /HTTP 429/ then "混み合っています（しばらくしてから作り直してください）"
    when /HTTP 5\d\d/, /overloaded/ then "Claude 側の障害です（しばらくしてから作り直してください）"
    when /接続できませんでした/ then "Claude API に接続できませんでした（ネットワークを確かめてください）"
    when /SOLARSIGHT_CLAUDE_MODEL/ then "モデル名（SOLARSIGHT_CLAUDE_MODEL）が設定されていません"
    when /SOLARSIGHT_ANTHROPIC_API_KEY/ then "API キー（SOLARSIGHT_ANTHROPIC_API_KEY）が設定されていません"
    when /拒否/ then "Claude が回答を拒否しました"
    when /途中で切れ/ then "応答が途中で切れました（config/claude.yml の max_tokens）"
    else message.to_s.truncate(120)
    end
  end

  def self.config_problems
    problems = []
    problems << "モデル名（SOLARSIGHT_CLAUDE_MODEL）が設定されていません" unless ClaudeStructuredOutput.model
    # テストで偽のクライアントに差し替えているときは、キーは要らない
    problems << "API キー（SOLARSIGHT_ANTHROPIC_API_KEY）が設定されていません" unless ClaudeStructuredOutput.api_key || ClaudeStructuredOutput.default_client
    problems
  end

  def initialize(inspection)
    @inspection = inspection
    @failures = []
    @state = compute
  end

  def label
    {
      disabled: "Claude を使わない点検です（所見・総括文は人が書きます）",
      config_missing: "Claude の設定が足りないため、所見・総括文は作られません",
      not_requested: "所見・総括文はまだ作っていません（「所見を作る」で作ります）",
      pending: "所見・総括文を作成中です（画面を再読み込みしてください）",
      failed: "所見・総括文のうち #{@failures.size} 件を作れませんでした",
      done: "所見・総括文はすべて作成済みです"
    }.fetch(@state)
  end

  def problem? = %i[config_missing not_requested failed].include?(@state)

  private

  def compute
    return :disabled unless @inspection.claude_enabled?
    return :config_missing if self.class.config_problems.any?

    explainer = AnomalyExplainer.new(output: nil)
    targets.each do |record, label|
      next if explainer.current?(record)

      @failures << Failure.new(label:, reason: self.class.reason_label(record.explanation_error)) if record.explanation_error.present?
    end
    if @inspection.summary_error.present? && !InspectionSummaryWriter.new(output: nil).current?(@inspection)
      @failures << Failure.new(label: "点検の総括文", reason: self.class.reason_label(@inspection.summary_error))
    end
    return :failed if @failures.any?
    return :done if summary_current? && targets.all? { |record, _| explainer.current?(record) }
    return :pending if requested?

    :not_requested
  end

  def summary_current? = InspectionSummaryWriter.new(output: nil).current?(@inspection)

  # 作るように頼んだか: 完了したときに「使う」だった（切り替えが完了より前）か、送信の記録がある
  def requested?
    changed = @inspection.claude_enabled_changed_at
    (changed && @inspection.reviewed_at && changed <= @inspection.reviewed_at) ||
      @inspection.external_transmissions.where(sent_at: (@inspection.reviewed_at || Time.at(0))..).exists?
  end

  def targets
    @targets ||= @inspection.anomalies.where(review_status: InspectionReview::CONFIRMED).countable.includes(:panel, :inspection_image, inspection: :site).map { |a| [ a, "画像 #{a.inspection_image.sequence} の#{RuleSetsHelper::ANOMALY_TYPE_LABELS.fetch(a.effective_type, a.effective_type)}の所見" ] } +
                 @inspection.anomaly_groups.where(review_status: InspectionReview::CONFIRMED).includes(:inspection_image, inspection: :site, anomalies: :panel).map { |g| [ g, "画像 #{g.inspection_image.sequence} の隣接パネル群の所見" ] }
  end
end
