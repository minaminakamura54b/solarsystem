# パネルの候補（docs/LAYOUT_OVERLAY_DESIGN.md の C-1）。同じパネルの同じ場所の異常（画像ごとの観測）を束ねたもの。
# 作り直しは PanelCandidateBuilder、レビューは PanelCandidateReview。判定（重大度）は観測ごとのまま変えない
class PanelCandidate < ApplicationRecord
  belongs_to :inspection
  belongs_to :panel
  belongs_to :representative_anomaly, class_name: "Anomaly", optional: true
  has_many :anomalies, dependent: :nullify

  KINDS = %w[area point].freeze
  POINT_TYPES = %w[hotspot multi_hotspot].freeze
  FLAGS = {
    "single_view" => "1 枚だけ",
    "position_biased" => "写る位置で変わる",
    "same_position" => "多くの架台の同じ位置",
    "registered_structure" => "登録済みの部材の位置"
  }.freeze

  validates :kind, inclusion: { in: KINDS }

  scope :pending, -> { where(review_status: "pending") }

  def self.kind_for(anomaly_type) = POINT_TYPES.include?(anomaly_type) ? "point" : "area"

  def pending? = review_status == "pending"
  def max_delta_t = anomalies.map { |a| a.delta_t.to_f }.max
  def severities = anomalies.map(&:effective_severity).compact.tally
end
