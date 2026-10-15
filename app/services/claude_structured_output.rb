# 公式 Anthropic Ruby SDK で、決まった JSON スキーマの応答を1回もらう（structured outputs。docs/IMPROVEMENT_PLAN.md Phase 6）。
# - モデル名は環境変数 CLAUDE_MODEL。未設定ならリクエストせず Error にする（コードにモデル名を書かない）
# - 送るのは文字だけ（画像は送らない。2026-10-15 ユーザー承認）
# - API エラー・拒否・途中で切れた応答・JSON でない応答は、すべて Error にする（呼び出し側で失敗として記録する）
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
    ENV["CLAUDE_MODEL"].presence
  end

  # system: プロンプト本文、input: 入力の文章、schema: 出力の JSON スキーマ。戻り値は文字列キーの Hash
  def request(system:, input:, schema:)
    model = self.class.model
    raise Error, "環境変数 CLAUDE_MODEL が設定されていません" unless model
    raise Error, "環境変数 ANTHROPIC_API_KEY が設定されていません" if @client.nil? && ENV["ANTHROPIC_API_KEY"].blank?

    message = client.messages.create(
      model: model,
      max_tokens: @config.fetch(:max_tokens),
      system_: system,
      messages: [ { role: "user", content: input } ],
      output_config: { format_: { type: :json_schema, schema: schema } }
    )
    parse(message)
  rescue Anthropic::Errors::APIConnectionError => e
    raise Error, "Claude API に接続できませんでした（#{e.class.name.demodulize}）"
  rescue Anthropic::Errors::APIStatusError => e
    raise Error, "Claude API がエラーを返しました（HTTP #{e.status}#{" #{e.type}" if e.type}）"
  rescue Anthropic::Errors::Error => e
    raise Error, "Claude API の呼び出しに失敗しました（#{e.class.name.demodulize}）"
  end

  private

  def client
    @client ||= Anthropic::Client.new(timeout: @config.fetch(:timeout_seconds).to_f, max_retries: @config.fetch(:max_retries).to_i)
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
