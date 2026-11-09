class InspectionsController < ApplicationController
  before_action :require_site
  before_action :find_inspection, only: %i[show destroy rejudge review complete_review explain measurement claude_setting findings]

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
      @confirmed_anomalies = @inspection.anomalies.where(review_status: InspectionReview::CONFIRMED).countable
                                        .includes(:panel, :inspection_image, inspection: :site).order(:inspection_image_id, :id)
      @confirmed_groups = @inspection.anomaly_groups.where(review_status: InspectionReview::CONFIRMED)
                                     .includes(:inspection_image, inspection: :site, anomalies: :panel).order(:inspection_image_id, :id)
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
      (pairing.unpaired_rgb + pairing.duplicates).each(&:purge_later)
      @inspection.inspection_images.each { |image| ProcessInspectionImageJob.perform_later(image.id) }
      flash[:alert] = pairing_warning(pairing)
      redirect_to inspection_path(@inspection), notice: create_notice(pairing)
    else
      blobs.each { |blob| blob.purge_later unless blob.attachments.exists? }
      render :new, status: :unprocessable_entity
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    @inspection.errors.add(:base, "アップロードされたファイルを確認できませんでした。もう一度選択してください")
    render :new, status: :unprocessable_entity
  end

  # 未確定の異常・群を、現在有効な判定基準で判定し直す（明示的な操作のときだけ）。
  # mild を下げても新しい候補は増えない（解析エンジンは mild 未満を出力しない）。増やすには画像の再解析が必要
  def rejudge
    rule_set = RuleSet.active_set
    if rule_set.nil?
      redirect_to inspection_path(@inspection), alert: "有効な判定基準（ルールセット）がありません"
    else
      count = SeverityRuleEngine.new(rule_set).rejudge!(@inspection)
      redirect_to inspection_path(@inspection),
        notice: "未確定の異常・群 #{count} 件を判定基準「#{rule_set.version}」で判定し直しました。確定済みのものは変わりません。" \
                "mild を下げた場合、新しい候補を出すには画像の再解析が必要です"
    end
  end

  # レビュー画面（画像ごと）。params[:image] は画像の番号（sequence）
  def review
    @images = @inspection.inspection_images.to_a
    if @images.empty?
      redirect_to inspection_path(@inspection), alert: "旧方式の点検はレビューできません"
      return
    end
    @image = @images.find { |i| i.sequence == params[:image].to_i } || @images.first
    @groups = @image.anomaly_groups.includes(:anomalies).order(:id)
    @anomalies = @image.anomalies.includes(:panel).order(:panel_index_in_image, :id)
    @panels = review_panels
    @review = InspectionReview.new(@inspection)
    # 「他の画像と重複」のまとめ先の候補（別の画像の、重複として却下していない異常）
    @duplicate_candidates = @inspection.anomalies.where.not(inspection_image_id: @image.id).includes(:inspection_image, :panel)
                                       .reject(&:rejected_as_duplicate?).sort_by { |a| [ a.inspection_image.sequence, a.id ] }
  end

  # レビュー完了。完了できなければ理由と警告を表示してレビュー画面に戻る
  def complete_review
    result = InspectionReview.new(@inspection).complete!(
      all_images_checked: params[:all_images_checked] == "1", acknowledge_pending: params[:acknowledge_pending] == "1"
    )
    if result.completed?
      if @inspection.claude_enabled? && (problems = FindingsStatus.config_problems).any?
        # 設定が足りないときは送らない（作れないまま気づかないことがないよう、完了の知らせに出す）
        notice = "レビューを完了しました（重要度: #{@inspection.reload.severity_label}）。ただし Claude の設定が足りないため、所見・総括文は作っていません（#{problems.join('・')}）"
      elsif @inspection.claude_enabled?
        ExplainInspectionJob.perform_later(@inspection.id)
        notice = "レビューを完了しました（重要度: #{@inspection.reload.severity_label}）。確定した異常の所見と総括文を Claude で作成します（結果は点検の画面の上に出ます）"
      else
        notice = "レビューを完了しました（重要度: #{@inspection.reload.severity_label}）。所見と総括文は「所見・総括」の欄に書いてください"
      end
      notice += "。#{result.warnings.join('。')}" if result.warnings.any?
      redirect_to inspection_path(@inspection), notice: notice
    else
      back = params[:return_to] == "panel_review" ? inspection_panel_review_path(@inspection, anchor: "complete") : review_inspection_path(@inspection, image: params[:image], anchor: "complete")
      redirect_to back, alert: (result.warnings + result.errors).join("。")
    end
  end

  # 確定した異常の所見と総括文を作り直す（入力が変わっていなくても作り直す）。レビューを完了した点検だけ
  def explain
    if !@inspection.claude_enabled?
      redirect_to inspection_path(@inspection, anchor: "findings"), alert: "この点検は Claude を使わない設定です"
    elsif (problems = FindingsStatus.config_problems).any?
      redirect_to inspection_path(@inspection, anchor: "findings-status"), alert: "Claude の設定が足りないため作れません（#{problems.join('・')}）"
    elsif @inspection.completed? && @inspection.reviewed_at.present?
      ExplainInspectionJob.perform_later(@inspection.id, force: true)
      redirect_to inspection_path(@inspection, anchor: "findings"), notice: "所見と総括文を作り直しています"
    else
      redirect_to inspection_path(@inspection), alert: "所見はレビューを完了した点検だけ作れます"
    end
  end

  # Claude の所見・総括文を、この点検で「使う／使わない」（既定は使わない。2026-11-09 ユーザー指示）。
  # 使うにするのは、顧客との取り決めで外部のサービスでの処理が認められていることを確認したときだけ
  def claude_setting
    enable = params[:claude_enabled] == "1"
    if enable && params[:agreement_confirmed] != "1"
      return redirect_to inspection_path(@inspection, anchor: "claude"), alert: "顧客との取り決めを確認したうえで「使う」にしてください"
    end

    @inspection.update_columns(claude_enabled: enable, claude_enabled_changed_at: Time.current, updated_at: Time.current)
    notice =
      if !enable then "この点検では Claude を使いません（所見・総括文は人が書きます）"
      elsif @inspection.completed? && @inspection.reviewed_at.present?
        "この点検では Claude で所見・総括文を作ります。レビューはもう完了しているので、「所見を作る」を押すと作ります（送った内容は記録します）"
      else "この点検では Claude で所見・総括文を作ります。レビュー完了のときに作ります（送った内容は記録します）"
      end
    redirect_to inspection_path(@inspection, anchor: enable ? "findings-status" : "claude"), notice:
  end

  # 人が書く所見（確定した異常・群）と総括文を保存する（Claude を使わない点検。判定・重大度は変えない）
  def findings
    now = Time.current
    Inspection.transaction do
      if params.key?(:manual_summary) && @inspection.manual_summary.to_s != params[:manual_summary].to_s.strip
        @inspection.update_columns(manual_summary: params[:manual_summary].to_s.strip.presence, manual_summary_updated_at: now, updated_at: now)
      end
      { anomaly_findings: @inspection.anomalies, group_findings: @inspection.anomaly_groups }.each do |key, scope|
        params.fetch(key, {}).each_pair do |id, text|
          record = scope.find(id)
          next if record.manual_finding.to_s == text.to_s.strip

          record.update_columns(manual_finding: text.to_s.strip.presence, manual_finding_updated_at: now, updated_at: now)
        end
      end
    end
    redirect_to inspection_path(@inspection, anchor: "findings"), notice: "所見と総括文を保存しました"
  end

  # 測定パラメータ（放射率・反射温度・距離）を保存する。解析済みの画像に反映するには再解析が必要（自動では解析し直さない）
  def measurement
    if @inspection.update(params.require(:inspection).permit(:emissivity, :reflected_temperature_c, :object_distance_m))
      redirect_to inspection_path(@inspection, anchor: "measurement"),
                  notice: "測定パラメータを保存しました。解析済みの画像に反映するには、画像ごとに再解析してください"
    else
      redirect_to inspection_path(@inspection, anchor: "measurement"), alert: @inspection.errors.map(&:message).join("。")
    end
  end

  def destroy
    if @inspection.destroy
      redirect_to inspections_path, notice: "点検記録を削除しました"
    else
      # 報告書を発行した点検は削除しない（発行した版は顧客に渡した内容の記録のため）
      redirect_to inspection_path(@inspection), alert: "報告書を発行した点検は削除できません"
    end
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

  # レビュー画面のパネルの選択肢。架台との位置合わせのグリッドがある画像では、写っている架台のパネル（と割り当て済みのパネル）
  # だけにする（架台から作ったパネルは数千枚になり、異常ごとに全部を並べると画面が重くなるため）
  def review_panels
    block_ids = Array(@image.panel_grids).filter_map { |g| g["pv_block_id"] }
    panels = @inspection.site.panels.by_position
    return panels if block_ids.empty?

    panels.where(pv_block_id: block_ids).or(panels.where(id: @anomalies.map(&:panel_id).compact))
  end

  def create_notice(pairing)
    rgb_count = pairing.pairs.count(&:rgb)
    "#{pairing.pairs.size}枚の画像を登録しました（RGB とのペア #{rgb_count}組）。メタデータの読み取りと品質チェックを行います"
  end

  # 登録しなかったファイルの警告（無ければ nil）
  def pairing_warning(pairing)
    names = ->(blobs) { blobs.map { |b| b.filename.to_s }.join("、") }
    no_thermal = pairing.unpaired_rgb - pairing.mismatched_rgb
    warnings = []
    if pairing.mismatched_rgb.any?
      gap = ImageQualityConfig.current.pairing_max_time_gap_seconds.to_i
      warnings << "番号が同じサーモ画像と撮影時刻が #{gap} 秒を超えてずれている RGB 画像は、組にせず登録していません: " \
                  "#{names.(pairing.mismatched_rgb)}（別の飛行の画像の可能性があります。画像ごとに手動で添付できます）"
    end
    warnings << "対になるサーモ画像が無い RGB 画像は登録していません: #{names.(no_thermal)}（画像ごとに手動で添付できます）" if no_thermal.any?
    if pairing.duplicates.any?
      warnings << "複製と思われるファイル（名前の末尾が「 (2)」など）は登録していません: #{names.(pairing.duplicates)}" \
                  "（元のファイルが無い場合は、名前を直してから登録してください）"
    end
    warnings.join(" / ").presence
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
