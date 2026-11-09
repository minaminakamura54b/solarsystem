# 公式 Anthropic Ruby SDK で、決まった JSON スキーマの応答を1回もらう（structured outputs。docs/IMPROVEMENT_PLAN.md Phase 6）。
# - モデル名は環境変数 SOLARSIGHT_CLAUDE_MODEL、API キーは SOLARSIGHT_ANTHROPIC_API_KEY（アプリ専用の名前。シェルの ANTHROPIC_API_KEY は使わない）。
#   未設定ならリクエストせず Error にする（コードにモデル名を書かない）。送った記録にキーの指紋（SHA-256 の先頭 8 文字）を残す
# - 送るのは文字だけ（画像は送らない。2026-10-15 ユーザー承認）
# - API エラー・拒否・途中で切れた応答・JSON でない応答は、すべて Error にする（呼び出し側で失敗として記録する）
# - Claude を「使う」にした点検（inspections.claude_enabled）のものだけ送る。既定は使わない（2026-11-09 ユーザー指示）
# - 送る前に、いつ・何を送るか（目的・対象・入力）を点検ごとに記録し（ExternalTransmission）、結果で更新する
class ClaudeStructuredOutput
  class Error < StandardError; end

  class << self
    # テストで偽クライアントに差し替えるためのフック。本番では常に nil のまま使う
    attr_accessor :default_client
  end

  def initialize(client: nil, config: Rails.application.config_for(:claude))
    @client = client || self.class.default_client
    @config = config.to_h.with_indifferent_access
  end

  def self.model
    ENV["SOLARSIGHT_CLAUDE_MODEL"].presence
  end

  def self.api_key
    ENV["SOLARSIGHT_ANTHROPIC_API_KEY"].presence
  end

  # キーの指紋（キーそのものは表示・保存しない）。キーが無ければ nil
  def self.key_fingerprint
    api_key && Digest::SHA256.hexdigest(api_key)[0, 8]
  end

  # system: プロンプト本文、input: 入力の文章、schema: 出力の JSON スキーマ。戻り値は文字列キーの Hash
  # audit: { inspection:, purpose:, target:, prompt_version: }（送った記録に残す。点検が「使わない」なら送らない）
  def request(system:, input:, schema:, audit:)
    inspection = audit.fetch(:inspection)
    raise Error, "この点検は Claude を使わない設定です（点検の画面で「使う」にしたときだけ送ります）" unless inspection.claude_enabled?

    model = self.class.model
    raise Error, "環境変数 SOLARSIGHT_CLAUDE_MODEL が設定されていません" unless model
    raise Error, "環境変数 SOLARSIGHT_ANTHROPIC_API_KEY が設定されていません" if @client.nil? && self.class.api_key.nil?

    log = ExternalTransmission.create!(inspection:, service: "anthropic", purpose: audit.fetch(:purpose), target: audit[:target],
                                       model:, prompt_version: audit[:prompt_version], input_text: input, input_bytes: input.bytesize,
                                       key_fingerprint: self.class.key_fingerprint,
                                       status: "sending", sent_at: Time.current)
    @last_usage = nil
    begin
      result = call_api(model:, system:, input:, schema:)
    rescue Error => e
      log.update!(status: "failed", error: e.message, **usage_columns)
      raise
    end
    log.update!(status: "sent", **usage_columns)
    result
  end

  private

  def call_api(model:, system:, input:, schema:)
    message = client.messages.create(
      model: model,
      max_tokens: @config.fetch(:max_tokens),
      system_: system,
      messages: [ { role: "user", content: input } ],
      output_config: { format_: { type: :json_schema, schema: schema } }
    )
    @last_usage = message.usage # 応答があれば、使えない応答（拒否・JSON でない）でも課金されるので記録する
    parse(message)
  rescue Anthropic::Errors::APIConnectionError => e
    raise Error, "Claude API に接続できませんでした（#{e.class.name.demodulize}）"
  rescue Anthropic::Errors::APIStatusError => e
    raise Error, "Claude API がエラーを返しました（HTTP #{e.status}#{" #{e.type}" if e.type}）"
  rescue Anthropic::Errors::Error => e
    raise Error, "Claude API の呼び出しに失敗しました（#{e.class.name.demodulize}）"
  end

  # 応答のトークン数（思考のトークンは output_tokens に含まれる）
  def usage_columns
    return {} unless @last_usage

    { input_tokens: @last_usage.input_tokens, output_tokens: @last_usage.output_tokens,
      cache_creation_input_tokens: @last_usage.cache_creation_input_tokens, cache_read_input_tokens: @last_usage.cache_read_input_tokens }
  end

  def client
    # キーと送り先を明示して渡す（SDK が環境変数 ANTHROPIC_* を暗黙に読まないようにする）
    @client ||= Anthropic::Client.new(api_key: self.class.api_key, base_url: @config.fetch(:base_url),
                                      timeout: @config.fetch(:timeout_seconds).to_f, max_retries: @config.fetch(:max_retries).to_i)
  end

  def parse(message)
    case message.stop_reason&.to_sym
    when :refusal then raise Error, "Claude が回答を拒否しました"
    when :max_tokens then raise Error, "Claude の応答が上限トークン数で途中で切れました（config/claude.yml の max_tokens）"
    end

    text = message.content.select { |block| block.type.to_sym == :text }.map(&:text).join
    raise Error, "Claude の応答に文章がありません" if text.blank?

    data = JSON.parse(text)
    raise Error, "Claude の応答が JSON のオブジェクトではありません" unless data.is_a?(Hash)

    data
  rescue JSON::ParserError
    raise Error, "Claude の応答を JSON として読めませんでした"
  end
end
