# アップロードされたファイルを、ファイル名の _T（サーモ）/ _V（RGB）でペアにする。
# 例: DJI_0001_T.JPG と DJI_0001_V.JPG → 1組。末尾に _T / _V が無いファイルはサーモ画像として扱う。
# 対になるサーモ画像が無い RGB は unpaired_rgb に入れる（保存しない。後から画像ごとに手動で添付できる）
class ImagePairing
  Pair = Data.define(:key, :thermal, :rgb)
  Result = Data.define(:pairs, :unpaired_rgb)

  # files: filename メソッドを持つもの（ActiveStorage::Blob）の配列
  def self.pair(files)
    thermals = {}
    rgbs = {}
    files.each do |file|
      base = File.basename(file.filename.to_s, ".*")
      if (m = base.match(/\A(.+)_([TV])\z/i))
        (m[2].casecmp?("T") ? thermals : rgbs)[m[1].downcase] = file
      else
        thermals[base.downcase] = file
      end
    end

    keys = thermals.keys.sort_by { |k| natural_key(k) }
    pairs = keys.map { |key| Pair.new(key: key, thermal: thermals[key], rgb: rgbs[key]) }
    unpaired = rgbs.reject { |key, _| thermals.key?(key) }.values
    Result.new(pairs: pairs, unpaired_rgb: unpaired)
  end

  def self.natural_key(name)
    name.scan(/\d+|\D+/).map { |part| part.match?(/\A\d+\z/) ? [ 0, part.to_i ] : [ 1, part ] }
  end
end
