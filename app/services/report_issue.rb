# 報告書の発行（docs/IMPROVEMENT_PLAN.md Phase 7 の決定事項 2026-10-22・2026-11-09）。
# - 発行できるのはレビュー完了済みの点検だけ。発行しても点検はロックしない
# - 警告（未確定の候補・割り当てが外れた異常・古い所見・総括文・モジュール仕様の未登録・暫定の判定基準）があれば、
#   確認したときだけ発行する。確認した警告は版に残す
# - 第 2 版からは改訂の理由が必須。内容が前の版と同じなら発行しない
# - 発行者の欄は会社名と資格の種別だけ（任意入力）。氏名の欄は作らない
class ReportIssue
  class Error < StandardError; end

  def initialize(inspection, now: Time.current)
    @inspection = inspection
    @now = now
  end

  def snapshot
    @snapshot ||= ReportSnapshotBuilder.new(@inspection).build
  end

  def digest = ReportSnapshotBuilder.digest(snapshot)

  def latest = @inspection.inspection_reports.latest_first.first

  # 最新の版の発行後に内容が変わったか（版が無ければ nil）
  def changed_since_latest?
    latest && latest.content_digest != digest
  end

  def blockers
    errors = []
    errors << "レビューを完了していない点検の報告書は発行できません" unless @inspection.completed? && @inspection.reviewed_at.present?
    errors << "#{latest.title}から内容が変わっていません（同じ内容の版は発行しません）" if latest && !changed_since_latest?
    errors
  end

  def issue!(acknowledge_warnings: false, revision_reason: nil, company_name: nil, qualification: nil, addressee: nil)
    @inspection.with_lock do
      errors = blockers
      warnings = snapshot["warnings"]
      errors << "警告を確認してください" if warnings.any? && !acknowledge_warnings
      raise Error, errors.join("／") if errors.any?

      number = (latest&.version_number || 0) + 1
      issue_meta = { "version_number" => number, "issued_at" => @now.iso8601,
                     "company_name" => company_name.to_s.strip.presence, "qualification" => qualification.to_s.strip.presence,
                     "addressee" => (addressee.nil? ? snapshot["default_addressee"] : addressee.to_s.strip.presence),
                     "revision_reason" => revision_reason.to_s.strip.presence }
      @inspection.inspection_reports.create!(version_number: number, issued_at: @now, snapshot: snapshot.merge("issue" => issue_meta),
                                             content_digest: digest, revision_reason: revision_reason.to_s.strip.presence,
                                             acknowledged_warnings: warnings)
    end
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.join("／")
  end
end
