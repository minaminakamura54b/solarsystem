namespace :dataset do
  desc "確定・修正済みの異常を YOLO 形式で書き出す: bin/rails \"dataset:export[OUT_DIR]\"（SITE_ID で発電所を絞り込める）"
  task :export, [ :out_dir ] => :environment do |_, args|
    out = args[:out_dir].presence or abort "書き出し先を指定してください: bin/rails \"dataset:export[/path/to/out]\""
    out_path = Pathname(out).expand_path
    root = Rails.root.expand_path
    # 顧客の画像を含むため、リポジトリの中（tmp/ 以外）には書き出さない（誤ってコミットしないように）
    if out_path.to_s.start_with?("#{root}/") && !out_path.to_s.start_with?("#{root.join('tmp')}/")
      abort "リポジトリの中（tmp/ 以外）には書き出せません。顧客の画像を含むため、リポジトリの外か tmp/ を指定してください"
    end

    inspections = ENV["SITE_ID"].present? ? Inspection.where(site_id: ENV["SITE_ID"]) : Inspection.all
    result = DatasetExporter.new(out_path, inspections: inspections).export!
    puts "#{out_path} に書き出しました: 画像 #{result.images} 枚（うち負例 #{result.negatives} 枚）、ラベル #{result.labels} 件"
    puts "未確定の候補が残っているため含めなかった画像: #{result.skipped_pending} 枚" if result.skipped_pending.positive?
    puts "表示できる画像が無いため含めなかった画像: #{result.skipped_undisplayable} 枚" if result.skipped_undisplayable.positive?
    puts "注意: 顧客の画像を含みます。リポジトリにコミットしないでください"
  end
end
