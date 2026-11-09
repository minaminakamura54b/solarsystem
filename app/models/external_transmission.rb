# 外部のサービスに送った内容の記録（点検ごと。2026-11-09 ユーザー指示）。いつ・何を（目的・対象・送った入力）・結果。
# 記録は ClaudeStructuredOutput#request が送る前に作り、結果で更新する。消さない
class ExternalTransmission < ApplicationRecord
  PURPOSES = { "anomaly_explanation" => "異常の所見", "inspection_summary" => "点検の総括文" }.freeze
  SERVICES = { "anthropic" => "Anthropic（Claude）" }.freeze
  STATUSES = { "sending" => "送信中", "sent" => "送信済み（応答あり）", "failed" => "失敗" }.freeze

  belongs_to :inspection
  belongs_to :target, polymorphic: true, optional: true

  validates :service, inclusion: { in: SERVICES.keys }
  validates :purpose, inclusion: { in: PURPOSES.keys }
  validates :status, inclusion: { in: STATUSES.keys }
  validates :input_text, :sent_at, presence: true

  before_destroy(prepend: true) { throw :abort }

  scope :recent_first, -> { order(sent_at: :desc, id: :desc) }

  def purpose_label = PURPOSES.fetch(purpose, purpose)
  def status_label = STATUSES.fetch(status, status)

  def target_label
    case target
    when Anomaly then "画像 #{target.inspection_image.sequence} の#{RuleSetsHelper::ANOMALY_TYPE_LABELS.fetch(target.effective_type, target.effective_type)}（パネル #{target.panel&.number || '未割り当て'}）"
    when AnomalyGroup then "画像 #{target.inspection_image.sequence} の隣接パネル群（#{target.panel_count} 枚）"
    else "点検全体"
    end
  end
end
