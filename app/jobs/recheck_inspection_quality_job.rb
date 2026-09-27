# 気象データを変更したときに、点検の全画像へ気象データを割り当て直し、品質チェックをやり直す。
# メタデータは読み直さない。除外済み・メタデータ未読み取りの画像は対象外
class RecheckInspectionQualityJob < ApplicationJob
  queue_as :default

  def perform(inspection_id)
    inspection = Inspection.find_by(id: inspection_id)
    return unless inspection

    inspection.inspection_images.each do |image|
      next if image.excluded? || image.quality_report.nil? || image.failed?

      InspectionImageQuality.apply(image)
      image.save!
    end
    inspection.refresh_status!
  end
end
