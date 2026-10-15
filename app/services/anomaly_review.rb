# 異常・異常群のレビュー操作（docs/IMPROVEMENT_PLAN.md Phase 5）。
# - 確定・修正・却下で locked = true にする。元の判定値（anomaly_type・bbox・severity）は残し、修正は final_* に保存する
# - 証拠レベル: RGB を確認して確定・修正したとき B、電気測定を入力したとき A（検出時点はすべて C）
# - 群は群単位で確定・却下し、構成パネルの異常にも反映する
# - 確定・修正した critical の異常・群には ConfirmedAnomalyAlert でアラートを1件作る
# - 完了済みの点検でレビュー操作をしたら、点検をレビュー待ちに戻す（重要度を付け直すため）
class AnomalyReview
  REJECTION_REASONS = { "glare" => "グレア（反射）", "shadow" => "影", "soiling" => "汚れ", "other" => "その他" }.freeze
  CAUSES = {
    "cell_crack" => "セルの割れ・欠け", "solder" => "はんだ・セル間接続の不良", "bypass_diode" => "バイパスダイオードの故障",
    "junction_box" => "ジャンクションボックスの不良", "string_open" => "ストリングの開放・接続不良",
    "delamination" => "剥離・変色", "shadow" => "影", "soiling" => "汚れ・鳥の糞", "other" => "その他"
  }.freeze
  ELECTRICAL_METHODS = { "iv_curve" => "IV カーブ", "string_current" => "ストリング電流", "insulation" => "絶縁抵抗", "other" => "その他" }.freeze

  Error = Class.new(StandardError)

  def initialize(record, now: Time.current)
    @record = record
    @now = now
  end

  def confirm!(rgb_checked: false, causes: [], note: nil)
    review!("confirmed", rgb_checked: rgb_checked, causes: causes, note: note)
  end

  # 種類・位置を修正して確定する。重大度は、判定時のルールセットで修正後の種類の閾値を使って付け直す
  def correct!(final_anomaly_type:, final_bbox: nil, rgb_checked: false, causes: [], note: nil)
    raise Error, "異常群は種類・位置を修正できません（群から外してから修正してください）" if group?
    raise Error, "種類が不正です" unless Anomaly::ANOMALY_TYPES.include?(final_anomaly_type)

    bbox = final_bbox.present? ? Bbox.normalize(final_bbox) : nil
    raise Error, "位置（bbox）が不正です" if final_bbox.present? && bbox.nil?

    @record.final_anomaly_type = final_anomaly_type
    @record.final_bbox = bbox if bbox
    @record.final_severity = corrected_severity(final_anomaly_type)
    review!("corrected", rgb_checked: rgb_checked, causes: causes, note: note)
  end

  def reject!(reason:, note: nil)
    raise Error, "却下の理由を選んでください" unless REJECTION_REASONS.key?(reason)

    @record.rejection_reason = reason
    review!("rejected", note: note)
  end

  # パネルを割り当てる（人の指定。並び順などで機械的に割り当てない）。ロックはしない
  def assign_panel!(panel)
    raise Error, "異常群にはパネルを割り当てられません" if group?
    raise Error, "この発電所のパネルではありません" if panel && panel.site_id != @record.inspection.site_id

    @record.update!(panel: panel)
    reopen_inspection
  end

  # 電気測定の結果を入力する。入力があれば証拠レベル A
  def record_electrical!(method:, result:, measured_on: nil)
    raise Error, "異常群には電気測定を入力できません（構成パネルごとに入力してください）" if group?
    raise Error, "測定方法を選んでください" unless ELECTRICAL_METHODS.key?(method)
    raise Error, "測定結果を入力してください" if result.blank?

    @record.update!(electrical_evidence: { "method" => method, "result" => result.to_s.strip, "measured_on" => measured_on.presence },
                    evidence_level: "A")
    reopen_inspection
  end

  # 群から特定のパネルの異常を外す（単独の異常として数える）
  def remove_from_group!
    group = @record.anomaly_group
    raise Error, "群に属していません" unless group

    AnomalyGroup.transaction do
      @record.update!(anomaly_group: nil)
      indices = group.panel_indices - [ @record.panel_index_in_image ]
      if indices.empty?
        group.destroy!
      else
        group.update!(panel_indices: indices, panel_count: indices.size)
      end
    end
    reopen_inspection
  end

  # 見逃しを手動で追加する（人が判断したので確定・locked）。温度の数値は無いので重大度は人が選ぶ
  def self.add_manual!(image, anomaly_type:, bbox:, severity:, panel_index: nil, causes: [], rgb_checked: false, note: nil, now: Time.current)
    raise Error, "種類が不正です" unless Anomaly::ANOMALY_TYPES.include?(anomaly_type)
    raise Error, "重大度を選んでください" unless Anomaly::SEVERITIES.include?(severity)

    normalized = Bbox.normalize(bbox)
    raise Error, "位置（bbox）を画像の上で指定してください" unless normalized && Bbox.area(normalized).positive?

    anomaly = image.anomalies.create!(
      inspection: image.inspection, anomaly_type: anomaly_type, detection: "manual", bbox: normalized,
      severity: severity, panel_index_in_image: panel_index.presence&.to_i, review_status: "confirmed", locked: true,
      reviewed_at: now, reviewer_note: note.presence, selected_causes: clean_causes(causes),
      evidence_level: rgb_checked && image.rgb.attached? ? "B" : "C"
    )
    ConfirmedAnomalyAlert.call(anomaly)
    InspectionReview.new(image.inspection).reopen!
    anomaly
  end

  def self.clean_causes(causes)
    Array(causes).map(&:to_s) & CAUSES.keys
  end

  private

  def group?
    @record.is_a?(AnomalyGroup)
  end

  def review!(status, rgb_checked: false, causes: [], note: nil)
    ActiveRecord::Base.transaction do
      @record.review_status = status
      @record.locked = true
      @record.reviewed_at = @now
      @record.reviewer_note = note.presence if note
      unless group?
        @record.selected_causes = self.class.clean_causes(causes) if status != "rejected"
        @record.evidence_level = "B" if rgb_checked && @record.inspection_image.rgb.attached? && @record.evidence_level == "C"
      end
      @record.save!
      apply_to_members(status) if group?
    end
    ConfirmedAnomalyAlert.call(@record) if %w[confirmed corrected].include?(status)
    reopen_inspection
    @record
  end

  def apply_to_members(status)
    @record.anomalies.each do |member|
      member.update!(review_status: status, locked: true, reviewed_at: @now, rejection_reason: @record.rejection_reason)
    end
  end

  # 判定時のルールセット（無ければ現在有効なもの）で、修正後の種類の閾値を使って重大度を付け直す
  def corrected_severity(anomaly_type)
    rule_set = @record.rule_set || RuleSet.active_set
    rule = rule_set&.rule_for(anomaly_type)
    rule ? SeverityRuleEngine.new(rule_set).severity(rule, @record) : @record.severity
  end

  def reopen_inspection
    InspectionReview.new(@record.inspection).reopen!
  end
end
