# Anthropic API を呼ばずに、決まった応答（またはエラー）を返す偽クライアント。
# 非公式 anthropic gem 0.4.1 の `client.messages(parameters: {...})` と同じ形で呼ばれる。
class FakeAnthropicClient
  attr_reader :requests

  def self.replying(text)
    new(text: text)
  end

  def self.raising(error)
    new(error: error)
  end

  def initialize(text: nil, error: nil)
    @text = text
    @error = error
    @requests = []
  end

  def messages(parameters:)
    @requests << parameters
    raise @error if @error

    { "content" => [ { "type" => "text", "text" => @text } ] }
  end
end
