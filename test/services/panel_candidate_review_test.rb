require "test_helper"

# パネルの候補のレビュー（束ねた観測に判断を入れる）
class PanelCandidateReviewTest < ActiveSupport::TestCase
  setup do
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg thermal_plain_T.jpg])
    blocks = register_blocks(@inspection.site)
    @i1, @i2 = @inspection.inspection_images.order(:sequence).to_a
    analyzed_image(@i1, blocks.values, y0: 0.4)
    analyzed_image(@i2, blocks.values, y0: 0.45)
    @a1 = anomaly_at(@i1, 0, 2, 3)
    @a2 = anomaly_at(@i2, 0, 2, 3)
    @candidate = PanelCandidateBuilder.new(@inspection).call.sole
  end

  test "確定すると代表の観測を確定し、ほかの画像の観測は代表への重複として却下する（同じ異常を何枚分も数えない）" do
    rep = @candidate.representative_anomaly
    other = ([ @a1, @a2 ] - [ rep ]).sole

    PanelCandidateReview.new(@candidate).confirm!

    assert_equal [ "confirmed", true ], [ rep.reload.review_status, rep.locked ]
    assert_equal [ "rejected", "duplicate", rep.id ], [ other.reload.review_status, other.rejection_reason, other.duplicate_of_id ]
    assert_equal :label, other.duplicate_outcome
    assert_equal [ "confirmed", true ], [ @candidate.reload.review_status, @candidate.locked ]
  end

  test "却下すると束ねた観測をすべて同じ理由で却下する。「他の画像と重複」は選べない" do
    assert_raises(PanelCandidateReview::Error) { PanelCandidateReview.new(@candidate).reject!(reason: "duplicate") }

    PanelCandidateReview.new(@candidate).reject!(reason: "structure")

    assert_equal [ %w[rejected structure] ] * 2, [ @a1, @a2 ].map { |a| a.reload.then { |x| [ x.review_status, x.rejection_reason ] } }
    assert_equal [ "rejected", "structure" ], [ @candidate.reload.review_status, @candidate.rejection_reason ]
  end

  test "人が判断済みの観測は変えない" do
    AnomalyReview.new(@a2).confirm!
    PanelCandidateReview.new(@candidate.reload).reject!(reason: "glare")

    assert_equal "confirmed", @a2.reload.review_status
    assert_equal "rejected", @a1.reload.review_status
  end
end
