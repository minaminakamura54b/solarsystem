require "test_helper"

# Claude への送信は「使う」にした点検だけ。送る前に記録し、結果で更新する（2026-11-09 ユーザー指示）
class ClaudeStructuredOutputTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection
    @schema = { type: "object", properties: { a: { type: "string" } }, required: %w[a], additionalProperties: false }
  end

  def request(client)
    with_fake_claude(client) do
      ClaudeStructuredOutput.new.request(system: "s", input: "入力 1", schema: @schema,
                                         audit: { inspection: @inspection, purpose: "inspection_summary", prompt_version: "v1" })
    end
  end

  test "使わない点検（既定）は送らず、記録も作らない" do
    client = FakeAnthropicClient.replying('{"a":"x"}')

    error = assert_raises(ClaudeStructuredOutput::Error) { request(client) }

    assert_match "Claude を使わない設定", error.message
    assert_empty client.requests
    assert_equal 0, @inspection.external_transmissions.count
  end

  test "使う点検は、送った入力・目的・モデル・日時を記録する" do
    @inspection.update_columns(claude_enabled: true)

    assert_equal({ "a" => "x" }, request(FakeAnthropicClient.replying('{"a":"x"}')))

    log = @inspection.external_transmissions.sole
    assert_equal [ "anthropic", "inspection_summary", "test-model", "v1", "入力 1", "sent" ],
                 log.values_at(:service, :purpose, :model, :prompt_version, :input_text, :status)
    assert_equal "入力 1".bytesize, log.input_bytes
    assert_equal [ 1, 1 ], [ log.input_tokens, log.output_tokens ], "応答のトークン数（費用の計算に使う）"
    assert log.sent_at
  end

  test "送ったあとに失敗したら、記録を失敗にしてエラーを残す。記録は消せない" do
    @inspection.update_columns(claude_enabled: true)

    assert_raises(ClaudeStructuredOutput::Error) { request(FakeAnthropicClient.replying("JSON ではない")) }

    log = @inspection.external_transmissions.sole
    assert_equal "failed", log.status
    assert_match "JSON", log.error
    assert_equal 1, log.output_tokens, "使えない応答でも課金されるのでトークン数を残す"
    assert_not log.destroy
    assert_not @inspection.destroy, "送った記録のある点検は削除しない"
  end

  test "キーはアプリ専用の SOLARSIGHT_ANTHROPIC_API_KEY だけを使い、送った記録にキーの指紋を残す（キーそのものは残さない）" do
    @inspection.update_columns(claude_enabled: true)
    previous = ENV.to_h.slice("SOLARSIGHT_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY")
    ENV["SOLARSIGHT_ANTHROPIC_API_KEY"] = "test-key-for-fingerprint"
    request(FakeAnthropicClient.replying('{"a":"x"}'))
    log = @inspection.external_transmissions.sole
    assert_equal Digest::SHA256.hexdigest("test-key-for-fingerprint")[0, 8], log.key_fingerprint
    assert_not_includes log.attributes.values.map(&:to_s).join, "test-key-for-fingerprint"

    # 本物のクライアントを作るときも、シェルの ANTHROPIC_API_KEY には切り替えない
    ENV.delete("SOLARSIGHT_ANTHROPIC_API_KEY")
    ENV["ANTHROPIC_API_KEY"] = "shell-key"
    error = with_fake_claude(nil) do
      assert_raises(ClaudeStructuredOutput::Error) do
        ClaudeStructuredOutput.new.request(system: "s", input: "x", schema: @schema, audit: { inspection: @inspection, purpose: "inspection_summary" })
      end
    end
    assert_match "SOLARSIGHT_ANTHROPIC_API_KEY", error.message
  ensure
    %w[SOLARSIGHT_ANTHROPIC_API_KEY ANTHROPIC_API_KEY].each { |k| previous&.key?(k) ? ENV[k] = previous[k] : ENV.delete(k) }
  end
end
