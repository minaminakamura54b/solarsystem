# 報告書の版の PDF を作る（docs/IMPROVEMENT_PLAN.md Phase 7）。
# - 版の固定コピーから報告書の画面と同じテンプレートで HTML を作り、切り出し画像は派生画像として埋め込む（ReportImages）
# - Chromium（ferrum_pdf）で PDF にする。サンドボックスは外さない（--no-sandbox を使わない。Docker では config/seccomp/chromium.json）
# - HTML にはネットワークから読むものを入れない（外部のフォント・スクリプト・画像の URL を使わない）。JavaScript は動かさない
# - 作れなかったら版にエラーを残す（版の内容・点検の状態は変えない）
class ReportPdf
  def initialize(report, now: Time.current)
    @report = report
    @now = now
  end

  def call
    pdf = FerrumPdf.render_pdf(html: html, javascript_enabled: false, pdf_options: PDF_OPTIONS.merge(footer_template: footer))
    @report.pdf.attach(io: StringIO.new(pdf), filename: @report.pdf_filename, content_type: "application/pdf")
    @report.update_columns(pdf_generated_at: @now, pdf_error: nil)
    true
  rescue Ferrum::Error, Vips::Error, ActiveStorage::FileNotFoundError, ActionView::Template::Error => e
    @report.update_columns(pdf_error: "#{e.class}: #{e.message}".truncate(500))
    false
  end

  def html
    snapshot = @report.snapshot
    ids = snapshot["items"].flat_map { |i| [ i.dig("image", "id") ] + Array(i["others"]).map { |o| o["image_id"] } }.compact.uniq
    images = InspectionImage.where(id: ids).includes(thermal_attachment: :blob, preview_attachment: :blob, rgb_attachment: :blob).index_by(&:id)
    ApplicationController.render(template: "reports/show", layout: "report",
                                 assigns: { inspection: @report.inspection, report: @report, snapshot:, pdf_images: ReportImages.new(images) })
  end

  PDF_OPTIONS = {
    format: :A4, print_background: true, display_header_footer: true, header_template: "<span></span>",
    margin_top: 0.55, margin_bottom: 0.6, margin_left: 0.47, margin_right: 0.47
  }.freeze

  private

  def footer
    title = ERB::Util.html_escape("熱異常スクリーニング報告書 #{@report.title}")
    "<div style=\"font-size:8px; width:100%; padding:0 12mm; display:flex; justify-content:space-between; color:#6b7280; " \
      "font-family:'Noto Sans CJK JP','Noto Sans JP','Hiragino Sans',sans-serif;\">" \
      "<span>#{title}</span><span><span class=\"pageNumber\"></span> / <span class=\"totalPages\"></span></span></div>"
  end
end
