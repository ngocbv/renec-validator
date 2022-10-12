# server-based syntax
# ======================
# Defines a single server with a list of roles and multiple properties.
# You can define all roles on a single server, or split them:

set :ssh_options, { forward_agent: true, user: "ubuntu", keys: %w(~/.ssh/ngocbv-renec.pem) }
server "54.85.162.144", user: "ubuntu", roles: %w{primary}
set :data_full_path, "/home/ubuntu/renec-cluster"
set :renec_version, "1.9.29"
set :is_genesis, false

namespace :deploy do
  after :finishing, :install_all do
    on roles(:primary) do |host|
      within current_path do
        install_nvme
        install_renec_tool_suite
        create_renec_service
        create_renec_sys_tuner_service
        restart_renec_sys_tuner
        start_renec_validator
        install_system_info_service
      end
    end
  end
end

def install_renec_tool_suite
  execute "sh -c \"$(curl -sSfL https://s3.amazonaws.com/release.renec.foundation/v#{fetch(:renec_version)}/install)\""
  execute "export PATH='/home/ubuntu/.local/share/renec/install/active_release/bin:$PATH'"

  return puts("Renec installed") if test("[ -d /home/ubuntu/.config/renec ]")
  execute "sed -i '1 i\\export PATH=\"/home/ubuntu/.local/share/renec/install/active_release/bin:$PATH\"' /home/ubuntu/.bashrc"
end

def install_nvme
  return puts("Nvme installed") if test("[ -d #{fetch(:data_full_path)} ]")

  # ssh to server and run lsblk to get the device name
  devices = [
    "/dev/nvme1n1",
    "/dev/nvme2n1",
    "/dev/nvme3n1",
    "/dev/nvme4n1"
  ]
  label = "renec_raid"
  execute :sudo, "mdadm --create --verbose /dev/md0 --level=0 --name=#{label} --raid-devices=#{devices.size} #{devices.join(' ')}"
  execute :sudo, "mkfs.ext4 -F -L #{label} /dev/md0"
  execute :sudo, "mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf"
  execute :sudo, "update-initramfs -u"
  execute :mkdir, "mkdir -p #{fetch(:data_full_path)}"
  execute :sudo, "mount LABEL=#{label} #{fetch(:data_full_path)}"
  execute :sudo, "bash -c 'echo LABEL=#{label}       #{fetch(:data_full_path)}   ext4    defaults,nofail        0       2  >> /etc/fstab'"
  execute :sudo, "chown ubuntu:ubuntu #{fetch(:data_full_path)}"
end

def renec_service_definition
  template_path = File.expand_path("../../../coin-service-conf/renec.service.erb", __FILE__)
  template = ERB.new(File.read(template_path))
  namespace = OpenStruct.new(
    start_command: fetch(:is_genesis) ? start_renec_genesis_validator_command : start_renec_validator_command
  )
  template.result(namespace.instance_eval { binding })
end

def create_renec_service
  upload! StringIO.new(renec_service_definition), "#{current_path}/renec.service"
  execute :sudo, "cp #{current_path}/renec.service /etc/systemd/system/"
end

def start_renec_validator_command
  # Do not pass the --no-snapshot-fetch parameter on your initial boot as it's not possible to boot the node all the way
  # from the genesis block. Instead boot from a snapshot first and then add the --no-snapshot-fetch parameter for reboots.
  first_start = !test("[ -d #{fetch(:data_full_path)}/snapshot/ ]")
  "/home/ubuntu/.local/share/renec/install/active_release/bin/renec-validator \
    --identity #{fetch(:data_full_path)}/keypairs/validator-keypair.json \
    --vote-account #{fetch(:data_full_path)}/keypairs/validator-vote-account.json \
    --known-validator HBXxbWBy6JRhvT61r4QxFg1FBQdMxeAbcv3q12XWH3xd \
    --only-known-rpc \
    --ledger #{fetch(:data_full_path)}/ledger \
    --gossip-port 8001 \
    --rpc-port 8888 \
    --enable-rpc-transaction-history \
    --enable-cpi-and-log-storage \
    --require-tower \
    --dynamic-port-range 8000-8020 \
    --entrypoint 34.228.109.119:8001 \
    --expected-genesis-hash 6bWMx8nFapGtRQdc5r1Dw5UimiX7YkJLKi6E4VC4LsHS \
    --full-rpc-api \
    --account-index program-id \
    --account-index spl-token-owner \
    --incremental-snapshots \
    --account-index spl-token-mint #{first_start ? "" : "--no-snapshot-fetch"}"
end

def start_renec_genesis_validator_command
  "/home/ubuntu/.local/share/renec/install/active_release/bin/renec-validator \
    --identity #{fetch(:data_full_path)}/keypairs/validator-keypair.json \
    --vote-account #{fetch(:data_full_path)}/keypairs/validator-vote-account.json \
    --no-genesis-fetch \
    --ledger #{fetch(:data_full_path)}/ledger \
    --no-wait-for-vote-to-start-leader \
    --tpu-coalesce-ms 50 \
    --gossip-port 8001 \
    --rpc-port 8888 \
    --enable-rpc-transaction-history \
    --enable-cpi-and-log-storage \
    --require-tower \
    --full-rpc-api \
    --account-index program-id \
    --account-index spl-token-owner \
    --incremental-snapshots \
    --account-index spl-token-mint"
end

def start_renec_validator
  execute :sudo, "systemctl enable renec.service"
  execute :sudo, "systemctl restart renec.service"
end

def renec_sys_tuner_service_definition
  template_path = File.expand_path("../../../coin-service-conf/renec-sys-tuner.service.erb", __FILE__)
  template = ERB.new(File.read(template_path))
  start_command = "/home/ubuntu/.local/share/renec/install/active_release/bin/renec-sys-tuner --user ubuntu"
  namespace = OpenStruct.new(
    start_command: start_command
  )
  template.result(namespace.instance_eval { binding })
end

def create_renec_sys_tuner_service
  upload! StringIO.new(renec_sys_tuner_service_definition), "#{current_path}/renec-sys-tuner.service"
  execute :sudo, "cp #{current_path}/renec-sys-tuner.service /etc/systemd/system/"
end

def restart_renec_sys_tuner
  execute :sudo, "systemctl enable renec-sys-tuner.service"
  execute :sudo, "systemctl restart renec-sys-tuner.service"
end