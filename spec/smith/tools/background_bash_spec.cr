require "../../spec_helper"
require "../../../src/smith/tools"

private def with_bash(timeout : Int32 = 120, max : Int32 = 10, &)
  dir = File.join(Dir.tempdir, "smith_bg_#{Random::Secure.hex(4)}")
  jobs = Smith::Tools::BashJobs.new(dir, max_jobs: max)
  begin
    yield Smith::Tools::Bash.new(jobs: jobs, timeout: timeout), jobs
  ensure
    jobs.shutdown_all(grace: 1.second)
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

private def args(command : String, background : Bool? = nil)
  hash = {"command" => command} of String => JSON::Any::Type
  hash["background"] = background unless background.nil?
  JSON.parse(hash.to_json)
end

describe "bash in the foreground" do
  it "still returns its output as before" do
    with_bash do |bash, _jobs|
      bash.run(args("echo hello")).should contain("hello")
    end
  end

  it "still reports a failing exit code" do
    with_bash do |bash, _jobs|
      output = bash.run(args("echo oops >&2; exit 3"))

      output.should contain("oops")
      output.should contain("exit code 3")
    end
  end

  it "leaves no job behind once it finished" do
    with_bash do |bash, jobs|
      bash.run(args("echo done"))

      jobs.jobs.should be_empty
    end
  end
end

describe "explicit backgrounding" do
  it "returns at once with an id" do
    with_bash do |bash, jobs|
      output = bash.run(args("sleep 5", background: true))

      output.should contain("bash-1")
      output.should contain("background")
      jobs.running.size.should eq(1)
    end
  end

  it "refuses once the limit is reached, without killing anything" do
    with_bash(max: 1) do |bash, jobs|
      bash.run(args("sleep 5", background: true)).should contain("bash-1")

      refusal = bash.run(args("sleep 5", background: true))
      refusal.should start_with("Error:")
      refusal.should contain("1")
      jobs.running.size.should eq(1)
    end
  end
end

describe "auto-backgrounding at the timeout" do
  it "hands the command over instead of killing it" do
    with_bash(timeout: 1) do |bash, jobs|
      output = bash.run(args("echo started; sleep 30"))

      output.should contain("bash-1")
      output.should contain("background")
      # The output produced before the deadline is the point — killing the
      # command would have thrown it away.
      output.should contain("started")
      jobs.running.size.should eq(1)
    end
  end

  it "does not background a command that finishes in time" do
    with_bash(timeout: 5) do |bash, jobs|
      bash.run(args("echo quick")).should contain("quick")

      jobs.running.should be_empty
    end
  end
end

describe Smith::Tools::BashOutput do
  it "returns only what is new, with the status" do
    with_bash do |bash, jobs|
      bash.run(args("echo one; sleep 0.5; echo two", background: true))
      tool = Smith::Tools::BashOutput.new(jobs)

      sleep 0.2.seconds
      first = tool.run(JSON.parse(%({"id": "bash-1"})))
      first.should contain("one")
      first.should contain("running")

      jobs["bash-1"].not_nil!.wait(5.seconds)
      second = tool.run(JSON.parse(%({"id": "bash-1"})))
      second.should contain("two")
      second.should_not contain("one")
      second.should contain("exited(0)")
    end
  end

  it "applies a filter" do
    with_bash do |bash, jobs|
      bash.run(args("echo keep-me; echo drop-this", background: true))
      jobs["bash-1"].not_nil!.wait(5.seconds)

      output = Smith::Tools::BashOutput.new(jobs).run(JSON.parse(%({"id": "bash-1", "filter": "keep"})))
      output.should contain("keep-me")
      output.should_not contain("drop-this")
    end
  end

  it "says so when there is nothing new" do
    with_bash do |bash, jobs|
      bash.run(args("sleep 5", background: true))

      Smith::Tools::BashOutput.new(jobs).run(JSON.parse(%({"id": "bash-1"})))
        .should contain("no new output")
    end
  end

  it "reports an unknown id as a tool error" do
    with_bash do |_bash, jobs|
      result = Smith::Tools::BashOutput.new(jobs).run(JSON.parse(%({"id": "bash-99"})))

      result.should start_with("Error:")
      result.should contain("bash-99")
    end
  end

  it "reports a broken filter rather than raising" do
    with_bash do |bash, jobs|
      bash.run(args("echo x", background: true))

      Smith::Tools::BashOutput.new(jobs).run(JSON.parse(%({"id": "bash-1", "filter": "["})))
        .should start_with("Error:")
    end
  end

  it "reads, so it neither mutates nor needs the approval gate" do
    with_bash do |_bash, jobs|
      tool = Smith::Tools::BashOutput.new(jobs)

      tool.mutating?.should be_false
      # It moves a shared cursor, so it must not run concurrently with itself.
      tool.parallel?.should be_false
    end
  end
end

describe Smith::Tools::BashKill do
  it "stops a running job" do
    with_bash do |bash, jobs|
      bash.run(args("sleep 30", background: true))

      Smith::Tools::BashKill.new(jobs).run(JSON.parse(%({"id": "bash-1"}))).should contain("killed")
      jobs["bash-1"].not_nil!.running?.should be_false
    end
  end

  it "reports an unknown id as a tool error" do
    with_bash do |_bash, jobs|
      Smith::Tools::BashKill.new(jobs).run(JSON.parse(%({"id": "nope"}))).should start_with("Error:")
    end
  end

  it "goes through the approval gate, since it stops something" do
    with_bash do |_bash, jobs|
      Smith::Tools::BashKill.new(jobs).mutating?.should be_true
    end
  end
end
