# frozen_string_literal: true

module Factory
  def with_good_job_adapter(mode)
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: mode)
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end
end

RSpec.configure do |c|
  c.include Factory
end
