require "csv"

# 確定・修正済みの異常を YOLO 形式で書き出す（docs/IMPROVEMENT_PLAN.md Phase 5-6）。
#   OUT_DIR/images/*.jpg|png    画像（表示用の画像。R-JPEG は原本、.npy はプレビュー）
#   OUT_DIR/labels/*.txt        1行 = "クラス番号 中心x 中心y 幅 高さ"（0〜1）。確定・修正した異常（修正後の種類・位置）
#   OUT_DIR/classes.txt         クラス番号の順の種類名
#   OUT_DIR/manifest.csv        画像ごとの撮影条件と数値
#   OUT_DIR/labels_detail.csv   ラベル・却下した候補ごとの数値
# 対象は、解析が終わり（completed）、未確定の候補が残っていない画像だけ（ラベルが不完全な画像を含めない）。
# 却下した候補しかない画像・異常の無い画像は、空のラベル（負例）として含める
class DatasetExporter
  CLASSES = Anomaly::ANOMALY_TYPES
  CONFIRMED = InspectionReview::CONFIRMED

  Result = Data.define(:images, :labels, :negatives, :skipped_pending, :skipped_undisplayable)

  def initialize(out_dir, inspections: Inspection.all)
    @out = Pathname(out_dir).expand_path
    @inspections = inspections
  end

  def export!
    FileUtils.mkdir_p([ @out.join("images"), @out.join("labels") ])
    File.write(@out.join("classes.txt"), CLASSES.join("\n") + "\n")
    counts = { images: 0, labels: 0, negatives: 0, skipped_pending: 0, skipped_undisplayable: 0 }
    zone = ImageQualityConfig.current.capture_time_zone

    CSV.open(@out.join("manifest.csv"), "w") do |manifest|
      CSV.open(@out.join("labels_detail.csv"), "w") do |detail|
        manifest << MANIFEST_HEADERS
        detail << DETAIL_HEADERS
        InspectionImage.where(inspection: @inspections, analysis_status: "completed").includes(:anomalies, inspection: :site).find_each do |image|
          if image.anomalies.any? { |a| a.review_status == "pending" }
            counts[:skipped_pending] += 1
            next
          end
          unless image.displayable?
            counts[:skipped_undisplayable] += 1
            next
          end

          stem = "#{image.inspection_id}_#{image.sequence.to_s.rjust(4, '0')}_#{File.basename(image.thermal_filename.to_s, '.*').gsub(/[^\w.-]/, '_')}"
          ext = image.display_image.filename.extension_with_delimiter.downcase
          File.binwrite(@out.join("images", "#{stem}#{ext}"), image.display_image.download)

          labeled = image.anomalies.select { |a| CONFIRMED.include?(a.review_status) && a.effective_bbox.present? }
          rejected = image.anomalies.select { |a| a.review_status == "rejected" }
          File.write(@out.join("labels", "#{stem}.txt"), labeled.map { |a| yolo_line(a) }.join)
          (labeled + rejected).each { |a| detail << detail_row("#{stem}#{ext}", a) }

          manifest << manifest_row(image, "#{stem}#{ext}", "#{stem}.txt", labeled.size, rejected.size, zone)
          counts[:images] += 1
          counts[:labels] += labeled.size
          counts[:negatives] += 1 if labeled.empty?
        end
      end
    end
    Result.new(**counts)
  end

  MANIFEST_HEADERS = %w[
    image_file label_file inspection_id site image_sequence thermal_filename captured_at camera_model width height
    gps_lat gps_lng altitude_m gimbal_pitch gimbal_yaw irradiance_w_m2 irradiance_type wind_speed_m_s air_temp_c humidity
    baseline_temp rule_versions labels rejected negative
  ].freeze

  DETAIL_HEADERS = %w[
    image_file anomaly_id review_status class original_type severity delta_t normalized_delta_t threshold_basis measure
    area_ratio detection active_bands evidence_level rejection_reason x1 y1 x2 y2
  ].freeze

  private

  def yolo_line(anomaly)
    b = Bbox.normalize(anomaly.effective_bbox)
    cx = (b["x1"] + b["x2"]) / 2
    cy = (b["y1"] + b["y2"]) / 2
    format("%d %.6f %.6f %.6f %.6f\n", CLASSES.index(anomaly.effective_type), cx, cy, b["x2"] - b["x1"], b["y2"] - b["y1"])
  end

  def manifest_row(image, image_file, label_file, labels, rejected, zone)
    [
      image_file, label_file, image.inspection_id, image.inspection.site.name, image.sequence, image.thermal_filename,
      image.captured_at&.in_time_zone(zone)&.iso8601, image.camera_model, image.width, image.height,
      image.gps_lat, image.gps_lng, image.altitude_m, image.gimbal_pitch, image.gimbal_yaw,
      image.irradiance_w_m2, image.irradiance_type, image.wind_speed_m_s, image.air_temp_c, image.humidity,
      image.raw_analysis&.dig("baseline", "temp"), image.anomalies.filter_map(&:rule_version).uniq.join(" "),
      labels, rejected, labels.zero?
    ]
  end

  def detail_row(image_file, a)
    b = Bbox.normalize(a.effective_bbox) || {}
    [
      image_file, a.id, a.review_status, a.effective_type, a.anomaly_type, a.effective_severity, a.delta_t, a.normalized_delta_t,
      a.threshold_basis, a.measure, a.area_ratio, a.detection, a.active_bands, a.evidence_level, a.rejection_reason,
      b["x1"], b["y1"], b["x2"], b["y2"]
    ]
  end
end
