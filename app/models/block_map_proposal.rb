require "csv"

# 点検の画像から作った架台の地図の候補（docs/LAYOUT_OVERLAY_DESIGN.md の A-3）。
# 候補は自動では使わない。人が確認・修正し、架台の CSV（BlockLayoutImport）として登録して初めて使う
class BlockMapProposal < ApplicationRecord
  belongs_to :site
  belongs_to :inspection

  STATUSES = %w[pending running proposed needs_review failed].freeze
  STATUS_LABELS = { "pending" => "待機中", "running" => "作成中", "proposed" => "候補あり", "needs_review" => "作れませんでした（要確認）", "failed" => "失敗" }.freeze

  validates :status, inclusion: { in: STATUSES }
  validate :module_size_present

  MapBlock = Data.define(:label, :rows, :cols, :corners_local, :low_confidence)

  def blocks = Array(result&.dig("blocks"))
  def proposed? = status == "proposed"
  def in_progress? = %w[pending running].include?(status)

  # 配置図の表示用（ラベルは並び順の番号）
  def map_blocks
    blocks.each_with_index.map do |b, i|
      MapBlock.new(label: (i + 1).to_s, rows: rows_for(b), cols: cols_for(b), corners_local: b["corners_local"].map { |c| c.first(2) },
                   low_confidence: b["low_confidence"])
    end
  end

  # 架台の CSV（BlockLayoutImport と同じ形）。架台ラベルは空欄（取り込みで自動）
  def to_csv
    CSV.generate do |csv|
      csv << BlockLayoutImport::COLUMNS.keys
      blocks.each do |b|
        upper = b["corners_local"][0][2]
        lower = b["corners_local"][3][2]
        csv << [ nil, rows_for(b), cols_for(b), *b["corners_latlng"].flatten.map { |v| format("%.8f", v) }, "portrait",
                 params["facing_azimuth_deg"] || 180, nil, upper, lower, "image_map", b["low_confidence"] ? "true" : "false",
                 b["observations"].to_h.values.sum ]
      end
    end
  end

  private

  def rows_for(block) = block["rows_estimate"] || params["rows"].presence&.to_i || 2
  def cols_for(block) = block["cols_estimate"]

  def module_size_present
    %w[module_width_m module_length_m].each do |key|
      value = params[key].to_f
      errors.add(:base, "モジュールの#{key == 'module_width_m' ? '幅' : '長さ'}（m）を 0.3〜3 の範囲で入力してください") unless value.between?(0.3, 3.0)
    end
  end
end
