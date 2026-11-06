require "application_system_test_case"

# 点検の登録画面で、選んだファイルをサーバーと同じ規則でペアにして一覧表示する JS を確かめる
class UploadFormTest < ApplicationSystemTestCase
  setup do
    @site = sites(:south)
    @dir = Rails.root.join("tmp", "upload_form_test_#{Process.pid}")
    FileUtils.mkdir_p(@dir)
  end

  teardown do
    FileUtils.rm_rf(@dir)
  end

  def files(*names)
    names.map do |name|
      path = @dir.join(name)
      FileUtils.cp(file_fixture("thermal_plain_T.jpg"), path)
      path.to_s
    end
  end

  test "番号が同じで時刻の差が設定以内ならペアにし、時刻のずれ・複製は登録しないと表示する" do
    visit new_inspection_path(site_id: @site.id)
    attach_file "inspection[files][]", files(
      "DJI_20260716171623_0052_T.JPG", "DJI_20260716171624_0052_V.JPG",
      "DJI_20260716171700_0053_T.JPG", "DJI_20260716180000_0053_V.JPG",
      "DJI_20260716171624_0052_V (2).JPG"
    ), make_visible: true

    assert_text "サーモ画像 2枚（RGB とのペア 1組） / 組にならない RGB 1枚（登録されません） / 複製と思われるファイル 1枚（登録されません）"
    assert_text "DJI_20260716171623_0052_T.JPG + DJI_20260716171624_0052_V.JPG"
    assert_text "DJI_20260716180000_0053_V.JPG（番号が同じサーモ画像と撮影時刻が 2 秒を超えてずれています）"
    assert_text "DJI_20260716171624_0052_V (2).JPG（複製と思われるため登録しません）"
  end
end
