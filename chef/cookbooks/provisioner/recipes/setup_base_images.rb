# Copyright 2011, Dell
# Copyright 2012, SUSE Linux Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied
# See the License for the specific language governing permissions and
# limitations under the License
#
# This recipe sets up the general environmnet needed to PXE boot
# other servers.

admin_ip = node.address.addr
domain_name = node["dns"].nil? ? node["domain"] : (node["dns"]["domain"] || node["domain"])
Chef::Log.info("Provisioner: raw server data #{ node["crowbar"]["provisioner"]["server"]}")
node.normal["crowbar"]["provisioner"]["server"]["name"]=node.name
v4addr=node.address("admin",IP::IP4)
v6addr=node.address("admin",IP::IP6)
node.normal["crowbar"]["provisioner"]["server"]["v4addr"]=v4addr.addr if v4addr
node.normal["crowbar"]["provisioner"]["server"]["v6addr"]=v6addr.addr if v6addr
node.normal["crowbar"]["provisioner"]["server"]["proxy"]="#{v4addr.addr}:8123"
web_port = node["crowbar"]["provisioner"]["server"]["web_port"]
use_local_security = node["crowbar"]["provisioner"]["server"]["use_local_security"]
provisioner_web="http://#{v4addr.addr}:#{web_port}"
node.normal["crowbar"]["provisioner"]["server"]["webserver"]=provisioner_web
os_token="#{node["platform"]}-#{node["platform_version"]}"
tftproot =  node["crowbar"]["provisioner"]["server"]["root"]
discover_dir="#{tftproot}/discovery"
pxecfg_dir="#{discover_dir}/pxelinux.cfg"
uefi_dir=discover_dir
pxecfg_default="#{pxecfg_dir}/default"

unless node["crowbar"]["provisioner"]["server"]["sledgehammer_kernel_params"]
  # FIXME: What is the purpose of this, really? If pxecfg_default does not exist
  # the root= parameters will not get appended to the kernel commandline. (Luckily
  # we don't need those with the SLES base sledgehammer)
  # Later on pxecfg_default will even be replace with a link to "discovery"
  # Probably this pxecfg_default check can go a way and we can just unconditionally
  # append the root= parameters?
  # ANSWER:  This hackery exists to automatically do The Right Thing in handling
  # CentOS 5 vs. CentOS 6 based sledgehammer images.
  sledge_args = Array.new
  sledge_args << "rootflags=loop"
  sledge_args << "initrd=initrd0.img"
  sledge_args << "root=live:/sledgehammer.iso"
  sledge_args << "rootfstype=auto"
  sledge_args << "ro"
  sledge_args << "liveimg"
  sledge_args << "rd_NO_LUKS"
  sledge_args << "rd_NO_MD"
  sledge_args << "rd_NO_DM"
  if node["crowbar"]["provisioner"]["server"]["use_serial_console"]
    sledge_args << "console=tty0 console=ttyS1,115200n8"
  end
  sledge_args << "provisioner.web=http://#{v4addr.addr}:#{web_port}"
  # This should not be hardcoded!
  sledge_args << "crowbar.web=http://#{v4addr.addr}:3000"
  sledge_args << "crowbar.dns.domain=#{node["crowbar"]["dns"]["domain"]}"
  sledge_args << "crowbar.dns.servers=#{node["crowbar"]["dns"]["nameservers"].join(',')}"

  node.normal["crowbar"]["provisioner"]["server"]["sledgehammer_kernel_params"] = sledge_args.join(" ")
end
append_line = node["crowbar"]["provisioner"]["server"]["sledgehammer_kernel_params"]

# By default, install the same OS that the admin node is running
# If the comitted proposal has a defualt, try it.
# Otherwise use the OS the provisioner node is using.

unless default = node["crowbar"]["provisioner"]["server"]["default_os"]
  node.normal["crowbar"]["provisioner"]["server"]["default_os"] = default = os_token
end

unless node.normal["crowbar"]["provisioner"]["server"]["repositories"]
  node.normal["crowbar"]["provisioner"]["server"]["repositories"] = Mash.new
end
node.normal["crowbar"]["provisioner"]["server"]["available_oses"] = Mash.new

# Generate the appropriate pxe and uefi config files for discovery
# These will only be used if we have not already discovered the system.
directory "#{pxecfg_dir}" do
  action :create
  recursive true
end

template "#{pxecfg_dir}/default" do
  mode 0644
  owner "root"
  group "root"
  source "default.erb"
  variables(:append_line => "#{append_line} crowbar.state=discovery",
            :install_name => "discovery",
            :initrd => "initrd0.img",
            :machine_key => node["crowbar"]["provisioner"]["machine_key"],
            :kernel => "vmlinuz0")
end

# Do uefi as well.
template "#{uefi_dir}/elilo.conf" do
  mode 0644
  owner "root"
  group "root"
  source "default.elilo.erb"
  variables(:append_line => "#{append_line} crowbar.state=discovery",
            :install_name => "discovery",
            :initrd => "initrd0.img",
            :machine_key => node["crowbar"]["provisioner"]["machine_key"],
            :kernel => "vmlinuz0")
end

package "syslinux"

ruby_block "Install pxelinux.0" do
  block do
    ["share","lib"].each do |d|
      next unless ::File.exists?("/usr/#{d}/syslinux/pxelinux.0")
      ::Kernel.system("cp /usr/#{d}/syslinux/pxelinux.0 #{discover_dir}")
    end
  end
  not_if do ::File.exists?("#{discover_dir}/pxelinux.0") end
end

bash "Install elilo as UEFI netboot loader" do
  code <<EOC
cd #{uefi_dir}
tar xzf '#{tftproot}/files/elilo-3.16-all.tar.gz'
mv elilo-3.16-x86_64.efi bootx64.efi
mv elilo-3.16-ia32.efi bootia32.efi
mv elilo-3.16-ia64.efi bootia64.efi
rm elilo*.efi elilo*.tar.gz || :
EOC
  not_if "test -f '#{uefi_dir}/bootx64.efi'"
end

node["crowbar"]["provisioner"]["server"]["supported_oses"].each do |os,params|
  web_path = "#{provisioner_web}/#{os}"
  admin_web = os_install_site = "#{web_path}/install"
  crowbar_repo_web="#{web_path}/crowbar-extra"
  os_dir="#{tftproot}/#{os}"
  os_codename=node["lsb"]["codename"]
  role="#{os}_install"
  initrd = params["initrd"]
  kernel = params["kernel"]

  # Don't bother for OSes that are not actaully present on the provisioner node.
  next unless (File.directory? os_dir and File.directory? "#{os_dir}/install") or
    ( node["crowbar"]["provisioner"]["server"]["online"] and params["online_mirror"])
   node.normal["crowbar"]["provisioner"]["server"]["available_oses"][os] = true

  # Index known barclamp repositories for this OS
  node.normal["crowbar"]["provisioner"]["server"]["repositories"][os] = Mash.new
  if File.exists? "#{os_dir}/crowbar-extra" and File.directory? "#{os_dir}/crowbar-extra"
    Dir.foreach("#{os_dir}/crowbar-extra") do |f|
      next unless File.symlink? "#{os_dir}/crowbar-extra/#{f}"
      node.normal["crowbar"]["provisioner"]["server"]["repositories"][os][f] = Mash.new
      case
      when os =~ /(ubuntu|debian)/
        bin="deb #{provisioner_web}/#{os}/crowbar-extra/#{f} /"
        src="deb-src #{provisioner_web}/#{os}/crowbar-extra/#{f} /"
         node.normal["crowbar"]["provisioner"]["server"]["repositories"][os][f][bin] = true if
          File.exists? "#{os_dir}/crowbar-extra/#{f}/Packages.gz"
         node.normal["crowbar"]["provisioner"]["server"]["repositories"][os][f][src] = true if
          File.exists? "#{os_dir}/crowbar-extra/#{f}/Sources.gz"
      when os =~ /(redhat|centos|suse)/
        bin="baseurl=#{provisioner_web}/#{os}/crowbar-extra/#{f}"
         node.normal["crowbar"]["provisioner"]["server"]["repositories"][os][f][bin] = true
        else
          raise ::RangeError.new("Cannot handle repos for #{os}")
      end
    end
  end

  if  node["crowbar"]["provisioner"]["server"]["online"]
    # This needs to be less fragile.
    Dir.glob("/opt/opencrowbar/*/crowbar.yml").each do |yml_file|
      bc = YAML.load_file(yml_file)
      if bc["debs"]
        bc["debs"]["repos"].each do |repo|
          unless node["crowbar"]["provisioner"]["server"]["repositories"][os]["online"]
            node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["online"] = Mash.new
          end
           node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["online"][repo] = true
        end if bc["debs"]["repos"]
        bc["debs"][os]["repos"].each do |repo|
          unless node["crowbar"]["provisioner"]["server"]["repositories"][os]["online"]
            node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["online"] = Mash.new
          end
          node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["online"][repo] = true
        end if (bc["debs"][os]["repos"] rescue nil)
      end if os =~ /(ubuntu|debian)/
      if bc["rpms"]
        bc["rpms"]["repos"].each do |repo|
          unless node["crowbar"]["provisioner"]["server"]["repositories"][os]["online"]
            node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["online"] = Mash.new
          end
          node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["online"][repo] = true
        end if bc["rpms"]["repos"]
        bc["rpms"][os]["repos"].each do |repo|
          unless node["crowbar"]["provisioner"]["server"]["repositories"][os]["online"]
            node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["online"] = Mash.new
          end
          node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["online"][repo] = true
        end if (bc["rpms"][os]["repos"] rescue nil)
      end if os =~ /(centos|redhat)/
    end

    if params["online_mirror"]
      directory "#{os_dir}/install/#{initrd.split('/')[0...-1].join('/')}" do
        recursive true
      end
      case
      when os =~ /^(ubuntu|debian)/
        raise ArgumentError.new("Cannot configure provisioner for online deploy of #{os}: missing codename") unless params["codename"]
        netboot_urls = {
          initrd => "#{params["online_mirror"]}/dists/#{params["codename"]}/main/installer-amd64/current/images/#{initrd.split('/')[1..-1].join('/')}",
          kernel => "#{params["online_mirror"]}/dists/#{params["codename"]}/main/installer-amd64/current/images/#{kernel.split('/')[1..-1].join('/')}"
        }
        os_install_site = params["online_mirror"]
      when os =~/^(centos|redhat)/
        netboot_urls = {
          initrd => "#{params["online_mirror"]}/os/x86_64/#{initrd}",
          kernel => "#{params["online_mirror"]}/os/x86_64/#{kernel}"
        }
        os_install_site = "#{params["online_mirror"]}/os/x86_64"
      else
        raise ArgumentError.new("Cannot configure provisioner for online deploy of #{os}: missing codepaths.")
      end
      netboot_urls.each do |k,v|
        bash "#{os}: fetch #{k}" do
          code <<EOC
set -x
export http_proxy=http://127.0.0.1:8123/
curl -sfL -o '#{os_dir}/install/#{k}.new' '#{v}' && \
mv '#{os_dir}/install/#{k}.new' '#{os_dir}/install/#{k}'
EOC
          not_if "test -f '#{os_dir}/install/#{k}'"
        end
      end
    end
  end

  replaces={
    '%os_site%'         => web_path,
    '%os_install_site%' => os_install_site
  }
  append = params["append"]

  # Sigh.  There has to be a more elegant way.
  replaces.each { |k,v|
    append.gsub!(k,v)
  }

  # If we were asked to use a serial console, arrange for it.
  if  node["crowbar"]["provisioner"]["server"]["use_serial_console"]
    append << " console=tty0 console=ttyS1,115200n8"
  end

  # If we were asked to use a serial console, arrange for it.
  if  node["crowbar"]["provisioner"]["server"]["use_serial_console"]
    append << " console=tty0 console=ttyS1,115200n8"
  end
  
  # Add per-OS base repos that may not have been added above.

  unless node["crowbar"]["provisioner"]["server"]["boot_specs"]
    node.normal["crowbar"]["provisioner"]["server"]["boot_specs"] = Mash.new
  end
  unless node["crowbar"]["provisioner"]["server"]["boot_specs"][os]
    node.normal["crowbar"]["provisioner"]["server"]["boot_specs"][os] = Mash.new
  end
  node.normal["crowbar"]["provisioner"]["server"]["boot_specs"][os]["kernel"] = "../#{os}/install/#{kernel}"
  node.normal["crowbar"]["provisioner"]["server"]["boot_specs"][os]["initrd"] = "../#{os}/install/#{initrd}"
  node.normal["crowbar"]["provisioner"]["server"]["boot_specs"][os]["os_install_site"] = os_install_site
  node.normal["crowbar"]["provisioner"]["server"]["boot_specs"][os]["kernel_params"] = append

  case
  when (/^ubuntu/ =~ os and File.exists?("#{tftproot}/#{os}/install/dists"))
     node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["base"] = { "#{provisioner_web}/#{os}/install" => true }
  when /^(suse)/ =~ os
     node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["base"] = { "baseurl=#{provisioner_web}/#{os}/install" => true }
  when /^(redhat|centos)/ =~ os
    # Add base OS install repo for redhat/centos
    if ::File.exists? "#{tftproot}/#{os}/install/repodata"
       node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["base"] = { "baseurl=#{provisioner_web}/#{os}/install" => true }
    elsif ::File.exists? "#{tftproot}/#{os}/install/Server/repodata"
       node.normal["crowbar"]["provisioner"]["server"]["repositories"][os]["base"] = { "baseurl=#{provisioner_web}/#{os}/install/Server" => true }
    end
  end
end

