# 点検の対象範囲（見直し R1。2026-11-09 ユーザー承認）。
# アプリが案を出し、人が配置図の上で確定する。案は広めにする（解析できた画像に加え、使わなかった・要確認の画像の
# 位置合わせの下書きに少しでも写った架台も入れる）。写った所だけを範囲にして、解析できなかった所を隠さないため。
# 範囲を決めるのは人（案はそのまま使わず、確定の操作が要る）
class InspectionScope
  class Error < StandardError; end

  def initialize(inspection)
    @inspection = inspection
    @site = inspection.site
  end

  # 案: 少しでも写った架台の id
  def proposal
    ids = @inspection.inspection_images.reload.flat_map do |img|
      GridGeometry.touched_block_ids(GridGeometry.layout_grids(img.panel_grids) + GridGeometry.layout_grids(img.alignment.to_h["draft_grids"]))
    end
    @site.pv_blocks.where(id: ids.uniq).order(:label).pluck(:id)
  end

  # 確定する。block_ids は発電所の架台に限る。source: proposal（案を確定）/ manual（人が選んだ）
  def confirm!(block_ids, source:)
    ids = @site.pv_blocks.where(id: Array(block_ids).map(&:to_i)).pluck(:id).sort
    raise Error, "対象の架台を 1 つ以上選んでください" if ids.empty?

    @inspection.update_columns(scope_block_ids: ids, scope_source: source == "proposal" && ids == proposal.sort ? "proposal" : "manual",
                               scope_confirmed_at: Time.current, updated_at: Time.current)
  end

  # 確定を取り消す（発電所全体として扱う）
  def clear!
    @inspection.update_columns(scope_block_ids: nil, scope_source: nil, scope_confirmed_at: nil, updated_at: Time.current)
  end

  # 表紙・報告書に載せる範囲の文（例: 「架台 A01〜A05、B01（30 基・パネル 600 枚）」）
  def description
    blocks = @inspection.scope_confirmed? ? @site.pv_blocks.where(id: @inspection.scope_block_ids) : @site.pv_blocks
    labels = blocks.order(:label).pluck(:label)
    return nil if labels.empty?

    panels = @site.panels.where(pv_block_id: blocks.select(:id)).count
    range = self.class.compress(labels)
    prefix = @inspection.scope_confirmed? ? "" : "発電所全体（"
    suffix = @inspection.scope_confirmed? ? "" : "）"
    "#{prefix}架台 #{range}（#{labels.size} 基・パネル #{panels} 枚）#{suffix}"
  end

  # ["A01", "A02", "A03", "B01"] → "A01〜A03、B01"（番号が続く同じ英字をつなぐ）
  def self.compress(labels)
    keyed = labels.map { |label| m = label.match(/\A(\D*)(\d+)\z/); [ m ? m[1] : label, m ? m[2].to_i : nil, label ] }
    keyed.sort_by! { |prefix, num, label| [ prefix, num.to_i, label ] }
    runs = []
    keyed.each do |prefix, num, label|
      last = runs.last
      if last && num && last[:prefix] == prefix && last[:last_num] && last[:last_num] + 1 == num
        last[:last] = label
        last[:last_num] = num
      else
        runs << { prefix:, first: label, last: label, last_num: num }
      end
    end
    runs.map { |r| r[:first] == r[:last] ? r[:first] : "#{r[:first]}〜#{r[:last]}" }.join("、")
  end
end
