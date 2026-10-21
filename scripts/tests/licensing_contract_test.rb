require "minitest/autorun"

class LicensingContractTest < Minitest::Test
  REPO_ROOT = File.expand_path("../..", __dir__)
  LAST_MIT_COMMIT = "87ffc527f5a9d1057591f448d402d07993af920f"
  LAST_MPL_COMMIT = "0479b74134a26234cb407c7c841e08e8115aec5f"
  SOURCE_URL = "https://github.com/CHANG-JUI-LIN/Yuedu-reader"

  def test_current_license_is_polyform_strict
    license = read("LICENSE")

    assert_includes license, "# PolyForm Strict License 1.0.0"
    assert_includes license, "other than distributing the software or making changes or new works based on the software"
  end

  def test_preserves_the_historical_mit_notice
    notice = read("LICENSES/MIT.txt")

    assert_includes notice, "MIT License"
    assert_includes notice, "Copyright (c) 2025 yuedu contributors"
    assert_includes notice, "The above copyright notice and this permission notice"
  end

  def test_preserves_the_historical_mpl_text
    mpl = read("LICENSES/MPL-2.0.txt")

    assert_includes mpl, "Mozilla Public License Version 2.0"
    assert_includes mpl, "Exhibit A - Source Code Form License Notice"
  end

  def test_documents_the_exact_license_transition_boundaries
    licensing = read("LICENSING.md")

    assert_includes licensing, LAST_MIT_COMMIT
    assert_includes licensing, "LICENSES/MIT.txt"
    assert_includes licensing, LAST_MPL_COMMIT
    assert_includes licensing, "LICENSES/MPL-2.0.txt"
  end

  def test_about_screen_links_binary_recipients_to_source_and_license
    profile_view = read("Modules/Features/Settings/ProfileView.swift")

    assert_includes profile_view, SOURCE_URL
    assert_includes profile_view, 'localized("原始碼與授權")'
    assert_includes profile_view, 'localized("取得本版本對應原始碼與授權條款")'

    localization_paths.each do |path|
      strings = read(path)
      assert_includes strings, '"原始碼與授權"'
      assert_includes strings, '"取得本版本對應原始碼與授權條款"'
    end
  end

  private

  def localization_paths
    %w[
      Resources/zh-Hant.lproj/Localizable.strings
      Resources/zh-Hans.lproj/Localizable.strings
      Resources/en.lproj/Localizable.strings
      Resources/ja.lproj/Localizable.strings
      Resources/ko.lproj/Localizable.strings
    ]
  end

  def read(path)
    File.read(File.join(REPO_ROOT, path), encoding: "UTF-8")
  end
end
