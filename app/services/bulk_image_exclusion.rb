# 要確認・失敗の画像を、理由ごとにまとめて除外する（docs/IMPROVEMENT_PLAN.md Phase 7 の決定事項 2026-11-09）。
# - 理由のまとまり: 画像の状態（要確認・失敗）と理由。位置合わせ不可は、位置合わせの理由ごとに分ける
# - 除外する前に、InspectionCoverage で「除外すると写っていないまま残るパネル」の数を出す
# - 除外の理由は画像の review_reason（と位置合わせの記録）のまま残し、除外のメモに理由の名前を書く
# - 正常にはしない（除外した画像は判定に使わない。報告書の「点検の範囲と限界」に載る）
class BulkImageExclusion
  class Error < StandardError; end

  ALIGNMENT_REASONS = {
    "no_blocks_in_view" => "登録した架台が写っていない",
    "no_across_anchor" => "架台の長辺が見つからない",
    "no_along_anchor" => "架台の端が見つからない",
    "residual_too_large" => "補正後のずれが大きい",
    "inconsistent_edges" => "画像の辺と架台の対応がそろわない",
    "no_radiometric" => "温度データを読めない"
  }.freeze

  Group = Data.define(:key, :label, :images)

  def initialize(inspection)
    @inspection = inspection
  end

  def groups
    targets = @inspection.inspection_images.reload.select { |img| img.needs_review? || img.failed? }
    targets.group_by { |img| self.class.key_for(img) }
           .map { |key, images| Group.new(key:, label: "#{key.start_with?('failed:') ? '失敗' : '要確認'}: #{self.class.reason_label(images.first)}", images:) }
           .sort_by { |g| -g.images.size }
  end

  # 理由のまとまりのキー（状態:理由、位置合わせ不可は 状態:alignment_failed:位置合わせの理由）
  def self.key_for(image)
    reason = image.review_reason.presence || "unknown"
    reason = "#{reason}:#{image.alignment.to_h['review_reason'] || 'other'}" if reason == "alignment_failed"
    "#{image.analysis_status}:#{reason}"
  end

  # 画像の要確認・失敗の理由の名前。除外した画像にも使う（除外しても review_reason と位置合わせの記録は残る）
  def self.reason_label(image)
    reason = image.review_reason.presence
    return "理由の記録なし" if reason.nil?
    # 解析エンジンのメッセージは画像ごとに違う（ファイル名など）ので使わない
    return "位置合わせ不可（#{ALIGNMENT_REASONS.fetch(image.alignment.to_h['review_reason'].to_s) { "その他: #{image.alignment.to_h['review_reason']}" }}）" if reason == "alignment_failed"

    check = Array(image.quality_report&.dig("checks")).find { |c| c["key"] == reason && c["result"] == "rejected" }
    check&.dig("message") || InspectionsHelper::REVIEW_REASON_MESSAGES[reason] || image.error_message.presence || reason
  end

  def group(key)
    groups.find { |g| g.key == key } or raise Error, "まとめて除外できる画像がありません（すでに状態が変わった可能性があります）"
  end

  def preview(key)
    g = group(key)
    [ g, InspectionCoverage.new(@inspection).exclusion_impact(g.images) ]
  end

  # image_ids: 確認画面で表示した画像。その後に状態が変わった画像は除外しない
  def exclude!(key, image_ids:, note: nil)
    @inspection.with_lock do
      g = group(key)
      images = g.images.select { |img| image_ids.map(&:to_i).include?(img.id) }
      raise Error, "除外する画像がありません（確認画面のあとに状態が変わった可能性があります）" if images.empty?

      memo = [ "まとめて除外: #{g.label}", note.to_s.strip.presence ].compact.join("／")
      InspectionImage.transaction do
        images.each { |img| img.update!(analysis_status: "excluded", exclusion_note: memo) }
      end
      @inspection.refresh_status!
      images.size
    end
  end
end
