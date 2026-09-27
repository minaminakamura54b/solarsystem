require "test_helper"

class InspectionImageTest < ActiveSupport::TestCase
  setup do
    @inspection = create_session_inspection(files: %w[thermal_plain_T.jpg lowres_T.jpg])
    @image = @inspection.inspection_images.first
  end

  test "画像ファイル以外はサーモ画像として登録できない" do
    image = @inspection.inspection_images.build(sequence: 9, thermal_filename: "memo.txt")
    image.thermal.attach(io: StringIO.new("hello"), filename: "memo.txt", content_type: "text/plain")

    assert_not image.valid?
    assert_includes image.errors[:base], "memo.txt は画像ファイルではありません"
  end

  test "要確認の画像は理由付きで除外できる" do
    @image.update!(analysis_status: "needs_review", review_reason: "no_radiometric")

    @image.exclude!("パネルが写っていない")

    assert @image.reload.excluded?
    assert_equal "パネルが写っていない", @image.exclusion_note
  end

  test "除外の理由は必須" do
    @image.update!(analysis_status: "needs_review")

    assert_raises(ActiveRecord::RecordInvalid) { @image.exclude!("") }
    assert @image.reload.needs_review?
  end

  test "品質チェック待ち・解析待ちの画像は除外できない" do
    assert_raises(ArgumentError) { @image.exclude!("理由") }
  end

  test "除外を取り消すと品質チェックの結果に応じたステータスに戻る" do
    @image.update!(analysis_status: "needs_review", quality_report: { "status" => "rejected" })
    @image.exclude!("理由")

    @image.unexclude!

    assert @image.reload.needs_review?
    assert_nil @image.exclusion_note
  end

  test "品質チェック前は quality_pending?" do
    assert @image.quality_pending?
    @image.quality_report = { "status" => "ok" }
    assert_not @image.quality_pending?
  end
end
