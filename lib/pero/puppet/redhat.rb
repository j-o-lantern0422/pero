module Pero
  class Puppet
    class Redhat < Base
      def main_release
        os_info[:release].split(/\./)[0]
      end

      def install(version)
        release_package, package_name = if Gem::Version.new("5.0.0") > Gem::Version.new(version)
          ["puppetlabs-release-el-#{main_release}.noarch.rpm", "puppet"]
        elsif Gem::Version.new("6.0.0") > Gem::Version.new(version)
          ["puppet5-release-el-#{main_release}.noarch.rpm", "puppet-agent"]
        else
          ["puppet6-release-el-#{main_release}.noarch.rpm", "puppet-agent"]
        end

        installed = run_specinfra(:check_package_is_installed, release_package.gsub(/-el.*/, ''))
        unless installed

          Pero.log.info "install package #{release_package}"
          run_specinfra(:remove_package, "puppet5-release")
          run_specinfra(:remove_package, "puppet6-release")
          raise "failed package install:#{release_package}" if specinfra.run_command("rpm -ivh https://yum.puppetlabs.com/#{release_package}").exit_status != 0
        end

        unless run_specinfra(:check_package_is_installed, package_name, version)
          Pero.log.info "install package #{package_name}-#{version}"
          raise "failed package uninstall:#{package_name}" if run_specinfra(:remove_package, package_name).exit_status != 0
          raise "failed package install:#{package_name} version #{version}" if run_specinfra(:install_package, package_name, version).exit_status != 0
        end
      end
    end
  end
end
