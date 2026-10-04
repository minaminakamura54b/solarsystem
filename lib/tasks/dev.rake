namespace :dev do
  desc "開発用: 合成シーン（.npy）の点検を登録する（開発環境だけ）。SITE_ID を省略すると最初の発電所"
  task synthetic_inspection: :environment do
    abort "このタスクは開発環境でだけ使えます（RAILS_ENV=development）" unless Rails.env.development?
    abort ".npy の登録が無効です（config/analyzer.yml の allow_npy_thermal）" unless AnalyzerConfig.current.allow_npy_thermal?

    site = ENV["SITE_ID"].present? ? Site.find(ENV["SITE_ID"]) : Site.first
    abort "発電所がありません（bin/rails db:seed）" unless site
    abort "判定基準（ルールセット）がありません（bin/rails db:seed）" unless RuleSet.active_set

    out = Rails.root.join("tmp", "dev_scenes")
    analyzer = AnalyzerConfig.current
    ok = system(*analyzer.command.first(analyzer.command.index("python") + 1), "scripts/make_dev_scenes.py", "--out", out.to_s,
                chdir: analyzer.working_dir)
    abort "合成シーンを作れませんでした（analyzer/ で uv sync を実行してください）" unless ok

    scenes = JSON.parse(File.read(out.join("scenes.json")))
    zone = ImageQualityConfig.current.capture_time_zone
    started = zone.now.change(sec: 0)
    inspection = site.inspections.build(conducted_at: started, weather_note: "開発用の合成データ（実画像ではありません）")
    scenes.each_with_index do |scene, i|
      image = inspection.inspection_images.build(sequence: i + 1, thermal_filename: "#{scene['name']}.npy")
      image.thermal.attach(io: File.open(out.join("#{scene['name']}.npy")), filename: "#{scene['name']}.npy", content_type: "application/octet-stream")
      image.preview.attach(io: File.open(out.join("#{scene['name']}.png")), filename: "#{scene['name']}.png", content_type: "image/png")
    end
    inspection.save!
    inspection.weather_readings.create!(observed_at: started, irradiance_w_m2: 800, irradiance_type: "poa", air_temp_c: 25)

    # .npy はメタデータ（EXIF）を持たないので、シーンの情報を設定してから品質チェックする
    inspection.inspection_images.each do |image|
      scene = scenes[image.sequence - 1]
      image.assign_attributes(
        captured_at: started + scene["captured_at_offset_s"].seconds, camera_model: "合成データ（開発用）",
        width: scene["width"], height: scene["height"], is_radiometric: true,
        gps_lat: scene["gps_lat"], gps_lng: scene["gps_lng"], altitude_m: scene["altitude_m"],
        gimbal_pitch: scene["gimbal_pitch"], gimbal_yaw: scene["gimbal_yaw"],
        metadata: { "description" => scene["description"], "synthetic" => true }
      )
      InspectionImageQuality.apply(image)
      image.save!
      InspectionImagePipeline.after_quality(image)
    end
    inspection.refresh_status!

    puts "合成シーンの点検を登録しました（#{scenes.size}枚、発電所: #{site.name}）"
    scenes.each { |s| puts "  #{s['name']}: #{s['description']}" }
    puts "点検: http://localhost:3000/inspections/#{inspection.id}?site_id=#{site.id}"
    puts "グリッドを指定すると解析します（画像 1〜3 は同じ配列なので、テンプレートの一括適用を試せます）"
  end
end
