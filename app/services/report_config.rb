# config/report.yml の読み込み（報告書の屋号など）
class ReportConfig
  attr_reader :business_name, :max_other_observations

  def self.current
    new(Rails.application.config_for(:report))
  end

  def initialize(values)
    values = values.to_h.with_indifferent_access
    @business_name = values.fetch(:business_name).to_s
    @max_other_observations = values.fetch(:max_other_observations).to_i
  end
end
