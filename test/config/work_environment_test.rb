require "test_helper"

# 実案件用（RAILS_ENV=work。docs/LOCAL_OPERATION.md）の設定がそろっているか。
# 環境ごとの節を持つ設定ファイルに work が無いと、bin/local で起動したときに読み込めない
class WorkEnvironmentTest < ActiveSupport::TestCase
  def yaml(name) = YAML.load(ERB.new(Rails.root.join("config/#{name}.yml").read).result, aliases: true)

  test "環境ごとの節を持つ設定ファイルに work の節がある" do
    %w[database queue cable recurring analyzer].each do |name|
      assert yaml(name).key?("work"), "config/#{name}.yml に work が無い"
    end
    assert File.exist?(Rails.root.join("config/environments/work.rb"))
  end

  test "実案件用のデータベースは開発用と別で、キューも別のデータベース" do
    work = yaml("database")["work"]
    assert_equal "solarsystem_work", work.dig("primary", "database")
    assert_equal "solarsystem_work_queue", work.dig("queue", "database")
    assert_operator work.dig("queue", "pool"), :>=, 6, "Solid Queue のスレッドより接続が少ないと起動しない"
  end

  test "実案件用の画像・開発用の画像はリポジトリの外に置く" do
    storage = yaml("storage")
    [ storage.dig("work_data", "root"), storage.dig("local", "root") ].each do |root|
      assert_not root.to_s.start_with?(Rails.root.to_s), "#{root} がリポジトリの中"
    end
    assert_match %r{SolarSightData/storage\z}, storage.dig("work_data", "root")
  end

  test "実案件用の解析は Docker で動かし、一時ファイルはリポジトリの外。合成データは既定で受け付けない" do
    work = yaml("analyzer")["work"]
    assert_match %r{bin/analyzer-docker\z}, work["command"].first
    assert_not work["work_dir"].start_with?(Rails.root.to_s)
    assert_equal false, work["allow_npy_thermal"]
  end
end
