class InspectionsController < ApplicationController
  before_action :require_site
  before_action :find_inspection, only: %i[show destroy]

  def index
    @inspections = current_site.inspections.recent.includes(:site, :inspection_images, image_attachment: :blob)
  end

  # 表示用の値を組み立てるだけで、DB には書き込まない
  def show
    if @inspection.legacy?
      prepare_legacy_display
    else
      @images = @inspection.inspection_images.includes(thermal_attachment: :blob, rgb_attachment: :blob)
      @new_reading = @inspection.weather_readings.build
      @capture_time_zone = ImageQualityConfig.current.capture_time_zone
    end

    respond_to do |format|
      format.html
      format.json do
        render json: {
          id: @inspection.id,
          analysis_status: @inspection.analysis_status,
          in_progress: @inspection.in_progress?,
          severity: @inspection.severity,
          anomaly_count: @inspection.anomaly_count,
          image_status_counts: @inspection.image_status_counts
        }
      end
    end
  end

  def new
    @inspection = current_site.inspections.build(conducted_at: Time.current)
  end

  # 複数のサーモ画像（と同時撮影の RGB）を受け取り、ファイル名の _T / _V でペアにして画像ごとに登録する。
  # 旧方式の Claude 判定は行わない。画像ごとにメタデータ読み取りと品質チェックのジョブを登録する
  def create
    @inspection = current_site.inspections.build(inspection_params)
    @inspection.conducted_at ||= Time.current
    blobs = uploaded_blobs
    pairing = ImagePairing.pair(blobs)
    pairing.pairs.each_with_index do |pair, index|
      image = @inspection.inspection_images.build(sequence: index + 1, thermal_filename: pair.thermal.filename.to_s)
      image.thermal.attach(pair.thermal)
      image.rgb.attach(pair.rgb) if pair.rgb
    end

    if @inspection.save
      pairing.unpaired_rgb.each(&:purge_later)
      @inspection.inspection_images.each { |image| ProcessInspectionImageJob.perform_later(image.id) }
      redirect_to inspection_path(@inspection), notice: create_notice(pairing)
    else
      blobs.each { |blob| blob.purge_later unless blob.attachments.exists? }
      render :new, status: :unprocessable_entity
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    @inspection.errors.add(:base, "アップロードされたファイルを確認できませんでした。もう一度選択してください")
    render :new, status: :unprocessable_entity
  end

  def destroy
    @inspection.destroy
    redirect_to inspections_path, notice: "点検記録を削除しました"
  end

  private

  def require_site
    redirect_to sites_path, alert: "発電所を選択してください" unless current_site
  end

  def find_inspection
    @inspection = current_site.inspections.find(params[:id])
  end

  def inspection_params
    params.require(:inspection).permit(:conducted_at, :weather_note)
  end

  # 直接アップロード（署名付き ID）と通常のファイル送信の両方を受け付ける
  def uploaded_blobs
    Array(params.dig(:inspection, :files)).compact_blank.map do |file|
      if file.is_a?(String)
        ActiveStorage::Blob.find_signed!(file)
      else
        ActiveStorage::Blob.create_and_upload!(io: file, filename: file.original_filename, content_type: file.content_type)
      end
    end
  end

  def create_notice(pairing)
    rgb_count = pairing.pairs.count(&:rgb)
    message = "#{pairing.pairs.size}枚の画像を登録しました（RGB とのペア #{rgb_count}組）。メタデータの読み取りと品質チェックを行います"
    if pairing.unpaired_rgb.any?
      names = pairing.unpaired_rgb.map { |b| b.filename.to_s }.join("、")
      message += "。対になるサーモ画像が無い RGB 画像は登録していません: #{names}（画像ごとに手動で添付できます）"
    end
    message
  end

  # 旧方式の点検。result に Claude の生 JSON が入っていることがあるので、そこから概要などを読む
  def prepare_legacy_display
    @display_anomalies = @inspection.legacy_anomalies
    if @inspection.completed? && @inspection.result.to_s.strip.start_with?("{")
      begin
        parsed = JSON.parse(@inspection.result)
        @display_anomalies      = parsed["anomalies"] || [] if @display_anomalies.blank?
        @display_summary        = parsed["summary"]
        @display_recommendation = parsed["recommendation"]
      rescue JSON::ParserError
        @display_summary = nil
      end
    else
      @display_summary        = @inspection.result
      @display_recommendation = recommendation_from_report(@inspection.report)
    end
  end

  def recommendation_from_report(report)
    return nil if report.blank? || report.strip.start_with?("{")
    lines = report.split("\n")
    idx = lines.index { |l| l.include?("推奨アクション") }
    return nil unless idx
    lines[idx + 1..].reject(&:blank?).join("\n").strip.presence
  end
end
