# 点検の画像から架台の地図の候補を作る（docs/LAYOUT_OVERLAY_DESIGN.md の A-3）。
# 位置合わせに使える画像（georef の usable）だけを使う。作れなければ needs_review（理由付き）、処理の失敗は failed。
# 候補は自動では使わない（人が確認して架台の CSV として登録する）。パネル・Site の状態は変えない
class BuildBlockMapJob < ApplicationJob
  queue_as :default

  def perform(proposal_id)
    proposal = BlockMapProposal.find_by(id: proposal_id)
    return unless proposal&.in_progress?

    images = proposal.inspection.inspection_images.where.not(analysis_status: "excluded").select { |i| i.georef&.dig("usable") && i.thermal.attached? }
    proposal.update!(status: "running", image_count: images.size, message: nil)
    if images.empty?
      return proposal.update!(status: "needs_review", message: "位置合わせに使える画像（RTK 固定解・真下向き）がありません")
    end

    result = Dir.mktmpdir("block_map", AnalyzerConfig.current.tmp_parent) do |dir|
      input = build_input(proposal, images, dir)
      AnalyzeInspectionImageJob.client.build_block_map(input:, dir:)
    end
    if result.output.nil?
      proposal.update!(status: "failed", message: result.message || "解析エンジンの出力を読めませんでした")
    elsif result.ok?
      proposal.update!(status: "proposed", result: result.output, message: nil)
    else
      proposal.update!(status: result.status == "needs_review" ? "needs_review" : "failed", result: result.output, message: result.message)
    end
  rescue => e
    Rails.logger.error("BuildBlockMapJob failed: #{e.class}: #{e.message}")
    proposal&.update_columns(status: "failed", message: "架台の地図の候補を作れませんでした: #{e.message}", updated_at: Time.current)
  end

  private

  def build_input(proposal, images, dir)
    site = proposal.site
    origin = if site.geo_origin_lat && site.geo_origin_lng
      { lat: site.geo_origin_lat.to_f, lng: site.geo_origin_lng.to_f }
    else
      { lat: images.map { |i| i.georef.dig("camera", "lat") }.min, lng: images.map { |i| i.georef.dig("camera", "lng") }.min }
    end
    {
      origin:,
      facing_azimuth_deg: proposal.params.fetch("facing_azimuth_deg", 180).to_f,
      module: { width_m: proposal.params["module_width_m"].to_f, length_m: proposal.params["module_length_m"].to_f },
      images: images.map do |image|
        path = File.join(dir, "#{image.id}#{image.thermal.filename.extension_with_delimiter}")
        File.open(path, "wb") { |f| image.thermal.download { |chunk| f.write(chunk) } }
        camera = image.georef["camera"]
        { id: image.id.to_s, thermal: path, lrf_target_abs_alt_m: image.georef.dig("lrf", "target_abs_alt_m"),
          camera: camera.slice("lat", "lng", "abs_alt_m", "image_up_azimuth_deg", "ifov_mrad", "width", "height") }
      end
    }
  end
end
