# 外部のサービスに送ったときに使った API キーの指紋（キーの SHA-256 の先頭 8 文字。キーそのものは残さない）。
# 意図しないキーで送っていないかを後から確かめるため（2026-11-09 ユーザー承認の修正案 12・案 A）
class AddKeyFingerprintToExternalTransmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :external_transmissions, :key_fingerprint, :string
  end
end
