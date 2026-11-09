# 報告書の「発電所の様子」のサーモ画像（docs/IMPROVEMENT_PLAN.md 見直し R4。2026-11-09 ユーザー承認）。
# - 候補: 解析できた（completed）・表示できる・異常（却下したもの以外）の無い画像。対象範囲を確定していれば、
#   対象範囲の架台が写った画像だけ（位置合わせのグリッドで判断する）
# - 自動の提案: 品質チェックに問題のない（ok）画像から、撮影位置（GPS）で散らばるように選ぶ（離れた所から順に。
#   同じくらいの距離なら写っている架台の多い画像）。ok の画像が足りなければ、注意（warning）の画像からも選ぶ。
#   GPS の無い画像しか無ければ、撮影の順に等間隔で選ぶ
# - 人が発行の画面で差し替えたら、その画像を使う（inspections.report_overview_image_ids。NULL = 自動の提案）。
#   差し替えた画像が後で候補から外れたら（除外・異常など）、報告書には載せない
# - 判定には関係しない（見せるための画像の選び方だけ）
class ReportOverview
  class Error < StandardError; end

  COLUMNS = %i[id inspection_id sequence captured_at gps_lat gps_lng quality_report panel_grids analysis_status].freeze

  Candidate = Data.define(:image, :block_ids, :blocks, :quality_ok) do
    def id = image.id
    def gps = image.gps_lat && image.gps_lng ? [ image.gps_lat.to_f, image.gps_lng.to_f ] : nil
  end

  def initialize(inspection, config: ReportConfig.current)
    @inspection = inspection
    @site = inspection.site
    @limit = config.overview_images
    @tolerance = config.overview_distance_tolerance
  end

  attr_reader :limit

  def manual? = !@inspection.report_overview_image_ids.nil?

  # 候補（撮影の順）
  def candidates
    @candidates ||= begin
      with_anomaly = @inspection.anomalies.where.not(review_status: "rejected").distinct.pluck(:inspection_image_id).to_set
      scope = @inspection.scope_confirmed? ? Array(@inspection.scope_block_ids).map(&:to_i).to_set : nil
      labels = @site.pv_blocks.pluck(:id, :label).to_h
      # 解析の生データ（raw_analysis）などの大きい列は読まない
      @inspection.inspection_images.where(analysis_status: "completed").select(*COLUMNS).with_attached_preview.with_attached_thermal
                 .order(:sequence).filter_map do |img|
        next if with_anomaly.include?(img.id) || !img.displayable?

        ids = GridGeometry.touched_block_ids(GridGeometry.layout_grids(img.panel_grids))
        ids &= scope.to_a if scope
        next if scope && ids.empty?

        Candidate.new(image: img, block_ids: ids, blocks: InspectionScope.compress(ids.filter_map { |id| labels[id] }),
                      quality_ok: img.quality_status == "ok")
      end
    end
  end

  # 自動の提案（候補の id。選んだ順）
  def proposal
    @proposal ||= begin
      ok = candidates.select(&:quality_ok)
      picked = pick(ok, @limit)
      picked += pick(candidates.reject(&:quality_ok), @limit - picked.size, picked) if picked.size < @limit
      picked.map(&:id)
    end
  end

  # 報告書に載せる画像の id（差し替えていれば人が選んだもののうち、今も候補のもの）
  def selected_ids
    return proposal unless manual?

    allowed = candidates.map(&:id).to_set
    Array(@inspection.report_overview_image_ids).map(&:to_i).select { |id| allowed.include?(id) }.first(@limit)
  end

  # 固定コピーに入れる内容
  def entries
    by_id = candidates.index_by(&:id)
    selected_ids.filter_map do |id|
      c = by_id[id]
      { "id" => id, "sequence" => c.image.sequence, "captured_at" => c.image.captured_at&.iso8601, "blocks" => c.blocks.presence }
    end
  end

  def candidate(id) = candidates.find { |c| c.id == id.to_i }

  # 人が選ぶ（候補の画像だけ・上限まで）
  def select!(ids)
    ids = Array(ids).map(&:to_i).uniq
    raise Error, "載せられるのは #{@limit} 枚までです" if ids.size > @limit

    allowed = candidates.map(&:id).to_set
    raise Error, "候補ではない画像は選べません" unless ids.all? { |id| allowed.include?(id) }

    @inspection.update_columns(report_overview_image_ids: ids, updated_at: Time.current)
  end

  def add!(id) = select!(selected_ids + [ id.to_i ])
  def remove!(id) = select!(selected_ids - [ id.to_i ])

  # 自動の提案に戻す
  def reset!
    @inspection.update_columns(report_overview_image_ids: nil, updated_at: Time.current)
  end

  private

  # 撮影位置で散らばるように count 枚選ぶ（chosen は先に選んだもの）
  def pick(pool, count, chosen = [])
    return [] if count <= 0 || pool.empty?

    with_gps, without = pool.partition(&:gps)
    picked = []
    if with_gps.any?
      points = chosen.filter_map(&:gps)
      center = centroid(with_gps)
      remaining = with_gps.dup
      while picked.size < count && remaining.any?
        # 1 枚目は全体の中心から最も離れた画像、2 枚目からは選んだ画像から最も離れた画像
        distances = remaining.to_h do |c|
          [ c, points.empty? ? distance(c.gps, center) : points.map { |p| distance(c.gps, p) }.min ]
        end
        best = distances.values.max
        near = distances.select { |_, d| d >= best * (1 - @tolerance) }
        choice = near.max_by { |c, d| [ c.block_ids.size, d, -c.image.sequence ] }.first
        picked << choice
        points << choice.gps
        remaining.delete(choice)
      end
    end
    picked + evenly(without, count - picked.size)
  end

  def evenly(pool, count)
    return [] if count <= 0 || pool.empty?
    return pool if pool.size <= count

    (0...count).map { |i| pool[(i * (pool.size - 1).to_f / [ count - 1, 1 ].max).round] }.uniq
  end

  def centroid(list)
    [ list.sum { |c| c.gps[0] } / list.size, list.sum { |c| c.gps[1] } / list.size ]
  end

  # 2 点の距離（m）。発電所の広さなら平面で近似してよい
  def distance(a, b)
    lat = (a[0] + b[0]) / 2 * Math::PI / 180
    dy = (a[0] - b[0]) * 111_320
    dx = (a[1] - b[1]) * 111_320 * Math.cos(lat)
    Math.hypot(dx, dy)
  end
end
