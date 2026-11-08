# パネルの候補のレビュー（docs/LAYOUT_OVERLAY_DESIGN.md の C-1）。判断は束ねた観測（画像ごとの異常）に AnomalyReview で入れる。
# - 確定: 代表の観測と、代表と同じ画像の観測を確定。ほかの画像の観測は「他の画像と重複」（まとめ先は代表）で却下
#   （同じ異常を何枚分も数えない。学習データでは、まとめ先の判断に合わせて異常ありになる）
# - 却下: 束ねた観測をすべて、選んだ理由で却下（「他の画像と重複」は選べない）
# - 人が判断済み（locked）の観測は変えない。判断した候補は locked にし、作り直しの対象から外す
class PanelCandidateReview
  Error = Class.new(StandardError)

  def initialize(candidate, now: Time.current)
    @candidate = candidate
    @now = now
  end

  def confirm!(note: nil)
    rep = @candidate.representative_anomaly
    raise Error, "代表の観測がありません" unless rep

    ActiveRecord::Base.transaction do
      pending_members.each do |a|
        if a.inspection_image_id == rep.inspection_image_id
          AnomalyReview.new(a, now: @now).confirm!(note:)
        else
          AnomalyReview.new(a, now: @now).reject!(reason: "duplicate", duplicate_of: rep, note: "パネルの候補でまとめて確定（代表: 画像 #{rep.inspection_image.sequence}）")
        end
      end
      finish!("confirmed", nil, note)
    end
  end

  def reject!(reason:, note: nil)
    raise Error, "却下の理由を選んでください" unless AnomalyReview::REJECTION_REASONS.key?(reason) && reason != "duplicate"

    ActiveRecord::Base.transaction do
      pending_members.each { |a| AnomalyReview.new(a, now: @now).reject!(reason:, note:) }
      finish!("rejected", reason, note)
    end
  end

  private

  # 代表を先に（重複のまとめ先は確定済みでなくてもよいが、順番をそろえる）
  def pending_members
    rep_id = @candidate.representative_anomaly_id
    @candidate.anomalies.reload.reject(&:locked).sort_by { |a| a.id == rep_id ? 0 : 1 }
  end

  def finish!(status, reason, note)
    @candidate.update!(review_status: status, locked: true, rejection_reason: reason, reviewer_note: note.presence, reviewed_at: @now)
  end
end
