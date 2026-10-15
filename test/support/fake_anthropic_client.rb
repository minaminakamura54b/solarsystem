# Anthropic API を呼ばずに、決まった応答（またはエラー）を返す偽クライアント。
# 公式 Ruby SDK の `client.messages.create(**params)` と同じ形で呼ばれ、SDK の Anthropic::Message を返す。
# 応答の文字列は、ブロック（リクエストの params を受け取る）か、replying に渡した文字列で決める
class FakeAnthropicClient
  attr_reader :requests

  def self.replying(text, stop_reason: :end_turn)
    new(stop_reason: stop_reason) { text }
  end

  def self.raising(error)
    new(error: error)
  end

  def initialize(error: nil, stop_reason: :end_turn, &responder)
    @error = error
    @stop_reason = stop_reason
    @responder = responder
    @requests = []
  end

  def messages
    self
  end

  def create(**params)
    @requests << params
    raise @error if @error

    Anthropic::Message.new(
      id: "msg_test", type: :message, role: :assistant, model: params[:model].to_s,
      content: [ { type: :thinking, thinking: "テスト", signature: "sig" }, { type: :text, text: @responder.call(params) } ],
      stop_reason: @stop_reason, stop_sequence: nil, stop_details: nil, container: nil, diagnostics: nil,
      usage: { input_tokens: 1, output_tokens: 1 }
    )
  end
end
