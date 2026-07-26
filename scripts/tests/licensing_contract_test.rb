require "minitest/autorun"

class LicensingContractTest < Minitest::Test
  REPO_ROOT = File.expand_path("../..", __dir__)
  LAST_MIT_COMMIT = "87ffc527f5a9d1057591f448d402d07993af920f"
  SOURCE_URL = "https://github.com/CHANG-JUI-LIN/Yuedu-reader"

  def test_preserves_the_historical_mit_notice
    notice = read("LICENSES/MIT.txt")

    assert_includes notice, "MIT License"
    assert_includes notice, "Copyright (c) 2025 yuedu contributors"
    assert_includes notice, "The above copyright notice and this permission notice"
  end

  def test_documents_the_exact_license_transition_boundary
    licensing = read("LICENSING.md")

    assert_includes licensing, LAST_MIT_COMMIT
    assert_includes licensing, "LICENSES/MIT.txt"
  end

  def test_about_screen_links_binary_recipients_to_source_and_license
    profile_view = read("Modules/Features/Settings/ProfileView.swift")

    assert_includes profile_view, SOURCE_URL
    assert_includes profile_view, 'localized("原始碼與開源授權")'
    assert_includes profile_view, 'localized("取得本版本對應原始碼與 MPL-2.0 授權")'

    localization_paths.each do |path|
      strings = read(path)
      assert_includes strings, '"原始碼與開源授權"'
      assert_includes strings, '"取得本版本對應原始碼與 MPL-2.0 授權"'
    end
  end

  private

  def localization_paths
    %w[
      Resources/zh-Hant.lproj/Localizable.strings
      Resources/zh-Hans.lproj/Localizable.strings
      Resources/en.lproj/Localizable.strings
    ]
  end

  def read(path)
    File.read(File.join(REPO_ROOT, path))
  end
end
