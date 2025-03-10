# frozen_string_literal: true

#
# Raise an exception when Postgres writes a notice to $stderr
#
POSTGRES_NOTICES = Concurrent::Array.new

ActiveSupport.on_load :active_record do
  ActiveRecord::ConnectionAdapters::AbstractAdapter.set_callback :checkout, :before, lambda { |conn|
    raw_connection = conn.raw_connection
    next unless raw_connection.respond_to? :set_notice_receiver

    raw_connection.set_notice_receiver do |result|
      Rails.logger.warn(result.error_message.strip)
      POSTGRES_NOTICES << result.error_message
    end
  }
end

RSpec.configure do |config|
  config.around do |example|
    POSTGRES_NOTICES.clear
    example.run
    expect(POSTGRES_NOTICES).to be_empty
  end
end
