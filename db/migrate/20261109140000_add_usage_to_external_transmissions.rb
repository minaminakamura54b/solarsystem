# 外部のサービスに送った記録に、応答のトークン数を残す（実際にかかった費用を出すため。2026-11-09 ユーザー指示）
class AddUsageToExternalTransmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :external_transmissions, :input_tokens, :integer
    add_column :external_transmissions, :output_tokens, :integer
    add_column :external_transmissions, :cache_creation_input_tokens, :integer
    add_column :external_transmissions, :cache_read_input_tokens, :integer
  end
end
