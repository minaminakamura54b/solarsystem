require "test_helper"

# 新方式の点検（複数画像のセッション）の登録・表示・操作
class InspectionSessionsTest < ActionDispatch::IntegrationTest
  setup do
    @site = sites(:south)
  end

  def upload(name, type = "image/jpeg")
    fixture_file_upload(name, type)
  end

  test "複数の画像をアップロードすると、_T / _V でペアにして画像ごとにジョブを登録する" do
    assert_difference -> { InspectionImage.count }, 2 do
      assert_enqueued_jobs 2, only: ProcessInspectionImageJob do
        post inspections_path(site_id: @site.id), params: {
          inspection: { conducted_at: "2026-09-20T10:00", weather_note: "快晴",
                        files: [ upload("thermal_plain_T.jpg"), upload("rgb_V.jpg"), upload("lowres_T.jpg") ] }
        }
      end
    end

    inspection = @site.inspections.order(:created_at).last
    assert_redirected_to inspection_path(inspection)
    assert_equal "快晴", inspection.weather_note
    images = inspection.inspection_images.to_a
    assert_equal %w[lowres_T.jpg thermal_plain_T.jpg], images.map(&:thermal_filename)
    assert images.none? { |i| i.rgb.attached? }, "rgb_V は thermal_plain と名前が対にならない"
    assert_match "対になるサーモ画像が無い RGB 画像は登録していません: rgb_V.jpg", flash[:notice]
  end

  test "旧方式の Claude 判定のジョブは登録しない" do
    assert_no_enqueued_jobs only: AnalyzePanelImageJob do
      post inspections_path(site_id: @site.id), params: { inspection: { files: [ upload("thermal_plain_T.jpg") ] } }
    end
  end

  test "画像ファイル以外は登録できない" do
    assert_no_difference -> { Inspection.count } do
      post inspections_path(site_id: @site.id), params: { inspection: { files: [ upload("memo.txt", "text/plain") ] } }
    end

    assert_response :unprocessable_entity
    assert_match "画像ファイルではありません", response.body
  end

  test "受け入れ確認: 温度データの無い JPEG は要確認になり、理由が画面に表示される" do
    perform_enqueued_jobs(only: ProcessInspectionImageJob) do
      post inspections_path(site_id: @site.id), params: { inspection: { files: [ upload("thermal_plain_T.jpg") ] } }
    end
    inspection = @site.inspections.order(:created_at).last

    get inspection_path(inspection, site_id: @site.id)

    assert_response :success
    assert_select ".badge", text: "要確認"
    assert_match "温度データ（放射温度）が見つかりません", response.body
    assert_equal "needs_review", inspection.reload.analysis_status
  end

  test "品質チェック待ちの間は自動更新し、JSON で in_progress を返す" do
    inspection = create_session_inspection

    get inspection_path(inspection, site_id: @site.id)
    assert_select "[data-controller='auto-refresh']"

    get inspection_path(inspection, format: :json, site_id: @site.id)
    assert_equal true, response.parsed_body["in_progress"]
  end

  test "品質チェックが終わって解析待ちなら自動更新しない" do
    inspection = create_session_inspection
    inspection.inspection_images.first.update_columns(quality_report: { "status" => "ok", "checks" => [] })

    get inspection_path(inspection, site_id: @site.id)

    assert_select "[data-controller='auto-refresh']", count: 0
    assert_select ".badge", text: "解析待ち"
  end

  test "要確認の画像を理由付きで除外し、取り消せる" do
    inspection = create_session_inspection
    image = inspection.inspection_images.first
    image.update_columns(analysis_status: "needs_review", review_reason: "no_radiometric", quality_report: { "status" => "rejected", "checks" => [] })

    patch exclude_inspection_inspection_image_path(inspection, image, site_id: @site.id), params: { inspection_image: { exclusion_note: "パネルが写っていない" } }
    assert image.reload.excluded?
    assert_equal "needs_review", inspection.reload.analysis_status, "全画像が除外されたら要確認"

    patch unexclude_inspection_inspection_image_path(inspection, image, site_id: @site.id)
    assert image.reload.needs_review?
  end

  test "除外の理由が空なら除外しない" do
    inspection = create_session_inspection
    image = inspection.inspection_images.first
    image.update_columns(analysis_status: "needs_review")

    patch exclude_inspection_inspection_image_path(inspection, image, site_id: @site.id), params: { inspection_image: { exclusion_note: "" } }

    assert image.reload.needs_review?
    assert flash[:alert].present?
  end

  test "RGB 画像を手動で添付・削除できる" do
    inspection = create_session_inspection
    image = inspection.inspection_images.first

    patch inspection_inspection_image_path(inspection, image, site_id: @site.id), params: { inspection_image: { rgb: upload("rgb_V.jpg") } }
    assert image.reload.rgb.attached?

    perform_enqueued_jobs do
      delete rgb_inspection_inspection_image_path(inspection, image, site_id: @site.id)
    end
    assert_not image.reload.rgb.attached?
  end

  test "気象データは撮影時刻と同じタイムゾーン（Asia/Tokyo）の時刻として登録し、品質チェックをやり直す" do
    inspection = create_session_inspection

    assert_enqueued_with(job: RecheckInspectionQualityJob, args: [ inspection.id ]) do
      post inspection_weather_readings_path(inspection, site_id: @site.id), params: {
        weather_reading: { observed_at: "2026-09-20T10:15", irradiance_w_m2: 750, irradiance_type: "poa" }
      }
    end

    assert_equal jst("2026-09-20 10:15"), inspection.weather_readings.sole.observed_at
  end

  test "日射量の種類が無い気象データは登録しない" do
    inspection = create_session_inspection

    assert_no_difference -> { WeatherReading.count } do
      post inspection_weather_readings_path(inspection, site_id: @site.id), params: {
        weather_reading: { observed_at: "2026-09-20T10:15", irradiance_w_m2: 750, irradiance_type: "" }
      }
    end
    assert flash[:alert].present?
  end

  test "気象データを削除すると品質チェックをやり直す" do
    inspection = create_session_inspection
    reading = inspection.weather_readings.create!(observed_at: jst("2026-09-20 10:15"), wind_speed_m_s: 2)

    assert_enqueued_with(job: RecheckInspectionQualityJob) do
      delete inspection_weather_reading_path(inspection, reading, site_id: @site.id)
    end
    assert_not WeatherReading.exists?(reading.id)
  end
end
