# 発電所ごとの「部材の位置」（案 A）。登録は、パネルごとの候補を「部材・構造物」でまとめて却下するときだけ（人の判断から）。
# 次の点検から、この位置に出た点状の発熱の候補に「登録済みの部材の位置」の目印を付ける（自動では却下しない・検出は変えない）
class StructurePosition < ApplicationRecord
  belongs_to :site
  belongs_to :source_inspection, class_name: "Inspection", optional: true

  validates :block_row, :block_col, :bins, numericality: { only_integer: true, greater_than: 0 }
  validates :u_bin, :v_bin, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def self.key_for(panel, location, bins)
    [ panel.block_row, panel.block_col, (location["u"].to_f * bins).floor.clamp(0, bins - 1), (location["v"].to_f * bins).floor.clamp(0, bins - 1), bins ]
  end

  def key = [ block_row, block_col, u_bin, v_bin, bins ]

  def description
    "#{block_row} 段目・#{block_col} 列目のパネル・パネルの中の区画（横 #{u_bin + 1}/#{bins}・縦 #{v_bin + 1}/#{bins}）"
  end
end
