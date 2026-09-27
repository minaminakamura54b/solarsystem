# 点検の気象データ（時刻付き）を、画像の撮影時刻で補間して割り当てる。
# 前後の観測値が両方あれば線形補間、片方だけなら近い方の値。撮影時刻から設定の分数を超えて離れた観測値は使わない
class WeatherInterpolator
  NUMERIC_FIELDS = %i[irradiance_w_m2 wind_speed_m_s air_temp_c humidity].freeze

  def initialize(readings, config: ImageQualityConfig.current)
    @readings = readings.sort_by(&:observed_at)
    @max_gap = config.weather_max_gap_minutes.minutes
  end

  # 画像に割り当てる属性（撮影時刻が無ければ全部 nil）
  def attributes_for(captured_at)
    blank = NUMERIC_FIELDS.index_with(nil).merge(irradiance_type: nil)
    return blank if captured_at.nil?

    values = NUMERIC_FIELDS.index_with { |field| interpolate(field, captured_at)&.first }
    irradiance = interpolate(:irradiance_w_m2, captured_at)
    values.merge(irradiance_type: irradiance && irradiance_type_of(irradiance.last))
  end

  private

  # [値, 使った観測値の配列] を返す
  def interpolate(field, time)
    usable = @readings.select { |r| !r.public_send(field).nil? && (r.observed_at - time).abs <= @max_gap }
    before = usable.select { |r| r.observed_at <= time }.last
    after = usable.find { |r| r.observed_at >= time }

    if before && after && before != after
      span = after.observed_at - before.observed_at
      ratio = (time - before.observed_at) / span
      a = before.public_send(field)
      b = after.public_send(field)
      [ (a + (b - a) * ratio).round(2), [ before, after ] ]
    elsif (nearest = before || after)
      [ nearest.public_send(field), [ nearest ] ]
    end
  end

  # 補間に使った観測値の日射量の種類がそろっていればその種類、食い違えば unknown
  def irradiance_type_of(readings)
    types = readings.map(&:irradiance_type).uniq
    types.size == 1 ? types.first : "unknown"
  end
end
