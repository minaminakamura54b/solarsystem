require "test_helper"

# 解析エンジンの呼び出し。ここでは解析エンジンの代わりに sh のスクリプトを動かし、
# タイムアウト・終了コード・出力の検証・一時ファイルの削除を確かめる
class ThermalAnalyzerClientTest < ActiveSupport::TestCase
  def config(script, timeout: 5)
    AnalyzerConfig.new(
      command: [ "sh", "-c", script, "analyzer" ], working_dir: ".", timeout_seconds: timeout,
      schema_version: "2.1", stale_after_minutes: 10, template_match: { altitude_m: 2 }
    )
  end

  # "$@" の最後の2つが --out <path>
  WRITE_OUTPUT = 'eval out=\${$#}; printf %s "$OUTPUT" > "$out"; exit ${CODE:-0}'

  def client_writing(output, code: 0)
    ENV["OUTPUT"] = output.is_a?(String) ? output : output.to_json
    ENV["CODE"] = code.to_s
    ThermalAnalyzerClient.new(config: config(WRITE_OUTPUT))
  end

  teardown do
    ENV.delete("OUTPUT")
    ENV.delete("CODE")
  end

  def analyze(client)
    client.analyze(thermal_path: "x.npy", panel_grids: [ SAMPLE_GRID ], module_spec: {}, rules: { "version" => "v" },
                   irradiance: 800, irradiance_type: "poa")
  end

  test "出力 JSON を読んで返す" do
    result = analyze(client_writing(analyzer_output))

    assert result.ok?
    assert_equal "completed", result.status
    assert_equal "hotspot", result.output["anomalies"].first["anomaly_type"]
  end

  test "終了コードと要確認の理由を返す" do
    result = analyze(client_writing(analyzer_output(status: "needs_review", review_reason: "insufficient_baseline", anomalies: []), code: 4))

    assert_not result.ok?
    assert_equal 4, result.exit_code
    assert_equal "insufficient_baseline", result.review_reason
  end

  test "schema_version が違えば invalid_output" do
    result = analyze(client_writing(analyzer_output.merge("schema_version" => "1.0")))

    assert_equal "invalid_output", result.error
  end

  test "必須項目の欠けた異常があれば invalid_output" do
    result = analyze(client_writing(analyzer_output(anomalies: [ { "panel_index" => 1 } ])))

    assert_equal "invalid_output", result.error
  end

  test "JSON でなければ invalid_output" do
    assert_equal "invalid_output", analyze(client_writing("not json")).error
  end

  test "時間切れならプロセスグループごと終了させ、子プロセスも残さない" do
    pid_file = Rails.root.join("tmp", "analyzer_child_#{Process.pid}.pid")
    script = "sleep 30 & echo $! > #{pid_file}; wait"
    client = ThermalAnalyzerClient.new(config: config(script, timeout: 1))

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = analyze(client)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert result.timed_out?
    assert_equal "解析エンジンが時間内に終わりませんでした", result.message
    assert elapsed < 10, "タイムアウト後すぐに戻る"
    child = File.read(pid_file).to_i
    assert_raises(Errno::ESRCH) { Process.kill(0, child) }
  ensure
    File.delete(pid_file) if pid_file && File.exist?(pid_file)
  end

  test "一時ファイル（ルールセット・出力 JSON）は終了後に消える" do
    script = 'eval out=\${$#}; dirname "$out" > ' + Rails.root.join("tmp", "analyzer_dir_#{Process.pid}.txt").to_s + '; printf %s "$OUTPUT" > "$out"'
    ENV["OUTPUT"] = analyzer_output.to_json
    analyze(ThermalAnalyzerClient.new(config: config(script)))

    dir = File.read(Rails.root.join("tmp", "analyzer_dir_#{Process.pid}.txt")).strip
    assert_not Dir.exist?(dir)
  ensure
    FileUtils.rm_f(Rails.root.join("tmp", "analyzer_dir_#{Process.pid}.txt"))
  end

  test "コマンドが無ければ command_not_found" do
    client = ThermalAnalyzerClient.new(config: AnalyzerConfig.new(
      command: [ "no-such-analyzer-command" ], working_dir: ".", timeout_seconds: 5,
      schema_version: "2.1", stale_after_minutes: 10, template_match: {}
    ))

    assert_equal "command_not_found", analyze(client).error
  end
end
