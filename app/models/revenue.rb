class Revenue < ApplicationRecord
  belongs_to :site

  validates :year, presence: true, numericality: { greater_than: 2000, less_than: 2100 }
  validates :month, presence: true, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 12 }
  validates :amount_yen, numericality: { greater_than_or_equal_to: 0 }
  validates :kwh, numericality: { greater_than_or_equal_to: 0 }
  validates :month, uniqueness: { scope: [ :site_id, :year ] }

  scope :chronological, -> { order(:year, :month) }
  scope :for_year, ->(year) { where(year: year) }

  def month_label
    "#{year}年#{month}月"
  end

  def unit_price
    return 0 if kwh.zero?
    (amount_yen / kwh).round(1)
  end
end