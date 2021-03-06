require "httparty"
require "tempfile"

module IntegrationHelpers
  def start_health_manager(config = {})
    with_config_file(config) do |path|
      @hm_pid = run_cmd("./bin/health_manager --config=#{path}", :debug => false)
    end
    wait_until { health_manager_up? }
  end

  def start_fake_bulk_api(port)
    username = 'some_user'
    password = 'some_password'
    @bulk_api_pid = run_cmd("./spec/bin/bulk_api_server.rb #{port} #{username} #{password}", :debug => false)
    wait_until { bulk_api_up?(port, { :username => username, :password => password}) }
  end

  def start_nats_server
    @nats_pid = run_cmd("nats-server -D", debug: false)
    wait_until { nats_up? }
  end

  def with_nats_server(timeout = 10)
    start_nats_server
    NATS.start do
      EM.add_timer(timeout) do
        puts "Timeout reached, exiting..."
        NATS.stop
      end
      yield
    end
  ensure
    stop_nats_server
  end

  def stop_fake_bulk_api
    graceful_shutdown(:bulk_api, @bulk_api_pid)
  end

  def stop_health_manager
    graceful_shutdown(:hm, @hm_pid)
  end

  def stop_nats_server
    graceful_shutdown(:nats, @nats_pid)
  end

  def bulk_api_up?(port, credentials)
    HTTParty.get("http://127.0.0.1:#{port}/bulk/counts", :basic_auth => credentials).success?
  end

  def health_manager_up?
    HTTParty.get("http://127.0.0.1:54321/varz", basic_auth: {
      username: "thin",
      password: "thin"
    }).success?
  end

  def nats_up?
    NATS.start do
      NATS.stop
      return true
    end
  rescue NATS::ConnectError
    nil
  end

  def run_nats_for_time(time_limit, &block)
    Timeout.timeout(time_limit) { NATS.start(&block) }
  rescue Timeout::Error
    nil
  end

  private

  def run_cmd(cmd, opts={})
    spawn_opts = {
      :chdir => File.join(File.dirname(__FILE__), "../.."),
      :out => opts[:debug] ? :out : "/dev/null",
      :err => opts[:debug] ? :out : "/dev/null",
    }

    Process.spawn(cmd, spawn_opts).tap do |pid|
      if opts[:wait]
        Process.wait(pid)
        raise "`#{cmd}` exited with #{$?}" unless $?.success?
      end
    end
  end

  def graceful_shutdown(name, pid)
    Process.kill("TERM", pid)
    Timeout.timeout(1) do
      while process_alive?(pid) do
      end
    end
  rescue Timeout::Error
    Process.kill("KILL", pid)
  end

  def process_alive?(pid)
    Process.getpgid(pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until(&block)
    Timeout::timeout(10) do
      loop do
        sleep 0.2
        begin
          break if block.call
        rescue Errno::ECONNREFUSED => e
        end
      end
    end
  end

  ROOT_DIR = File.expand_path("../../..", __FILE__)

  def with_config_file(hash)
    default_config_file = File.join(ROOT_DIR, "config", "health_manager.yml")
    default_hash = YAML.load_file(default_config_file)
    merged_hash = deep_merge(default_hash, hash)

    f = Tempfile.new("health_manager_config")
    f.write(YAML.dump(merged_hash))
    f.rewind
    yield f.path
  end

  def deep_merge(first_hash, other_hash)
    first_hash.merge(other_hash) do |key, oldval, newval|
      oldval = oldval.to_hash if oldval.respond_to?(:to_hash)
      newval = newval.to_hash if newval.respond_to?(:to_hash)
      oldval.class.to_s == 'Hash' && newval.class.to_s == 'Hash' ? deep_merge(oldval, newval) : newval
    end
  end
end

RSpec.configure do |rspec_config|
  rspec_config.include(IntegrationHelpers, :type => :integration)
end
