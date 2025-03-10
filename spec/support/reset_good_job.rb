# frozen_string_literal: true

THREAD_ERRORS = Concurrent::Array.new

ActiveSupport.on_load :active_record do
  ActiveRecord::ConnectionAdapters::AbstractAdapter.set_callback :checkout, :before, lambda { |conn|
    thread_name = Thread.current.name || Thread.current.object_id
    conn.exec_query("SET application_name = '#{thread_name}'", "Set application name")
  }
end

RSpec.configure do |config|
  config.around do |example|
    GoodJob.preserve_job_records = true

    PgLock.current_database.advisory_lock.owns.all?(&:unlock) if PgLock.advisory_lock.owns.count > 0
    PgLock.current_database.advisory_lock.others.each(&:unlock!) if PgLock.advisory_lock.others.count > 0
    expect(PgLock.current_database.advisory_lock.count).to eq(0), "Existing advisory locks BEFORE test run"

    GoodJob::CurrentThread.reset
    THREAD_ERRORS.clear
    GoodJob.on_thread_error = lambda do |exception|
      THREAD_ERRORS << [Thread.current.name, exception, exception.backtrace]
    end

    example.run

    expect(THREAD_ERRORS).to be_empty
  end

  config.after do
    GoodJob.shutdown(timeout: -1)

    executables = [].concat(
      GoodJob::Capsule.instances,
      GoodJob::SharedExecutor.instances,
      GoodJob::CronManager.instances,
      GoodJob::Notifier.instances,
      GoodJob::Poller.instances,
      GoodJob::Scheduler.instances,
      GoodJob::CronManager.instances
    )
    GoodJob._shutdown_all(executables, timeout: -1)

    expect(GoodJob::Notifier.instances).to all be_shutdown
    GoodJob::Notifier.instances.clear

    expect(GoodJob::Poller.instances).to all be_shutdown
    GoodJob::Poller.instances.clear

    expect(GoodJob::CronManager.instances).to all be_shutdown
    GoodJob::CronManager.instances.clear

    expect(GoodJob::Scheduler.instances).to all be_shutdown
    GoodJob::Scheduler.instances.clear

    expect(GoodJob::Capsule.instances).to all be_shutdown
    GoodJob::Capsule.instances.clear

    # always make sure there is a capsule; unstub it first if necessary
    RSpec::Mocks.space.proxy_for(GoodJob::Capsule).reset
    GoodJob.capsule = GoodJob::Capsule.new

    expect(PgLock.current_database.advisory_lock.owns.count).to eq(0), "Existing owned advisory locks AFTER test run"

    other_locks = PgLock.current_database.advisory_lock.others
    if other_locks.any?
      puts "There are #{other_locks.count} advisory locks still open AFTER test run."
      puts "\n\nAdvisory Locks:"
      other_locks.includes(:pg_stat_activity).all.each do |pg_lock| # rubocop:disable Rails/FindEach
        puts "  - #{pg_lock.pid}: #{pg_lock.pg_stat_activity.application_name}"
      end

      puts "\n\nCurrent connections:"
      PgStatActivity.all.each do |pg_stat_activity| # rubocop:disable Rails/FindEach
        puts "  - #{pg_stat_activity.pid}: #{pg_stat_activity.application_name}"
      end
    end

    expect(PgLock.current_database.advisory_lock.others.count).to eq(0), "Existing others advisory locks AFTER test run"

    GoodJob.configuration.instance_variable_set(:@_in_webserver, nil)
  end
end

module PostgresXidExtension
  def initialize_type_map(map = type_map)
    if respond_to?(:register_class_with_limit, true)
      register_class_with_limit map, 'xid', ActiveRecord::Type::String # OID 28
    else
      # Rails 7 defines statically
      # https://github.com/rails/rails/commit/d79fb963603658117fd1d639976c375ea2a8ada3
      self.class.send :register_class_with_limit, map, 'xid', ActiveRecord::Type::String # OID 28
    end

    super(map)
  end
end

ActiveSupport.on_load :active_record do
  ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend PostgresXidExtension
end

class PgStatActivity < ActiveRecord::Base
  self.table_name = 'pg_stat_activity'
  self.primary_key = 'datid'
end

class PgLock < ActiveRecord::Base
  self.table_name = 'pg_locks'
  self.primary_key = 'objid'

  belongs_to :pg_stat_activity, primary_key: :pid, foreign_key: :pid

  scope :current_database, -> { joins("JOIN pg_database ON pg_database.oid = pg_locks.database").where("pg_database.datname = current_database()") }
  scope :advisory_lock, -> { where(locktype: 'advisory') }
  scope :owns, -> { where('pid = pg_backend_pid()') }
  scope :others, -> { where('pid != pg_backend_pid()') }

  def unlock
    query = <<~SQL.squish
      SELECT pg_advisory_unlock(($1::bigint << 32) + $2::bigint) AS unlocked
    SQL

    binds = [
      ActiveRecord::Relation::QueryAttribute.new('classid', classid, ActiveRecord::Type::String.new),
      ActiveRecord::Relation::QueryAttribute.new('objid', objid, ActiveRecord::Type::String.new),
    ]
    self.class.connection.exec_query(GoodJob::Execution.pg_or_jdbc_query(query), 'PgLock Advisory Unlock', binds).first['unlocked']
  end

  def unlock!
    query = <<~SQL.squish
      SELECT pg_terminate_backend(#{self[:pid]}) AS terminated
    SQL
    self.class.connection.exec_query(GoodJob::Execution.pg_or_jdbc_query(query), 'PgLock Terminate Backend Lock', []).first['terminated']
  end
end
