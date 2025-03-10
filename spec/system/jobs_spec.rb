# frozen_string_literal: true

require 'rails_helper'

describe 'Jobs', :js do
  before do
    allow(GoodJob).to receive_messages(retry_on_unhandled_error: false, preserve_job_records: true)
  end

  it 'renders chart js' do
    visit good_job.jobs_path
    expect(page).to have_content 'GoodJob 👍'
  end

  it 'renders each top-level page successfully' do
    visit good_job.jobs_path
    expect(page).to have_content 'GoodJob 👍'

    click_on "Jobs"
    expect(page).to have_content 'GoodJob 👍'

    click_on "Cron"
    expect(page).to have_content 'GoodJob 👍'

    click_on "Processes"
    expect(page).to have_content 'GoodJob 👍'
  end

  describe 'Jobs' do
    let(:unfinished_job) do
      ExampleJob.set(wait: 10.minutes, queue: :mice).perform_later
      GoodJob::Job.order(created_at: :asc).last
    end

    let(:discarded_job) do
      travel_to 1.hour.ago
      ExampleJob.set(queue: :elephants).perform_later(ExampleJob::DEAD_TYPE)
      5.times do
        travel 5.minutes
        GoodJob.perform_inline
      end
      travel_back
      GoodJob::Job.order(created_at: :asc).last
    end

    before do
      ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :inline)
      discarded_job
      ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
      unfinished_job
    end

    describe 'filtering' do
      let!(:foo_queue_job) { ConfigurableQueueJob.set(wait: 10.minutes).perform_later(queue_as: 'foo') }

      it "can filter by job class" do
        visit good_job.jobs_path

        select "ConfigurableQueueJob", from: "job_class_filter"
        expect(current_url).to match(/job_class=ConfigurableQueueJob/)

        table = page.find("[role=table]")
        expect(table).to have_selector("[role=row]", count: 1)
        expect(table).to have_content(foo_queue_job.job_id)
      end

      it "can filter by state" do
        visit good_job.jobs_path

        within "#filter" do
          click_on "Scheduled"
        end

        expect(current_url).to match(/state=scheduled/)

        table = page.find("[role=table]")
        expect(table).to have_selector("[role=row]", count: 2)
        expect(table).to have_content(foo_queue_job.job_id)
      end

      it "can filter by queue" do
        visit good_job.jobs_path

        select "foo", from: "job_queue_filter"
        expect(current_url).to match(/queue_name=foo/)

        table = page.find("[role=table]")
        expect(table).to have_selector("[role=row]", count: 1)
        expect(table).to have_content(foo_queue_job.job_id)
      end

      it "can filter by multiple variables" do
        visit good_job.jobs_path

        select "ConfigurableQueueJob", from: "job_class_filter"
        select "mice", from: "job_queue_filter"

        expect(page).to have_content("No jobs found.")

        select "foo", from: "job_queue_filter"

        expect(page).to have_content(foo_queue_job.job_id)
      end

      it 'can search by argument' do
        visit '/good_job'
        click_on "Jobs"

        expect(page).to have_selector('[role=row]', count: 3)
        fill_in 'query', with: ExampleJob::DEAD_TYPE
        click_on 'Search'
        expect(page).to have_selector('[role=row]', count: 1)
      end
    end

    it 'can retry discarded jobs' do
      visit '/good_job'
      click_on "Jobs"

      expect do
        within "##{dom_id(discarded_job)}" do
          click_on 'Actions'
          accept_confirm { click_on 'Retry job' }
        end
        expect(page).to have_content "Job has been retried"
      end.to change { discarded_job.reload.status }.from(:discarded).to(:queued)
    end

    it 'can discard jobs' do
      visit '/good_job'
      click_on "Jobs"

      expect do
        within "##{dom_id(unfinished_job)}" do
          click_on 'Actions'
          accept_confirm { click_on 'Discard job' }
        end
        expect(page).to have_content "Job has been discarded"
      end.to change { unfinished_job.head_execution(reload: true).finished_at }.from(nil).to within(1.second).of(Time.current)
    end

    it 'can force discard jobs' do
      unfinished_job.update scheduled_at: 1.hour.ago

      locked_event = Concurrent::Event.new
      done_event = Concurrent::Event.new

      promise = Concurrent::Promises.future do
        rails_promise do
          # pretend the job is running
          unfinished_job.with_advisory_lock do
            locked_event.set
            done_event.wait(20)
          end
        end
      end
      locked_event.wait(10)

      visit '/good_job'
      click_on "Jobs"

      expect do
        within "##{dom_id(unfinished_job)}" do
          click_on 'Actions'
          accept_confirm { click_on 'Force discard' }
        end
        expect(page).to have_content "Job has been force discarded"
      end.to change { unfinished_job.head_execution(reload: true).finished_at }.from(nil).to within(1.second).of(Time.current)
    ensure
      locked_event.set
      done_event.set
      promise.value!
    end

    it 'can destroy jobs' do
      visit '/good_job'
      click_on "Jobs"

      within "##{dom_id(discarded_job)}" do
        click_on 'Actions'
        accept_confirm { click_on 'Destroy job' }
      end
      expect(page).to have_content "Job has been destroyed"
      expect { discarded_job.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'performs batch job actions' do
      visit "/good_job"
      click_on "Jobs"

      expect(page).to have_field(checked: true, count: 0)

      check "toggle_job_ids"
      expect(page).to have_field(checked: true, count: 3)

      uncheck "toggle_job_ids"
      expect(page).to have_field(checked: true, count: 0)

      expect do
        check "toggle_job_ids"
        within("[role=table] header") { accept_confirm { click_on "Reschedule all" } }
        expect(page).to have_field(checked: true, count: 0)
      end.to change { unfinished_job.reload.scheduled_at }.to within(1.second).of(Time.current)

      expect do
        check "toggle_job_ids"
        within("[role=table] header") { accept_confirm { click_on "Discard all" } }
        expect(page).to have_field(checked: true, count: 0)
      end.to change { GoodJob::Job.discarded.count }.from(1).to(2)

      expect do
        check "toggle_job_ids"
        within("[role=table] header") { accept_confirm { click_on "Retry all" } }
        expect(page).to have_field(checked: true, count: 0)
      end.to change { GoodJob::Job.discarded.count }.from(2).to(0)

      visit good_job.jobs_path(limit: 1)
      expect do
        check "toggle_job_ids"
        check "Apply to all 2 jobs"
        within("[role=table] header") { accept_confirm { click_on "Discard all" } }
        expect(page).to have_field(checked: true, count: 0)
      end.to change { GoodJob::Job.discarded.count }.from(0).to(2)

      visit "/good_job"
      click_on "Jobs"
      expect do
        check "toggle_job_ids"
        within("[role=table] header") do
          click_on "Toggle Actions"
          accept_confirm { click_on "Destroy all" }
        end
        expect(page).to have_field(checked: true, count: 0)
      end.to change(GoodJob::Job, :count).from(2).to(0)
    end
  end
end
