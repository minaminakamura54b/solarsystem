require "test_helper"

# 報告書の版の PDF（Chromium は偽物に差し替える。実際の出力は Mac と Docker で確かめる）
class ReportPdfTest < ActiveSupport::TestCase
  setup do
    @site = sites(:south)
    load_initial_rule_set
    @inspection = analyzable_inspection(grids: [], files: %w[thermal_plain_T.jpg])
    blocks = register_blocks(@site, %w[A01])
    @image = @inspection.inspection_images.first
    analyzed_image(@image, [ blocks["A01"] ], y0: 0.4)
    anomaly_at(@image, 0, 1, 3, type: "hotspot", severity: "warning", review_status: "confirmed", locked: true)
    InspectionReview.new(@inspection).complete!(all_images_checked: true)
    @report = ReportIssue.new(@inspection).issue!(acknowledge_warnings: true)
  end

  def with_fake_renderer(result: "%PDF-1.7 fake", error: nil)
    calls = []
    FerrumPdf.singleton_class.alias_method(:original_render_pdf, :render_pdf)
    FerrumPdf.define_singleton_method(:render_pdf) do |**args|
      calls << args
      raise error if error

      result
    end
    yield calls
  ensure
    FerrumPdf.singleton_class.alias_method(:render_pdf, :original_render_pdf)
    FerrumPdf.singleton_class.remove_method(:original_render_pdf)
  end

  test "版の固定コピーから HTML を作り、画像は派生画像（data URI）として埋め込み、PDF を版に付ける" do
    with_fake_renderer do |calls|
      assert ReportPdf.new(@report).call

      html = calls.sole[:html]
      assert_includes html, "熱異常スクリーニング報告書"
      assert_match %r{<img[^>]+src="data:image/jpeg;base64,}, html, "サーモの切り出しは派生画像を埋め込む"
      assert_no_match %r{/rails/active_storage}, html, "PDF の HTML はネットワークから画像を読まない"
      assert_no_match(/fonts\.googleapis|<script/, html, "外部のフォント・スクリプトを入れない")
      assert_equal false, calls.sole[:javascript_enabled]
      assert_equal :A4, calls.sole[:pdf_options][:format]
    end
    @report.reload
    assert @report.pdf.attached?
    assert_equal "application/pdf", @report.pdf.content_type
    assert_match(/第1版\.pdf\z/, @report.pdf.filename.to_s)
    assert @report.pdf_generated_at
  end

  test "社内向けの作業記録の PDF も版に付ける。発行のジョブは両方を作る" do
    with_fake_renderer do |calls|
      ReportPdfJob.perform_now(@report.id)
      assert_equal 2, calls.size
      assert_includes calls.last[:html], "作業記録（社内向け・顧客には渡さない）"
    end
    @report.reload
    assert @report.pdf.attached?
    assert @report.internal_pdf.attached?
    assert_match(/\A作業記録（社内向け）_.*第1版\.pdf\z/, @report.internal_pdf.filename.to_s)
  end

  test "作れなかったら版にエラーを残す（版の内容は変えない）" do
    snapshot = @report.snapshot
    with_fake_renderer(error: Ferrum::TimeoutError.new) { assert_not ReportPdf.new(@report).call }

    @report.reload
    assert_match "Ferrum::TimeoutError", @report.pdf_error
    assert_not @report.pdf.attached?
    assert_equal snapshot, @report.snapshot
  end

  test "Chromium のサンドボックスを外す設定をしていない" do
    assert_not FerrumPdf.config.to_h.dig(:browser_options, "no-sandbox")
    assert_not_equal "true", ENV["FERRUM_CHROME_DOCKERIZE"]
  end
end
