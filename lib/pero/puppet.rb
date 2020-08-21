require 'net/ssh'

Specinfra::Configuration.error_on_missing_backend_type = false
Specinfra.configuration.backend = :ssh
module Specinfra
  module Configuration
    def self.sudo_password
      return ENV['SUDO_PASSWORD'] if ENV['SUDO_PASSWORD']
      return @sudo_password if defined?(@sudo_password)

      # TODO: Fix this dirty hack
      return nil unless caller.any? {|call| call.include?('channel_data') }

      print "sudo password: "
      @sudo_password = STDIN.noecho(&:gets).strip
      print "\n"
      @sudo_password
    end
  end
end

module Pero
  class Puppet
    extend Pero::SshExecutable
    attr_reader :specinfra
    def initialize(host, options)
      @options = options.dup

      @options[:host] = host
      so = ssh_options
      @specinfra = Specinfra::Backend::Ssh.new(
        request_pty: true,
        host: so[:host_name],
        ssh_options: so,
        disable_sudo: false,
      )
    end

    # refs: github.com/itamae-kitchen/itamae
    def ssh_options
      opts = {}
      opts[:host_name] = @options[:host]

      # from ssh-config
      ssh_config_files = @options[:ssh_config] ? [@options[:ssh_config]] : Net::SSH::Config.default_files
      opts.merge!(Net::SSH::Config.for(@options[:host], ssh_config_files))
      opts[:user] = @options[:user] || opts[:user] || Etc.getlogin
      opts[:password] = @options[:password] if @options[:password]
      opts[:keys] = [@options[:key]] if @options[:key]
      opts[:port] = @options[:port] if @options[:port]

      if @options[:vagrant]
        config = Tempfile.new('', Dir.tmpdir)
        hostname = opts[:host_name] || 'default'
        vagrant_cmd = "vagrant ssh-config #{hostname} > #{config.path}"
        if defined?(Bundler)
          Bundler.with_clean_env do
            `#{vagrant_cmd}`
          end
        else
          `#{vagrant_cmd}`
        end
        opts.merge!(Net::SSH::Config.for(hostname, [config.path]))
      end

      if @options[:ask_password]
        print "password: "
        password = STDIN.noecho(&:gets).strip
        print "\n"
        opts.merge!(password: password)
      end
      opts
    end

    def install(port=8140)
      Pero.log.info "bootstrap puppet"
      osi = specinfra.os_info
      os = case osi[:family]
      when "redhat"
        Redhat.new(specinfra, osi)
      else
          raise "sorry unsupport os, please pull request!!!"
      end
      os.install(@options["puppet-version"])
    end

    def serve_master(version)
        Pero.log.info "start puppet master container"
        container = run_container(version)
        begin
          yield
        rescue => e
          Pero.log.error e.inspect
          raise e
        ensure
          Pero.log.info "stop puppet master container"
          container.kill
        end
    end

    def run_container(version)
      Pero::Docker.alerady_run? || Pero::Docker.run(Pero::Docker.build(version))
    end

    def apply(port=8140)
      serve_master(@options["puppet-version"]) do
        begin
          tmpdir=(0...8).map{ (65 + rand(26)).chr }.join
          Pero.log.info "start forwarding port:#{port}"


          in_ssh_forwarding(port) do |host, ssh|
            puppet_cmd = "puppet agent --no-daemonize --onetime #{parse_puppet_option(@options)} --server localhost"
            Pero.log.info "#{host}:puppet cmd[#{puppet_cmd}]"
            cmd = "unshare -m -- /bin/bash -c 'install -o puppet -d /tmp/puppet/#{tmpdir} && \
                           mount --bind /tmp/puppet/#{tmpdir} #{@options["ssl-dir"]} && \
                           #{puppet_cmd}'"
            ssh.exec!(specinfra.build_command(cmd))  do |channel, stream, data|
                             Pero.log.info "#{host}:#{data.chomp}" if stream == :stdout && data.chomp != ""
                           end
            ssh.exec!(specinfra.build_command("rm -rf /tmp/puppet/#{tmpdir}"))
          end
        rescue => e
          Pero.log.error "puppet apply error:#{e.inspect}"
        end
      end

      name = if @options["node-name"].empty?
               specinfra.run_command("hostname").stdout.chomp
             else
               @options["node-name"]
             end
      Pero::History::Attribute.new(name, specinfra.get_config(:host), @options).save
    end

    def parse_puppet_option(options)
      ret = ""
      %w(noop verbose).each do |n|
        ret << " --#{n}" if options[n]
      end
      ret << " --tags #{options["tags"].join(",")}" if options["tags"]
      ret
    end

    def in_ssh_forwarding(port)
      options = specinfra.get_config(:ssh_options)

      if !Net::SSH::VALID_OPTIONS.include?(:strict_host_key_checking)
        options.delete(:strict_host_key_checking)
      end

      Net::SSH.start(
        specinfra.get_config(:host),
        options[:user],
        options
      ) do |ssh|
        ssh.forward.remote(port, 'localhost', 8140)
        yield specinfra.get_config(:host), ssh
      end
    end
  end
end
