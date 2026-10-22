require "test_helper"

# 点検の測定パラメータ（放射率・反射温度・距離）の入力（2026-10-22。SDK への渡し方は Phase S で確定）
class MeasurementParamsTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
    @inspection = analyzable_inspection
    @image = @inspection.inspection_images.first
  end

  test "点検詳細に入力欄を出し、保存できる。解析済みの画像には再解析が要ることを表示する" do
    @image.update_columns(analysis_status: "completed", measurement_params: ThermalMeasurement.new(@image).record)
    get inspection_path(@inspection, site_id: @site.id)
    assert_select "#measurement input[name='inspection[emissivity]']"
    assert_no_match "解析した後に測定パラメータ", response.body

    patch measurement_inspection_path(@inspection, site_id: @site.id),
          params: { inspection: { emissivity: "0.9", reflected_temperature_c: "-3.5", object_distance_m: "30" } }

    assert_redirected_to inspection_path(@inspection, anchor: "measurement")
    assert_match "再解析してください", flash[:notice]
    assert_equal [ 0.9, -3.5, 30.0 ], @inspection.reload.values_at(:emissivity, :reflected_temperature_c, :object_distance_m).map(&:to_f)
    assert_equal "completed", @image.reload.analysis_status, "自動では解析し直さない"
    get inspection_path(@inspection, site_id: @site.id)
    assert_match "解析した後に測定パラメータ（または湿度）が変わっています", response.body
  end

  test "ありえない値は保存しない" do
    patch measurement_inspection_path(@inspection, site_id: @site.id), params: { inspection: { emissivity: "1.5" } }

    assert_equal "放射率は 0 より大きく 1 以下にしてください", flash[:alert]
    assert_nil @inspection.reload.emissivity
  end
end
