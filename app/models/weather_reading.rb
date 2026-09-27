# 点検中の気象の観測値（時刻付き）。画像の撮影時刻で補間して画像に割り当てる
class WeatherReading < ApplicationRecord
  IRRADIANCE_TYPES = %w[poa ghi unknown].freeze

  belongs_to :inspection

  validates :observed_at, presence: true
  validates :irradiance_type, inclusion: { in: IRRADIANCE_TYPES }, allow_nil: true
  validates :irradiance_type, presence: { message: "（POA / GHI）を選んでください" }, if: -> { irradiance_w_m2.present? }
  validates :irradiance_w_m2, :wind_speed_m_s, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :humidity, numericality: { in: 0..100 }, allow_nil: true
  validate :has_some_value

  scope :chronological, -> { order(:observed_at) }

  private

  def has_some_value
    return if [ irradiance_w_m2, wind_speed_m_s, air_temp_c, humidity ].any?(&:present?)

    errors.add(:base, "日射量・風速・気温・湿度のいずれかを入力してください")
  end
end
