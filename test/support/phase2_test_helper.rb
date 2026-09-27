# Phase 2（複数画像の点検・品質チェック）のテスト用ヘルパー
module Phase2TestHelper
  # exiftool を呼ばずに、決まったタグを返す偽の読み取りクラス
  class FakeExifReader
    def initialize(tags: {}, error: nil)
      @tags = tags
      @error = error
    end

    def read(_path)
      ExifReader::Result.new(tags: @error ? {} : @tags, error: @error)
    end
  end

  # ブロック内だけ ProcessInspectionImageJob が偽の読み取りクラスを使う
  def with_fake_exif(tags: {}, error: nil)
    previous = ProcessInspectionImageJob.instance_variable_get(:@exif_reader)
    ProcessInspectionImageJob.exif_reader = FakeExifReader.new(tags: tags, error: error)
    yield
  ensure
    ProcessInspectionImageJob.exif_reader = previous
  end

  # DJI の R-JPEG を想定したタグ（温度データあり）
  def dji_thermal_tags(**overrides)
    {
      "Make" => "DJI", "Model" => "M3T", "DateTimeOriginal" => "2026:09:20 10:15:30",
      "ImageWidth" => 640, "ImageHeight" => 512,
      "GPSLatitude" => 35.6625, "GPSLongitude" => 138.5683, "RelativeAltitude" => 30.1,
      "GimbalPitchDegree" => -90.0, "GimbalYawDegree" => 12.5,
      "ThermalData" => "(Binary data 655360 bytes, use -b option to extract)",
      "Emissivity" => 0.95
    }.merge(overrides.stringify_keys)
  end

  # 新方式の点検（画像を files の数だけ持つ）を作る。files はテスト用ファイル名
  def create_session_inspection(site: sites(:south), files: [ "thermal_plain_T.jpg" ], conducted_at: Time.zone.parse("2026-09-20 01:00:00"))
    inspection = site.inspections.build(conducted_at: conducted_at)
    files.each_with_index do |name, i|
      image = inspection.inspection_images.build(sequence: i + 1, thermal_filename: name)
      image.thermal.attach(io: file_fixture(name).open, filename: name, content_type: "image/jpeg")
    end
    inspection.save!
    inspection
  end

  def jst(string)
    ActiveSupport::TimeZone["Asia/Tokyo"].parse(string)
  end

  def load_initial_rule_set
    capture_io { load Rails.root.join("db/seeds/rule_sets.rb") }
    RuleSet.find_by!(version: "2026-09-initial")
  end
end
