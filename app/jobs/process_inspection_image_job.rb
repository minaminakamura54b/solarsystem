# 画像1枚のメタデータ読み取り → 気象データの割り当て → 品質チェック。
# 品質チェックに合格した画像は pending のまま解析エンジン（Phase 4 で接続）を待つ。
# 不合格は needs_review（理由付き）、処理の失敗は failed。どちらも正常扱いにはしない
class ProcessInspectionImageJob < ApplicationJob
  queue_as :default

  class << self
    # テストで偽の読み取りクラスに差し替えるためのフック。本番では常に ExifReader
    attr_writer :exif_reader

    def exif_reader
      @exif_reader || ExifReader
    end
  end

  def perform(image_id)
    image = InspectionImage.find_by(id: image_id)
    return unless image
    return if image.excluded?

    tags_result = image.thermal.open { |file| self.class.exif_reader.read(file.path) }
    image.assign_attributes(ImageMetadataExtractor.new(tags_result.tags).attributes) if tags_result.ok?
    image.is_radiometric = nil unless tags_result.ok? # 読めなかったときは「判定できない」

    InspectionImageQuality.apply(image)
    image.save!
    InspectionImagePipeline.after_quality(image)
    image.inspection.refresh_status!
  rescue => e
    Rails.logger.error("ProcessInspectionImageJob failed: #{e.class}: #{e.message}")
    return unless image

    image.update_columns(analysis_status: "failed", error_message: "画像の処理中にエラーが発生しました: #{e.message}", updated_at: Time.current)
    image.inspection.refresh_status!
  end
end
