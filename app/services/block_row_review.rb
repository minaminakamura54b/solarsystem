# 架台・段の候補のレビュー（案 X 改）。確定・却下で locked にし、作り直しの対象から外す
class BlockRowReview
  Error = Class.new(StandardError)

  def initialize(finding, now: Time.current)
    @finding = finding
    @now = now
  end

  def confirm!(note: nil)
    raise Error, "候補ではない段は確定できません" unless @finding.candidate?

    finish!("confirmed", nil, note)
  end

  def reject!(reason:, note: nil)
    raise Error, "却下の理由を選んでください" unless AnomalyReview::REJECTION_REASONS.key?(reason) && reason != "duplicate"
    raise Error, "候補ではない段は却下できません" unless @finding.candidate?

    finish!("rejected", reason, note)
  end

  private

  def finish!(status, reason, note)
    @finding.update!(review_status: status, locked: true, rejection_reason: reason, reviewer_note: note.presence, reviewed_at: @now)
    InspectionReview.new(@finding.inspection, now: @now).reopen!
    @finding
  end
end
