# サーモの位置（0〜1 の正規化座標）から、同時撮影の RGB のおおよその位置を求める（Phase 7 の決定事項 2026-11-09）。
# 両方のカメラが同じ向きで画像の中心がそろっていると仮定し、画角の比だけで移す:
#   u_rgb = 0.5 + (u − 0.5) × (サーモの横の画素数 × サーモの画素の角度) / (RGB の横の画角)
# RGB の画角は「RGB の画素の角度 × 基準の横の画素数」（縦は RGB の縦横比から）。値は config/layout_overlay.yml のカメラごと。
# 位置合わせを調整した値ではないので、表示・報告書では必ず「おおよその位置」と注記し、RGB には枠を描かない（報告書）。
# カメラが設定に無いときは nil（呼び出し側は今までどおり同じ正規化座標を使う）
class RgbCropMapping
  def self.for(image, config: LayoutOverlayConfig.current)
    ifov = config.ifov_mrad(image.camera_model)
    rgb = config.rgb_optics(image.camera_model)
    return nil unless ifov && rgb && image.width.to_i.positive? && image.height.to_i.positive?

    new(thermal_fov_x: image.width * ifov, thermal_fov_y: image.height * ifov, rgb_fov_x: rgb[:ifov_mrad] * rgb[:reference_width])
  end

  attr_reader :thermal_fov_x, :thermal_fov_y, :rgb_fov_x

  def initialize(thermal_fov_x:, thermal_fov_y:, rgb_fov_x:)
    @thermal_fov_x = thermal_fov_x.to_f
    @thermal_fov_y = thermal_fov_y.to_f
    @rgb_fov_x = rgb_fov_x.to_f
  end

  # RGB の縦横の画素数から、正規化座標の倍率（横・縦）
  def scales(rgb_width, rgb_height)
    rgb_fov_y = rgb_fov_x * rgb_height.to_f / rgb_width.to_f
    [ thermal_fov_x / rgb_fov_x, thermal_fov_y / rgb_fov_y ]
  end

  def to_rgb(bbox, rgb_width, rgb_height)
    sx, sy = scales(rgb_width, rgb_height)
    { "x1" => 0.5 + (bbox["x1"].to_f - 0.5) * sx, "x2" => 0.5 + (bbox["x2"].to_f - 0.5) * sx,
      "y1" => 0.5 + (bbox["y1"].to_f - 0.5) * sy, "y2" => 0.5 + (bbox["y2"].to_f - 0.5) * sy }
  end

  # 画面の JS（review_controller.js）に渡す値（RGB の画素数は画像を読み込んでから分かるため、比の材料を渡す）
  def data_attributes
    { rgb_thermal_fov_x: thermal_fov_x.round(3), rgb_thermal_fov_y: thermal_fov_y.round(3), rgb_fov_x: rgb_fov_x.round(3) }
  end
end
