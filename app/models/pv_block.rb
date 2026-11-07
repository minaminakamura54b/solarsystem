# 架台（docs/LAYOUT_OVERLAY_DESIGN.md の A-1）。登録は BlockLayoutImport（CSV・確認画面・全部の置き換え）だけで行う
class PvBlock < ApplicationRecord
  belongs_to :site
  has_many :panels, dependent: :nullify

  ORIENTATIONS = %w[portrait landscape].freeze
  SOURCES = { "drawing" => "図面", "image_map" => "画像から作った地図", "manual" => "手入力" }.freeze

  validates :label, presence: true, uniqueness: { scope: :site_id }
  validates :rows, :cols, numericality: { only_integer: true, greater_than: 0 }
  validates :panel_orientation, inclusion: { in: ORIENTATIONS }
  validates :source, inclusion: { in: SOURCES.keys }
end
