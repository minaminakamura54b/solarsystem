# Phase 4（解析エンジンとの接続）のテスト用ヘルパー
module AnalyzerTestHelper
  # 解析エンジンを呼ばずに、決まった結果を返す偽のクライアント
  class FakeAnalyzerClient
    attr_reader :calls

    def initialize(analyze: nil, propose: nil)
      @analyze_result = analyze
      @propose_result = propose
      @calls = []
    end

    def analyze(**kwargs)
      @calls << [ :analyze, kwargs ]
      @analyze_result
    end

    def propose_grid(**kwargs)
      @calls << [ :propose_grid, kwargs ]
      @propose_result
    end
  end

  def with_fake_analyzer(analyze: nil, propose: nil)
    previous = AnalyzeInspectionImageJob.instance_variable_get(:@client)
    client = FakeAnalyzerClient.new(analyze: analyze, propose: propose)
    AnalyzeInspectionImageJob.client = client
    yield client
  ensure
    AnalyzeInspectionImageJob.client = previous
  end

  def analyzer_result(exit_code: 0, output: nil, error: nil, stderr: "")
    ThermalAnalyzerClient::Result.new(exit_code: exit_code, output: output, stderr: stderr, error: error)
  end

  # 解析エンジンの出力（schema_version 2.1）。anomalies / groups は上書きできる
  def analyzer_output(status: "completed", review_reason: nil, anomalies: nil, groups: [], message: nil)
    {
      "schema_version" => "2.1", "analyzer_version" => "thermal_rules_v1", "status" => status,
      "review_reason" => review_reason, "message" => message, "rule_version" => "2026-09-initial",
      "image" => { "width" => 640, "height" => 512, "is_radiometric" => true, "source" => "npy" },
      "baseline" => { "temp" => 40.0, "panel_count" => 24, "required_count" => 12 },
      "panels" => [],
      "anomalies" => anomalies || [ analyzer_anomaly ],
      "groups" => groups
    }
  end

  def analyzer_anomaly(**overrides)
    {
      "panel_index" => 7, "anomaly_type" => "hotspot", "detection" => "local", "active_bands" => nil,
      "bbox" => { "x1" => 0.3, "y1" => 0.4, "x2" => 0.32, "y2" => 0.43 },
      "measure" => "region_max", "delta_t" => 16.0, "normalized_delta_t" => 20.0, "threshold_basis" => "normalized",
      "area_ratio" => 0.017, "t_max" => 56.0, "t_mean" => 55.0, "t_min" => 54.0, "baseline_temp" => 40.0,
      "shape" => { "regions" => 1 }, "flags" => []
    }.merge(overrides.stringify_keys)
  end

  SAMPLE_GRID = { "rows" => 4, "cols" => 6, "corners" => [ [ 0.15, 0.2 ], [ 0.72, 0.2 ], [ 0.72, 0.48 ], [ 0.15, 0.48 ] ], "panel_orientation" => "landscape" }.freeze

  # 品質チェックに合格した画像（グリッド付き）を持つ点検
  def analyzable_inspection(grids: [ SAMPLE_GRID ], files: [ "thermal_plain_T.jpg" ])
    inspection = create_session_inspection(files: files)
    inspection.inspection_images.each do |image|
      image.update_columns(quality_report: { "status" => "ok", "checks" => [] }, panel_grids: grids,
                           irradiance_w_m2: 800, irradiance_type: "poa")
    end
    inspection
  end
end
