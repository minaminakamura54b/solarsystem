# exiftool のタグから InspectionImage の属性を取り出す。
# 温度データの有無（is_radiometric）は、設定したタグの有無による「仮判定」。最終判定は Phase 3 の解析エンジンで行う
class ImageMetadataExtractor
  KEPT_TAGS = %w[
    Make Model DateTimeOriginal OffsetTimeOriginal ImageWidth ImageHeight
    GPSLatitude GPSLongitude GPSLatitudeRef GPSLongitudeRef GPSAltitude
    RelativeAltitude AbsoluteAltitude GimbalPitchDegree GimbalYawDegree GimbalRollDegree
  ].freeze

  def initialize(tags, config: ImageQualityConfig.current)
    @tags = tags
    @config = config
  end

  def attributes
    {
      camera_model: camera_model,
      captured_at: captured_at,
      width: integer(@tags["ImageWidth"]),
      height: integer(@tags["ImageHeight"]),
      gps_lat: signed_coordinate(@tags["GPSLatitude"], @tags["GPSLatitudeRef"], "S"),
      gps_lng: signed_coordinate(@tags["GPSLongitude"], @tags["GPSLongitudeRef"], "W"),
      altitude_m: decimal(@tags["RelativeAltitude"] || @tags["GPSAltitude"]),
      gimbal_pitch: decimal(@tags["GimbalPitchDegree"]),
      gimbal_yaw: decimal(@tags["GimbalYawDegree"]),
      is_radiometric: radiometric_tags_found.any?,
      metadata: @tags.slice(*KEPT_TAGS).merge("radiometric_tags_found" => radiometric_tags_found)
    }
  end

  private

  def camera_model
    [ @tags["Make"], @tags["Model"] ].compact.map(&:to_s).map(&:strip).reject(&:empty?).uniq.join(" ").presence
  end

  # EXIF の撮影時刻はタイムゾーンを持たないので、OffsetTimeOriginal があればそれを、無ければ設定のタイムゾーンを使う
  def captured_at
    raw = @tags["DateTimeOriginal"].to_s
    match = raw.match(/\A(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/)
    return nil unless match

    iso = "#{match[1]}-#{match[2]}-#{match[3]}T#{match[4]}:#{match[5]}:#{match[6]}"
    offset = @tags["OffsetTimeOriginal"].to_s
    if offset.match?(/\A[+-]\d{2}:\d{2}\z/)
      Time.iso8601("#{iso}#{offset}")
    else
      @config.capture_time_zone.parse(iso)
    end
  rescue ArgumentError
    nil
  end

  def radiometric_tags_found
    @radiometric_tags_found ||= @config.radiometric_tags & @tags.keys
  end

  def signed_coordinate(value, ref, negative_ref)
    number = decimal(value)
    return nil if number.nil?

    number.positive? && ref.to_s.upcase.start_with?(negative_ref) ? -number : number
  end

  def integer(value)
    Integer(value, exception: false)
  end

  def decimal(value)
    return nil if value.nil? || value.to_s.strip.empty?

    BigDecimal(value.to_s, exception: false)
  end
end
