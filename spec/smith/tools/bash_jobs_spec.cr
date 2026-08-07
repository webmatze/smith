require "../../spec_helper"
require "../../../src/smith/tools/bash_jobs"

private def with_jobs(max : Int32 = 10, &)
  dir = File.join(Dir.tempdir, "smith_jobs_#{Random::Secure.hex(4)}")
  jobs = Smith::Tools::BashJobs.new(dir, max_jobs: max)
  begin
    yield jobs, dir
  ensure
    jobs.shutdown_all
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

describe Smith::Tools::BashJobs do
  it "starts a job and hands back an id" do
    with_jobs do |jobs, _dir|
      job = jobs.start("echo hello").not_nil!

      job.id.should eq("bash-1")
      job.wait(5.seconds).should be_true
      job.read_new.should contain("hello")
    end
  end

  it "numbers jobs in order" do
    with_jobs do |jobs, _dir|
      jobs.start("true").not_nil!.id.should eq("bash-1")
      jobs.start("true").not_nil!.id.should eq("bash-2")
    end
  end

  it "writes output to disk rather than holding it in memory" do
    with_jobs do |jobs, _dir|
      job = jobs.start("echo to-the-log").not_nil!
      job.wait(5.seconds)

      File.exists?(job.log_path).should be_true
      File.read(job.log_path).should contain("to-the-log")
    end
  end

  it "reads incrementally, so a long-running log is not resent every time" do
    with_jobs do |jobs, _dir|
      job = jobs.start("echo first; sleep 0.4; echo second").not_nil!

      # Give the first line time to land without waiting for the whole job.
      sleep 0.2.seconds
      first = job.read_new
      first.should contain("first")
      first.should_not contain("second")

      job.wait(5.seconds)
      second = job.read_new
      second.should contain("second")
      second.should_not contain("first")
    end
  end

  it "filters to matching lines when asked" do
    with_jobs do |jobs, _dir|
      job = jobs.start("echo keep-me; echo drop-this; echo keep-me-too").not_nil!
      job.wait(5.seconds)

      output = job.read_new(/keep/)
      output.should contain("keep-me")
      output.should contain("keep-me-too")
      output.should_not contain("drop-this")
    end
  end

  it "reports its status through the run" do
    with_jobs do |jobs, _dir|
      job = jobs.start("sleep 0.3").not_nil!
      job.running?.should be_true
      job.status.should eq("running")

      job.wait(5.seconds)
      job.status.should eq("exited(0)")
    end
  end

  it "carries a non-zero exit code" do
    with_jobs do |jobs, _dir|
      job = jobs.start("exit 3").not_nil!
      job.wait(5.seconds)

      job.status.should eq("exited(3)")
    end
  end

  it "kills a job on request" do
    with_jobs do |jobs, _dir|
      job = jobs.start("sleep 30").not_nil!
      job.kill(grace: 1.second)

      job.running?.should be_false
      job.status.should eq("killed")
    end
  end

  it "refuses to start more than the configured number" do
    with_jobs(max: 2) do |jobs, _dir|
      jobs.start("sleep 5").should_not be_nil
      jobs.start("sleep 5").should_not be_nil
      jobs.start("sleep 5").should be_nil
    end
  end

  it "counts only jobs that are still running towards the limit" do
    with_jobs(max: 1) do |jobs, _dir|
      first = jobs.start("true").not_nil!
      first.wait(5.seconds)

      jobs.start("true").should_not be_nil
    end
  end

  it "leaves nothing running after shutdown" do
    dir = File.join(Dir.tempdir, "smith_jobs_#{Random::Secure.hex(4)}")
    jobs = Smith::Tools::BashJobs.new(dir)
    begin
      a = jobs.start("sleep 30").not_nil!
      b = jobs.start("sleep 30").not_nil!

      jobs.shutdown_all(grace: 1.second)

      a.running?.should be_false
      b.running?.should be_false
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "finds a job by id, and says nothing for an unknown one" do
    with_jobs do |jobs, _dir|
      job = jobs.start("true").not_nil!

      jobs[job.id].should_not be_nil
      jobs["bash-99"].should be_nil
    end
  end
end

describe "waiting on a job" do
  it "reports whether it finished in time" do
    with_jobs do |jobs, _dir|
      slow = jobs.start("sleep 5").not_nil!
      slow.wait(0.2.seconds).should be_false

      quick = jobs.start("true").not_nil!
      quick.wait(5.seconds).should be_true
    end
  end

  it "keeps the output written before the deadline" do
    with_jobs do |jobs, _dir|
      job = jobs.start("echo early; sleep 5").not_nil!

      job.wait(0.4.seconds).should be_false
      # This is the whole point of auto-backgrounding: nothing is thrown away.
      job.read_new.should contain("early")
    end
  end
end

describe "how long a job ran" do
  it "stops counting once the job ended" do
    with_jobs do |jobs, _dir|
      job = jobs.start("sleep 0.2").not_nil!
      job.wait(5.seconds)

      first = job.runtime
      sleep 0.3.seconds

      job.runtime.should eq(first)
    end
  end
end
