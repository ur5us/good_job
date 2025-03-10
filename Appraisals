# frozen_string_literal: true

ruby_27_or_higher = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.7')
ruby_31_or_higher = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.1')
jruby = RUBY_PLATFORM.include?('java')

unless ruby_31_or_higher # https://github.com/rails/rails/issues/44090#issuecomment-1007686519
  appraise "rails-6.0" do
    gem "rails", "~> 6.0.0"
    gem "traces", "~> 0.9.1"
  end

  appraise "rails-6.1" do
    gem "rails", "~> 6.1.0"
    gem "traces", "~> 0.9.1"
  end
end

if ruby_27_or_higher && !ruby_31_or_higher && !jruby
  # Rails HEAD requires MRI 2.7+
  # activerecord-jdbcpostgresql-adapter does not have a compatible version

  appraise "rails-7.0" do
    gem "rails", "~> 7.0.0"
    gem "selenium-webdriver", "~> 4.0" # https://github.com/rails/rails/pull/43498
  end
end

if ruby_31_or_higher
  appraise "rails-7.0-ruby-3.1" do
    gem "capybara", "~> 3.36" # For Ruby 3.1 support https://github.com/teamcapybara/capybara/pull/2468
    gem 'psych', '5.1.0' # https://github.com/jruby/jruby/issues/7962
    gem "rails", "~> 7.0.1" # Ruby 3.1 requires Rails 7.0.1+
    gem "selenium-webdriver", "~> 4.0" # https://github.com/rails/rails/pull/43498
  end

  unless jruby
    appraise "rails-head" do
      gem "capybara", "~> 3.36"
      gem "rails", github: "rails/rails", branch: "main"
      gem "selenium-webdriver", "~> 4.0" # https://github.com/rails/rails/pull/43498
    end
  end
end
