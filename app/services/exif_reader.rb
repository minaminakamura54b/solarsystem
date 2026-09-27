require "open3"

# exiftool で画像のメタデータ（EXIF / XMP / メーカー独自タグ）を読む。gem は使わずコマンドを呼ぶ
class ExifReader
  Result = Data.define(:tags, :error) do
    def ok? = error.nil?
  end

  def self.read(path)
    new.read(path)
  end

  def read(path)
    stdout, stderr, status = Open3.capture3("exiftool", "-json", "-n", "-a", path.to_s)
    return Result.new(tags: {}, error: "exiftool の実行に失敗しました: #{stderr.strip.presence || status}") unless status.success?

    tags = JSON.parse(stdout).first || {}
    Result.new(tags: tags, error: nil)
  rescue Errno::ENOENT
    Result.new(tags: {}, error: "exiftool が見つかりません（インストールしてください）")
  rescue JSON::ParserError => e
    Result.new(tags: {}, error: "exiftool の出力を読めませんでした: #{e.message}")
  end
end
