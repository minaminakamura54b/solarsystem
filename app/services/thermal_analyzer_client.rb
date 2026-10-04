require "open3"

# 解析エンジン（python -m analyzer）を別プロセスで実行し、出力 JSON を返す（docs/IMPROVEMENT_PLAN.md Phase 4-3）。
# Open3.capture3 にはタイムアウト機能が無いため popen3 で起動し、上限を超えたらプロセスグループごと終了させる。
# 一時ファイル（ルールセット・出力 JSON）は一時ディレクトリごと削除する
class ThermalAnalyzerClient
  VALID_STATUSES = {
    "analyze" => %w[completed needs_review failed],
    "propose-grid" => %w[proposed needs_review failed]
  }.freeze

  Result = Data.define(:exit_code, :output, :stderr, :error) do
    def ok? = error.nil? && exit_code.zero?
    def timed_out? = error == "timeout"
    def status = output&.dig("status")
    def review_reason = output&.dig("review_reason")
    def message = output&.dig("message").presence || error_message
    def error_message
      { "timeout" => "解析エンジンが時間内に終わりませんでした", "invalid_output" => "解析エンジンの出力を読めませんでした" }
        .fetch(error.to_s, stderr.to_s.strip.presence)
    end
  end

  def initialize(config: AnalyzerConfig.current)
    @config = config
  end

  def analyze(thermal_path:, panel_grids:, module_spec:, rules:, irradiance: nil, irradiance_type: nil)
    Dir.mktmpdir("analyzer") do |dir|
      rules_path = File.join(dir, "rules.json")
      File.write(rules_path, rules.to_json)
      args = [ "analyze", "--thermal", thermal_path.to_s, "--panel-grids", panel_grids.to_json,
               "--module", module_spec.to_json, "--rules", rules_path ]
      args += [ "--irradiance", irradiance.to_s, "--irradiance-type", irradiance_type.to_s ] if irradiance && irradiance_type
      run("analyze", args, dir)
    end
  end

  def propose_grid(thermal_path:)
    Dir.mktmpdir("analyzer") { |dir| run("propose-grid", [ "propose-grid", "--thermal", thermal_path.to_s ], dir) }
  end

  private

  def run(subcommand, args, dir)
    out_path = File.join(dir, "out.json")
    command = @config.command + args + [ "--out", out_path ]
    stdout_text = stderr_text = nil
    exit_code = nil
    timed_out = false

    Open3.popen3(*command, chdir: @config.working_dir, pgroup: true) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }
      if wait_thr.join(@config.timeout_seconds)
        exit_code = wait_thr.value.exitstatus
      else
        timed_out = true
        terminate_group(wait_thr)
      end
      stdout_text = out_reader.value
      stderr_text = err_reader.value
    end

    return Result.new(exit_code: nil, output: nil, stderr: stderr_text, error: "timeout") if timed_out

    output = parse_output(out_path, subcommand)
    error = output.nil? ? "invalid_output" : nil
    Result.new(exit_code: exit_code, output: output, stderr: stderr_text.presence || stdout_text, error: error)
  rescue Errno::ENOENT => e
    Result.new(exit_code: nil, output: nil, stderr: e.message, error: "command_not_found")
  end

  # プロセスグループ（解析エンジンと、その子プロセス）を終了させる。TERM で終わらなければ KILL
  def terminate_group(wait_thr)
    pgid = wait_thr.pid
    signal_group("TERM", pgid)
    return if wait_thr.join(3)

    signal_group("KILL", pgid)
    wait_thr.join(3)
  end

  def signal_group(signal, pgid)
    Process.kill(signal, -pgid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  # 出力 JSON を読み、約束（schema_version・status・必須項目）に沿っているかを確かめる。沿っていなければ nil
  def parse_output(path, subcommand)
    return nil unless File.exist?(path)

    data = JSON.parse(File.read(path))
    return nil unless data.is_a?(Hash)
    return nil unless data["schema_version"] == @config.schema_version
    return nil unless VALID_STATUSES.fetch(subcommand).include?(data["status"])
    return nil if subcommand == "analyze" && !valid_analysis?(data)

    data
  rescue JSON::ParserError
    nil
  end

  ANOMALY_KEYS = %w[panel_index anomaly_type detection measure delta_t threshold_basis bbox area_ratio].freeze
  GROUP_KEYS = %w[type panel_indices measure delta_t threshold_basis].freeze

  def valid_analysis?(data)
    anomalies = Array(data["anomalies"])
    groups = Array(data["groups"])
    anomalies.all? { |a| a.is_a?(Hash) && (ANOMALY_KEYS - a.keys).empty? } &&
      groups.all? { |g| g.is_a?(Hash) && (GROUP_KEYS - g.keys).empty? }
  end
end
