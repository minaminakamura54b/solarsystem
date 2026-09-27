# 画像に適用するパネルのグリッド（docs/IMPROVEMENT_PLAN.md 4.2）。入力 UI は Phase 4
class GridTemplate < ApplicationRecord
  ORIENTATIONS = %w[portrait landscape].freeze

  belongs_to :inspection

  validates :name, presence: true
  validates :rows, :cols, numericality: { only_integer: true, greater_than: 0 }
  validates :panel_orientation, inclusion: { in: ORIENTATIONS }
end
