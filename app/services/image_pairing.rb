# アップロードされたファイルを、ファイル名の _T（サーモ）/ _V（RGB）でペアにする。
# - 例: DJI_0001_T.JPG と DJI_0001_V.JPG → 1組。末尾に _T / _V が無いファイルはサーモ画像として扱う
# - DJI の名前（DJI_<撮影時刻 14 桁>_<番号>_T）は、番号が同じで撮影時刻の差が設定の秒数以内なら組にする。
#   サーモと RGB で名前の時刻が 1 秒ずれることがあるため（実データで 17%。2026-11-06 ユーザー指示）。
#   番号が同じでも差が設定を超えるものは組にせず mismatched_rgb に入れる（別の飛行の同じ番号を取り違えないため）
# - 名前の末尾が「 (2)」などの複製と思われるファイルは、サーモ・RGB とも登録せず duplicates に入れる
# 対になるサーモ画像が無い RGB は unpaired_rgb に入れる（保存しない。後から画像ごとに手動で添付できる）。
# mismatched_rgb は unpaired_rgb の一部（時刻のずれで組にしなかったもの）
class ImagePairing
  Pair = Data.define(:key, :thermal, :rgb)
  Result = Data.define(:pairs, :unpaired_rgb, :mismatched_rgb, :duplicates)
  Entry = Data.define(:file, :stem, :dji_key, :time)

  SUFFIX = /\A(.+)_([TV])\z/i
  DUPLICATE = /\s\(\d+\)\z/
  DJI_STEM = /\A(.+)_(\d{14})_(\d+)\z/

  # files: filename メソッドを持つもの（ActiveStorage::Blob）の配列
  def self.pair(files, max_gap_seconds: ImageQualityConfig.current.pairing_max_time_gap_seconds)
    new(max_gap_seconds).pair(files)
  end

  def self.natural_key(name)
    name.scan(/\d+|\D+/).map { |part| part.match?(/\A\d+\z/) ? [ 0, part.to_i ] : [ 1, part ] }
  end

  def initialize(max_gap_seconds)
    @max_gap = max_gap_seconds
  end

  def pair(files)
    thermals = []
    rgbs = []
    duplicates = []
    files.each do |file|
      base = File.basename(file.filename.to_s, ".*")
      next duplicates << file if base.match?(DUPLICATE)

      m = base.match(SUFFIX)
      kind = m ? m[2].upcase : "T"
      (kind == "T" ? thermals : rgbs) << entry(file, m ? m[1] : base)
    end

    matched = match(thermals, rgbs)
    pairs = thermals.sort_by { |t| self.class.natural_key(t.stem) }
                    .map { |t| Pair.new(key: t.stem, thermal: t.file, rgb: matched[t]&.file) }
    paired_rgbs = matched.values.to_set
    unpaired = rgbs.reject { |v| paired_rgbs.include?(v) }
    thermal_keys = thermals.filter_map(&:dji_key).to_set
    mismatched = unpaired.select { |v| v.dji_key && thermal_keys.include?(v.dji_key) }
    Result.new(pairs: pairs, unpaired_rgb: unpaired.map(&:file), mismatched_rgb: mismatched.map(&:file), duplicates: duplicates)
  end

  private

  def entry(file, stem)
    stem = stem.downcase
    m = stem.match(DJI_STEM)
    time = m && dji_time(m[2])
    Entry.new(file: file, stem: stem, dji_key: time && [ m[1], m[3].to_i ], time: time)
  end

  # 名前の撮影時刻（14 桁）。差を求めるだけなのでタイムゾーンは問わない。日時として不正なら nil
  def dji_time(digits)
    Time.utc(digits[0, 4].to_i, digits[4, 2].to_i, digits[6, 2].to_i, digits[8, 2].to_i, digits[10, 2].to_i, digits[12, 2].to_i)
  rescue ArgumentError
    nil
  end

  # 名前（_T / _V を除く）が同じもの、または DJI の名前で番号が同じく時刻の差が設定以内のものを、差の小さい順に 1 対 1 で組にする
  def match(thermals, rgbs)
    by_stem = rgbs.group_by(&:stem)
    by_dji = rgbs.select(&:dji_key).group_by(&:dji_key)
    candidates = thermals.flat_map do |t|
      exact = by_stem.fetch(t.stem, []).map { |v| [ 0, t, v ] }
      near = by_dji.fetch(t.dji_key, []).filter_map do |v|
        gap = (v.time - t.time).abs
        [ gap, t, v ] if gap <= @max_gap && v.stem != t.stem
      end
      exact + near
    end

    matched = {}
    used = Set.new
    candidates.sort_by { |gap, t, v| [ gap, self.class.natural_key(t.stem), self.class.natural_key(v.stem) ] }.each do |_, t, v|
      next if matched.key?(t) || used.include?(v)

      matched[t] = v
      used << v
    end
    matched
  end
end
