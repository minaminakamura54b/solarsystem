# config/row_effect.yml の読み込み
class RowEffectConfig
  attr_reader :version, :model, :row

  def self.current
    new(Rails.application.config_for(:row_effect))
  end

  def initialize(values)
    values = values.to_h.with_indifferent_access
    @version = values.fetch(:version).to_s
    @model = values.fetch(:model).to_h.transform_keys(&:to_s)
    @row = values.fetch(:row).to_h.transform_keys(&:to_s)
  end
end
