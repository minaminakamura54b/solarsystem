# config/panel_candidates.yml の読み込み
class PanelCandidateConfig
  attr_reader :version, :point_merge_distance, :flags

  def self.current
    new(Rails.application.config_for(:panel_candidates))
  end

  def initialize(values)
    values = values.to_h.with_indifferent_access
    @version = values.fetch(:version).to_s
    @point_merge_distance = values.fetch(:point_merge_distance).to_f
    @flags = values.fetch(:flags).to_h.transform_keys(&:to_s)
  end
end
