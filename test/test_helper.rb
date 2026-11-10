ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# 開発者の .env（dotenv が test でも読む）にある本物の Claude の設定を、テストでは使わない。
# 本物の API を呼ばないため・結果が開発者の環境に左右されないため。Claude を使うテストは with_fake_claude で偽のクライアントとモデル名を入れる
ENV.delete("SOLARSIGHT_ANTHROPIC_API_KEY")
ENV.delete("SOLARSIGHT_CLAUDE_MODEL")

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include ActiveJob::TestHelper
    include ClaudeTestHelper
    include Phase2TestHelper
    include AnalyzerTestHelper
    include PanelCandidateTestHelper
  end
end
