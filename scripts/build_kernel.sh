#!/bin/bash
# Builds the kernel from source, installs it, and builds the fake_tsc module after reboot

# Redirect output to log file
exec >> /local/build.log
exec 2>&1

# Color output
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'
if ! test -t 1; then
    GREEN=""
    BLUE=""
    NC=""
fi

function step_log() {
    echo ""
    echo "====================[ $1 ]===================="
    date
    if [ -n "$2" ]; then
        echo ""
        echo "$2"
    fi
    echo ""
}

GITHUB_TOKEN="$1"
GITHUB_USERNAME="$2"
MACHINE_NUM="$3"
INSTANCE_ID="$4"
MACHINE_PNUM="$5"
NUM_GNB="$6"
NUM_UE="$7"
CONTROL_PLANE="${8:-chronos-auto-deploy}"   # chronos-auto-deploy | phobos-console (one-click phobos, Step 7)
PHOBOS_CONSOLE_BRANCH="${9:-main}"
PHOBOS_5G_BRANCH="${10:-new-oai-port}"
PHOBOS_OAI_BRANCH="${11:-phobos-ue}"

step_log "Number of arguments: $#"
step_log "GitHub token: $GITHUB_TOKEN"
step_log "GitHub username: $GITHUB_USERNAME"
step_log "Number of Machines: $MACHINE_NUM"
step_log "Number of Proxy Machines: $MACHINE_PNUM"
step_log "Instance ID: $INSTANCE_ID"
step_log "Number of gNB: $NUM_GNB"
step_log "Number of UE: $NUM_UE"
step_log "Control plane: $CONTROL_PLANE"

# Shared lock-tolerant / retrying apt + download wrappers. These hard-fail loudly on
# exhaustion of their per-occurrence budget, which (since this script has no `set -e`)
# aborts the script before any `.done` marker is written for a failed step.
source /local/repository/scripts/retry_helpers.sh
# Shared experiment-key handling (node-local key, system ssh_config, guest
# authorized_keys set, guest password lockout).
source /local/repository/scripts/experiment_ssh_key.sh


USER_HOME="/users/$(whoami)"
echo "Number of machines in this experiments are ${MACHINE_NUM}"
kernel_repo="ujjwalpawar/chronos-kernel"
cad="andrewferguson/chronos-auto-deploy"
tsc_repo="ujjwalpawar/fake_tsc"
kernel_link="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${kernel_repo}.git"
cad_link="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${cad}.git"
tsc_link="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${tsc_repo}.git"
VM_NAME="ins${INSTANCE_ID}vm"
INTERNAL_SUBNET=$((1 +INSTANCE_ID)) # 122,123,124,…
INTERNAL_IP="10.2.${INTERNAL_SUBNET}.2"
NET_GW_IP="10.2.${INTERNAL_SUBNET}.1"
RANGE_START="10.2.${INTERNAL_SUBNET}.2"
RANGE_END="10.2.${INTERNAL_SUBNET}.254"
SSH_OPTS="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"

################################################################################
# Step 1: Kernel Build
################################################################################
CPU_VENDOR=$(lscpu | grep "^Vendor ID:" | awk -F ' ' '{ print $3 }')
[ "$CPU_VENDOR" != "GenuineIntel" ] && {
  echo "Not an Intel CPU"
  echo "Skipping building the custom kernel"
  touch /local/.kernel_done
  touch /local/.rebooted
  touch /local/.tsc_done
  # Record *why* Step 2 was skipped, so later steps can tell "this node has no
  # dilated-TSC support" apart from "Step 2 should have run and did not".
  #
  # This is the normal path for the controller: ManagerHardware is d6515, which
  # is AMD EPYC, so node0 never builds the custom kernel, never loads
  # custom_tsc, and therefore never gets /dev/shm/my-little-shared-memory. It
  # does not need them -- values.yaml has dilateFirstNode: False and globalsc's
  # component list starts at 10.1.2.1, so the controller is not a dilated
  # component. Step 5 and verify_node.sh key off this marker instead of
  # demanding artifacts that cannot exist here.
  touch /local/.tsc_skipped
}
if [ ! -f "/local/.kernel_done" ]; then
    step_log "Installing kernel build dependencies"
    apt_get_update_soft
    apt_get_retry install build-essential git libncurses-dev bison flex libssl-dev libelf-dev dwarves ripgrep

    step_log "Cloning kernel repo to ~/chronos-kernel"
    git_clone_retry "${kernel_link}" "${USER_HOME}/chronos-kernel" --quiet
    cd "${USER_HOME}/chronos-kernel"

    step_log "Copying current kernel config to .config"
    cp "/boot/config-$(uname -r)" .config

    step_log "Disabling/enabling kernel config options"
    scripts/config --disable SYSTEM_TRUSTED_KEYS
    scripts/config --disable SYSTEM_REVOCATION_KEYS
    scripts/config --disable VIDEO_OV01A10
    scripts/config --enable NETFILTER_XTABLES
    scripts/config --enable NETFILTER_XT_MARK
    scripts/config --enable NETFILTER_XT_TARGET_MARK
    scripts/config --enable PREEMPT_RT_FULL
    scripts/config --disable DEBUG_INFO_BTF

    step_log "Running olddefconfig"
    make olddefconfig

    step_log "Building the kernel"
    make -j"$(nproc)"

    step_log "Installing kernel modules"
    sudo make INSTALL_MOD_STRIP=1 modules_install
    sudo make install

    step_log "Updating grub"
    sudo update-grub

    
    ################################################################################
    # Step 1.5: Configure tuned for core isolation (core 2–55)
    ################################################################################
    step_log "Installing tuned and configuring for CPU isolation (core 2–55)"
    apt_get_retry install tuned

    sudo ln -sf /boot/grub/grub.cfg /etc/grub2.cfg

    export line to grub.d/00_tuned
    echo 'echo "export tuned_params"' | sudo tee -a /etc/grub.d/00_tuned

    echo "isolated_cores=2-55" | sudo tee /etc/tuned/realtime-variables.conf

    sudo sed -i '/^cmdline_realtime=/d' /usr/lib/tuned/realtime/tuned.conf

    # If [bootloader] section does not exist, append it
    if ! grep -q "^\[bootloader\]" /usr/lib/tuned/realtime/tuned.conf; then
        echo -e "\n[bootloader]" | sudo tee -a /usr/lib/tuned/realtime/tuned.conf
    fi

    # Append the new cmdline_realtime under [bootloader]
    sudo sed -i '/^\[bootloader\]/a cmdline_realtime=+isolcpus=${managed_irq}${isolated_cores} nohz_full=${isolated_cores} rcu_nocbs=${isolated_cores} nosoftlockup' /usr/lib/tuned/realtime/tuned.conf

    # Activate realtime profile
    sudo tuned-adm profile realtime

    step_log "Mark kernel done and reboot"
    touch /local/.kernel_done
    touch /local/.rebooted
    sudo reboot
    exit 0
fi

################################################################################
# Step 2: After Reboot, build & insert fake_tsc
################################################################################

if [ -f "/local/.kernel_done" ] && [ -f "/local/.rebooted" ] && [ ! -f "/local/.tsc_done" ]; then
    step_log "After reboot: building and inserting fake_tsc module"
    # NOTE: /local/.rebooted is cleared at the END of this block, not here. It is
    # this block's own entry condition, so clearing it up front meant a crash
    # part-way through (the gNB build OOMs these nodes regularly) left the node
    # unable to re-enter Step 2 *and* unable to reach Step 3 -- permanently stuck
    # with neither marker set.

    cd "${USER_HOME}"
    if [ ! -d "fake_tsc" ]; then
        git_clone_retry "${tsc_link}" "${USER_HOME}/fake_tsc"
    fi
    cd fake_tsc

    if [ -f init.c ]; then
            step_log "Compiling and running init.c"
            gcc init.c -o init

    fi

    if [ -f shared.c ]; then
        step_log "Compiling shared.c"
        gcc shared.c -o shared
    fi

    step_log "Building fake_tsc module"
    make

    # Persistent home for everything the boot-time units execute. Deliberately
    # NOT /local/repository, which CloudLab re-clones on every boot -- that is
    # what deleted the compiled slot checker and nodes.json after every reboot.
    sudo mkdir -p /local/chronos/bin /local/chronos/etc

    step_log "Installing custom_tsc for automatic load at every boot"
    # Kernel modules do not survive a reboot and the bare `insmod` here only ever
    # ran on first provision. Install it where modprobe can find it by name and
    # declare both the boot-time load and its ordering against KVM.
    sudo install -D -m 0644 custom_tsc.ko "/lib/modules/$(uname -r)/extra/custom_tsc.ko"
    sudo depmod -a
    sudo install -D -m 0644 /local/repository/scripts/chronos-tsc.conf \
        /etc/modules-load.d/chronos-tsc.conf
    sudo install -D -m 0644 /local/repository/scripts/chronos-tsc-modprobe.conf \
        /etc/modprobe.d/chronos-tsc.conf

    step_log "Loading custom_tsc ahead of KVM"
    sudo rmmod kvm_intel || true
    sudo rmmod kvm || true
    lsmod | grep -q '^custom_tsc' || sudo modprobe custom_tsc
    sudo modprobe kvm
    sudo modprobe kvm_intel

    # The module's init creates /dev/shm/my-little-shared-memory; tsc-init then
    # writes its initial contents. Both are lost on reboot (tmpfs), which is why
    # chronos-tsc-init.service re-runs this every boot.
    step_log "Initialising the custom_tsc shared-memory region"
    sudo install -m 0755 init /local/chronos/bin/tsc-init
    sudo /local/chronos/bin/tsc-init

    step_log "Installing chronos-tsc-init.service"
    sudo install -D -m 0644 /local/repository/scripts/chronos-tsc-init.service \
        /etc/systemd/system/chronos-tsc-init.service
    sudo systemctl daemon-reload
    sudo systemctl enable chronos-tsc-init.service

    apt_get_retry install -qq libsctp-dev lksctp-tools zlib1g-dev
    sudo modprobe sctp
    step_log "fake_tsc module inserted"
    sudo lsmod | grep custom_tsc || echo "⚠️ Warning: custom_tsc not in lsmod"
    sudo dmesg | tail -n 20

    step_log "Building slotcheckerservice into /local/chronos/bin"
    cp /local/repository/scripts/slotcheckerservice.c ./
    # Build to a temp path then rename. mv within one filesystem is atomic, so an
    # interrupted or failed compile can never leave a partial binary at the path
    # the service executes.
    if sudo gcc -pthread slotcheckerservice.c -o /local/chronos/bin/.slotcheckerservice.tmp; then
        sudo mv -f /local/chronos/bin/.slotcheckerservice.tmp /local/chronos/bin/slotcheckerservice
    else
        sudo rm -f /local/chronos/bin/.slotcheckerservice.tmp
        echo "❌ FATAL: slotcheckerservice build failed"; exit 1
    fi
    sudo install -m 0755 /local/repository/scripts/start_slotchecker.sh \
        /local/chronos/bin/start_slotchecker.sh

    # Guard on the artifacts, not merely on having reached the end of the block.
    # This script deliberately runs without `set -e`, so without these checks a
    # failed install or compile would still be recorded as a completed step.
    [ -x /local/chronos/bin/tsc-init ] \
        || { echo "❌ FATAL: tsc-init missing after Step 2"; exit 1; }
    [ -x /local/chronos/bin/slotcheckerservice ] \
        || { echo "❌ FATAL: slotcheckerservice missing after Step 2"; exit 1; }
    [ -f "/lib/modules/$(uname -r)/extra/custom_tsc.ko" ] \
        || { echo "❌ FATAL: custom_tsc.ko not installed into /lib/modules"; exit 1; }

    rm -f /local/.rebooted
    touch /local/.tsc_done
fi

################################################################################
# Step 3: VM setup — uvt-kvm create ► virsh set MAC ► 固定 IP (DHCP host 条目)
################################################################################
# Preconditions
#   – /local/.tsc_done exists
#   – /local/.vm_setup_done NOT exists
################################################################################
if [ -f "/local/.tsc_done" ] && [ ! -f "/local/.vm_setup_done" ]; then
    step_log "Installing virtualization tools and creating VM (uvt-kvm + static MAC)"

    # 1. Packages
    apt_get_update_soft
    apt_get_retry install qemu-kvm libvirt-daemon-system libvirt-clients \
                          bridge-utils virtinst uvtool

    step_log "Changing default storage location"
    sudo /local/repository/scripts/change_storage.sh
    # 2. Sync cloud image (once per host)
    step_log "Syncing Ubuntu cloud image"
    retry_cmd "sync focal cloud image" \
        sudo uvt-simplestreams-libvirt sync --source https://cloud-images.ubuntu.com/daily/ release=focal arch=amd64
    sudo virsh net-start default
    # 3. Names & deterministic IP/MAC
    sudo virsh pool-destroy  uvtool 
    sudo virsh pool-edit     uvtool  

    sudo virsh pool-build   uvtool
    sudo virsh pool-start   uvtool
    sudo virsh pool-autostart uvtool
    sudo chown -R libvirt-qemu:kvm /storage/uvtool      # in case anything already exists
    sudo chmod 2770               /storage/uvtool       # setgid bit → new files get group=kvm

    sudo setfacl -d -m g:kvm:rwx  /storage/uvtool
    
    echo "/storage/uvtool/** rwk," | sudo tee /etc/apparmor.d/local/abstractions/libvirt-qemu
    sudo systemctl reload apparmor

    step_log "VM  = ${VM_NAME}"
    step_log "Int = ${INTERNAL_IP}"

    step_log "Preparing the shared experiment SSH key before VM creation"
    materialize_experiment_key \
        || { echo "❌ FATAL: could not materialize the experiment SSH key"; exit 1; }
    install_shared_experiment_key \
        || { echo "❌ FATAL: could not install the node-local shared experiment key"; exit 1; }
    build_guest_authorized_keys \
        || { echo "❌ FATAL: could not build the guest authorized_keys set"; exit 1; }

    # 4. Create VM (uvt-kvm, DHCP)
    #
    # Deliberately no --password. Passing one makes cloud-init write
    # /etc/ssh/sshd_config.d/50-cloud-init.conf containing
    # "PasswordAuthentication yes", which overrides the cloud image's own
    # "PasswordAuthentication no" in 60-cloudimg-settings.conf, because sshd
    # takes the first value it sees across a lexically ordered sshd_config.d.
    # The "backup" password was therefore the very thing switching password
    # auth on. Omitting it is what actually makes the guest key-only.
    if ! sudo uvt-kvm create "${VM_NAME}" \
            release=focal arch=amd64 \
            --cpu 51 --memory 114096 \
            --ssh-public-key-file "${CHRONOS_GUEST_AUTH_KEYS}" --disk 200; then
        echo "❌ uvt-kvm create failed, aborting"; exit 1
    fi

    # uvt-kvm starts the domain immediately, using a stock CPU model that still
    # advertises rdtscp. On a node running the custom kernel with custom_tsc.ko
    # loaded, that guest dies about 100 seconds in with
    #   KVM internal error. Suberror: 4 / vmx: unexpected exit reason 0x33
    # (exit reason 51 == EXIT_REASON_RDTSCP, faulting on 0f 01 f9), and libvirt
    # leaves the domain paused forever. Kill it before it gets anywhere, so the
    # first real boot is the patched rdtscp-free one below and cloud-init only
    # ever runs once, on a VM that can actually survive to the end of it.
    step_log "Stopping ${VM_NAME} before it boots on an unpatched CPU model"
    sudo virsh destroy "${VM_NAME}" 2>/dev/null || true

     step_log "Modifying /etc/libvirt/qemu/$VM_NAME.xml to patch CPU and clock settings"
            VM_XML="/etc/libvirt/qemu/${VM_NAME}.xml"
            TMP_XML="/tmp/${VM_NAME}.xml.modified"

            sudo cp "$VM_XML" "$VM_XML.bak"

            step_log "Deleting two lines after </features>"
            sudo awk '
            /<\/features>/ {
                print;
                skip = 2;
                next;
            }
            skip > 0 {
                skip--;
                next;
            }
            { print }
            ' "$VM_XML" > "$TMP_XML"

            step_log "Inserting new <cpu> and <clock> blocks"
            sudo sed -i "/<\/features>/a \
        <cpu mode='host-passthrough' check='none'>\\
          <feature policy='disable' name='rdtscp'/>\\
          <feature policy='disable' name='tsc-deadline'/>\\
        </cpu>\\
        <clock offset='localtime'>\\
          <timer name='rtc' present='no' tickpolicy='delay'/>\\
          <timer name='pit' present='no' tickpolicy='discard'/>\\
          <timer name='hpet' present='no'/>\\
          <timer name='kvmclock' present='yes'/>\\
        </clock>" "$TMP_XML"

step_log "pinning cpu"
        # Ensure <vcpu> = 54 and placement='static'
NUM_CPU=$(lscpu | grep "^CPU(s):" | awk -F ' ' '{ print $2 }')
[ "$NUM_CPU" -lt "32" ] && {
  echo "<32 CPU cores"
  echo "Aborting"
  exit 1
}
SEQVAR="22"
EMULATORPIN_CPUSET="23"
IOTHREADPIN_CPUSET="24"
VCPUSCHED="22"
[ "$NUM_CPU" -ge "56" ] && {
  echo ">= 56 CPU cores"
  SEQVAR="50"
  EMULATORPIN_CPUSET="53"
  IOTHREADPIN_CPUSET="54"
  VCPUSCHED="50"
}
block=$(
  echo "  <iothreads>1</iothreads>"
  echo "  <cputune>"
  for i in $(seq 0 $SEQVAR); do
    printf "    <vcpupin vcpu='%d' cpuset='%d'/>\n" "$i" "$((i+2))"
  done
  echo "    <emulatorpin cpuset='$EMULATORPIN_CPUSET'/>"
  echo "    <iothreadpin iothread='1' cpuset='$IOTHREADPIN_CPUSET'/>"
  echo "    <vcpusched vcpus='0'    scheduler='fifo' priority='1'/>"
  echo "    <vcpusched vcpus='1-$VCPUSCHED' scheduler='fifo' priority='1'/>"
  echo "    <emulatorsched scheduler='fifo' priority='1'/>"
  echo "    <iothreadsched iothreads='1' scheduler='fifo' priority='1'/>"
  echo "  </cputune>"
)
sudo sed -i "/<vcpu placement='static'>51<\/vcpu>/r /dev/stdin" "$TMP_XML" <<<"$block"

            step_log "Replacing $VM_NAME.xml with modified version and redefining domain"
            sudo mv "$TMP_XML" "$VM_XML"
            sudo virsh define "$VM_XML"

            sudo virsh destroy "$VM_NAME" 2>/dev/null || true
            sudo virsh start "$VM_NAME"


    # --------------------------------------------------------------------- #
        # 3. Waiting domifaddr return real MAC/IP
        # --------------------------------------------------------------------- #
        step_log "Waiting domifaddr for ${VM_NAME}"
        for i in {1..30}; do
            domif=$(sudo virsh domifaddr "$VM_NAME" 2>&1)
            if echo "$domif" | sudo grep -q 'ipv4'; then
                break
            fi
            sleep 2
        done
        step_log "domifaddr output" "$domif"

    REAL_MAC=$(echo "$domif" | awk '/ipv4/ {print $2}')

    if [ -z "$REAL_MAC" ] ; then
            echo "❌ domifaddr did not return MAC, aborting"; exit 1
        fi
################################################################################
# Step 3。5   virsh set MAC ► static IP (DHCP host 条目)
################################################################################
################################################################################

    step_log "Edit the default network"
    NET_XML="/etc/libvirt/qemu/networks/default.xml"

    if ! sudo grep -q "$REAL_MAC" "$NET_XML"; then
      step_log "Adding DHCP host entry for ${VM_NAME} in default network"
      sudo sed -i -E "
        # -- bridge / gateway ----------------------------------------------------
        0,/<ip address=/{
            s@<ip address='[0-9.]+' netmask='255\.255\.255\.0'>@<ip address='${NET_GW_IP}' netmask='255.255.0.0'>@
        }

        # -- DHCP range ----------------------------------------------------------
        /<range /{
            s@start='[0-9.]+'@start='${RANGE_START}'@
            s@end='[0-9.]+'@end='${RANGE_END}'@
        }

        # -- purge any old host entry for this VM --------------------------------
        /<dhcp>/,/<\/dhcp>/{
            /<host .*name='${VM_NAME}'.*\/>/d
        }

        # -- add fresh host reservation -----------------------------------------
        /<range /a\\
            <host mac='${REAL_MAC}' name='${VM_NAME}' ip='${INTERNAL_IP}'/>
        "  "$NET_XML"

    fi
    step_log "stopping ${VM_NAME} to change ip address"
    sudo virsh shutdown "${VM_NAME}"

    for i in {1..200}; do
        state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
        echo "⏳ Waiting for ${VM_NAME} to shut off... (${i}/20) → state: ${state}"
        sudo virsh shutdown "${VM_NAME}"
        [[ "$state" == "shut off" ]] && break
        sleep 1
    done

    if [[ "$state" != "shut off" ]]; then
        echo "⚠️  ${VM_NAME} did not shut off in time; forcing shutdown"
        sudo virsh destroy "${VM_NAME}"
        sleep 2
    fi
    step_log "Restarting libvirt default network"
    sudo virsh net-destroy default

    step_log "Restarting libvirtd service to apply changes"
    sudo service libvirtd restart

    sudo systemctl restart libvirtd

    sudo virsh net-start  default
    sleep 10
    # 8. start VM


    step_log "Starting ${VM_NAME} again"
    sudo virsh start "${VM_NAME}"
    for i in {1..200}; do
        state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
        echo "⏳ Waiting for ${VM_NAME} to shut off... (${i}/20) → state: ${state}"
        [[ "$state" == "running" ]] && break
        sleep 1
    done
    sleep 30
    domif_output2=$(sudo virsh domifaddr "${VM_NAME}" 2>&1)
    step_log "Assigned IP address from domifaddr for ${VM_NAME}" "${domif_output2}"

    # 9. Wait until DHCP assigns the fixed IP
    step_log "Waiting for ${VM_NAME} to get IP ${INTERNAL_IP}"
    for i in {1..30}; do
        ip_list=$(sudo virsh domifaddr "${VM_NAME}" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1)
        for ip in $ip_list; do
            if [[ "$ip" == "$INTERNAL_IP" ]]; then
                cur_ip="$ip"
                break 2  # Exit both loops
            fi
        done
        sleep 2
    done
    [[ "${cur_ip}" != "${INTERNAL_IP}" ]] && echo "⚠️  VM IP is ${cur_ip:-N/A}, expected ${INTERNAL_IP}"

    step_log "Waiting for ${VM_NAME} to accept key-based SSH on ${INTERNAL_IP}"
    final_guest_ready=""
    for i in {1..60}; do
        if ssh ${SSH_OPTS} -oConnectTimeout=10 ubuntu@"${INTERNAL_IP}" true 2>/dev/null; then
            final_guest_ready=1
            break
        fi
        sleep 5
    done

    if [ -z "${final_guest_ready}" ]; then
        echo "❌ ${VM_NAME} never accepted key-based SSH on ${INTERNAL_IP} after restart, aborting"
        exit 1
    fi

    step_log "Locking ${VM_NAME} to key-only SSH"
    enforce_guest_key_only_ssh "ubuntu@${INTERNAL_IP}" \
        || { echo "❌ FATAL: ${VM_NAME} still accepts SSH password authentication"; exit 1; }

    # 10. Done
#    sudo virsh net-destory default
#    sleep 2
#    sudo virsh net-start default
#    sleep 2
#    sudo virsh shutdown "${VM_NAME}"
#    sleep 5
#    sudo service libvirtd restart
#    sleep 5
#    sudo virsh start "${VM_NAME}"

    # The VM definition and its disk persist across a reboot, but libvirt will
    # not start a domain that is not marked autostart -- so every reboot used to
    # leave insNvm 'shut off' with nothing to bring it back. This one command is
    # what moves "VM running" from an every-boot action to a once-only install.
    step_log "Marking ${VM_NAME} to autostart at boot"
    sudo virsh autostart "${VM_NAME}"
    sudo virsh dominfo "${VM_NAME}" | grep -qE '^Autostart:[[:space:]]*enable' \
        || { echo "❌ FATAL: could not enable autostart for ${VM_NAME}"; exit 1; }

    touch /local/.vm_setup_done
fi
#sudo virsh destroy "${VM_NAME}"
#sudo reboot
################################################################################
# Step 4: Exposed-IP alias  &  NAT rules (runs once per host)
################################################################################
# Preconditions
#   – /local/.vm_setup_done   exists  (VM created)
#   – /local/.net_setup_done  NOT     exists (NAT not yet written)
################################################################################
if [ -f "/local/.vm_setup_done" ] && [ ! -f "/local/.net_setup_done" ]; then
    step_log "Setting alias IP and NAT rules for this host"
    state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
    echo "⏳ Checking state of ${VM_NAME} to shut off... (${i}/20) → state: ${state}"
    [[ "$state" == "shut off" ]] && sudo virsh start ${VM_NAME}
    for i in {1..200}; do
        state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
        echo "⏳ Waiting for ${VM_NAME} to start... (${i}/20) → state: ${state}"
        [[ "$state" == "running" ]] && break
        sleep 1
    done
    cd  /local/repository/scripts

    # Copy the two scripts chronos-net.service executes into the persistent tree.
    # They cannot be run from /local/repository at boot: CloudLab re-clones it on
    # every boot, so it is not guaranteed to exist or be complete by the time a
    # systemd unit fires.
    sudo mkdir -p /local/chronos/bin /local/chronos/etc
    sudo install -m 0755 /local/repository/scripts/add-secondary.sh /local/chronos/bin/add-secondary.sh
    sudo install -m 0755 /local/repository/scripts/set_ip.sh        /local/chronos/bin/set_ip.sh
    sudo install -m 0755 /local/repository/scripts/chronos-net.sh   /local/chronos/bin/chronos-net.sh

    step_log "Generating json"
    # Written outside the re-cloned repository so it survives a reboot. The
    # generator truncates, so this is safe to re-run.
    sudo /local/repository/scripts/generate_config.sh "$MACHINE_NUM" /local/chronos/etc/nodes.json
    [ -s /local/chronos/etc/nodes.json ] \
        || { echo "❌ FATAL: nodes.json was not generated"; exit 1; }
    sleep 5

    step_log "Adding ips"
    sudo /local/chronos/bin/add-secondary.sh
    sleep 5
    step_log "Adding IP TABLES"
    sudo /local/chronos/bin/set_ip.sh
    sleep 5

    step_log "Installing chronos-net.service"
    sudo install -D -m 0644 /local/repository/scripts/chronos-net.service \
        /etc/systemd/system/chronos-net.service
    sudo systemctl daemon-reload
    sudo systemctl enable chronos-net.service

    step_log "Using the injected experiment key for guest bootstrap"

    step_log "Copying script to add ip address"
    scp $SSH_OPTS /local/repository/scripts/add-secondary_vm.sh ubuntu@${INTERNAL_IP}:~/ \
        || { echo "❌ FATAL: could not copy add-secondary_vm.sh into ${VM_NAME}"; exit 1; }
    ssh $SSH_OPTS ubuntu@${INTERNAL_IP} "chmod +x /home/ubuntu/add-secondary_vm.sh" \
        || { echo "❌ FATAL: could not chmod add-secondary_vm.sh inside ${VM_NAME}"; exit 1; }
    step_log "calling copied script"

    ssh $SSH_OPTS ubuntu@${INTERNAL_IP}  "sudo /home/ubuntu/add-secondary_vm.sh" \
        || { echo "❌ FATAL: could not run add-secondary_vm.sh inside ${VM_NAME}"; exit 1; }

    # Guest addresses and routes are runtime-only too, and are lost whenever the
    # VM restarts -- including a plain `virsh start` with no host reboot. Enable
    # the equivalent unit inside the guest so it re-applies them itself.
    step_log "Installing chronos-guest-net.service inside ${VM_NAME}"
    scp $SSH_OPTS /local/repository/scripts/chronos-guest-net.service ubuntu@${INTERNAL_IP}:/tmp/ \
        || { echo "❌ FATAL: could not copy chronos-guest-net.service into ${VM_NAME}"; exit 1; }
    ssh $SSH_OPTS ubuntu@${INTERNAL_IP} \
        "sudo install -D -m 0644 /tmp/chronos-guest-net.service /etc/systemd/system/chronos-guest-net.service \
         && sudo systemctl daemon-reload && sudo systemctl enable chronos-guest-net.service" \
        || { echo "❌ FATAL: could not enable chronos-guest-net.service inside ${VM_NAME}"; exit 1; }

    touch /local/.net_setup_done
fi

################################################################################
# Step 5a: Clone chronos-auto-deploy into the controller VM and prep it for
# download_images.sh, before k0s itself gets installed
################################################################################
# Preconditions
#   – /local/.vm_setup_done and /local/.net_setup_done exist (VM up, networked)
#   – /local/.cad_cloned does NOT exist
#   – $INSTANCE_ID must be 0 (only the controller VM runs download_images.sh)
#
# This has to happen before k0s is installed (Step 5) because
# master_install_k0.sh calls download_images.sh as its last step, and that
# script lives inside this clone and needs values.yaml patched with this
# experiment's real node counts first.
################################################################################
if [ -f "/local/.vm_setup_done" ] && [ -f "/local/.net_setup_done" ] && [ ! -f "/local/.cad_cloned" ] && [ "$INSTANCE_ID" -eq 0 ]; then
    step_log "Preparing chronos-auto-deploy inside the controller VM (${VM_NAME})"

    # retry_helpers.sh is normally copied in by Step 5, below -- but this
    # block now runs *before* Step 5, so it needs its own copy first.
    scp $SSH_OPTS /local/repository/scripts/retry_helpers.sh ubuntu@"${INTERNAL_IP}":/tmp/ \
        || { echo "❌ FATAL: could not copy retry_helpers.sh into ${VM_NAME}"; exit 1; }

    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" \
        "source /tmp/retry_helpers.sh && apt_get_update_soft && apt_get_retry install parallel" \
        || { echo "❌ FATAL: could not install parallel inside ${VM_NAME}"; exit 1; }

    step_log "Cloning chronos-auto-deploy (branch main)"
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" \
        "source /tmp/retry_helpers.sh && git_clone_retry '${cad_link}' /home/ubuntu/chronos-auto-deploy --quiet -b main" \
        || { echo "❌ FATAL: could not clone chronos-auto-deploy into ${VM_NAME}"; exit 1; }

    step_log "Syncing values.yaml node counts to this experiment's real topology"
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" \
        "sed -i'' -E 's/^(numberGNBNodes:)[[:space:]]*[0-9]+/\1 $((MACHINE_NUM - 1))/' /home/ubuntu/chronos-auto-deploy/values.yaml && sed -i'' -E 's/^(numberProxyNodes:)[[:space:]]*[0-9]+/\1 ${MACHINE_PNUM}/' /home/ubuntu/chronos-auto-deploy/values.yaml && sed -i'' -E 's/^(numberGNB:)[[:space:]]*[0-9]+/\1 ${NUM_GNB}/' /home/ubuntu/chronos-auto-deploy/values.yaml && sed -i'' -E 's/^(numberUE:)[[:space:]]*[0-9]+/\1 ${NUM_UE}/' /home/ubuntu/chronos-auto-deploy/values.yaml" \
        || { echo "❌ FATAL: could not patch values.yaml node counts inside ${VM_NAME}"; exit 1; }

    step_log "Copying the shared experiment SSH key into the controller VM"
    scp $SSH_OPTS "${HOME}/.ssh/id_rsa" ubuntu@"${INTERNAL_IP}":/home/ubuntu/.ssh/experiment_key \
        || { echo "❌ FATAL: could not copy experiment key into ${VM_NAME}"; exit 1; }
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "chmod 600 /home/ubuntu/.ssh/experiment_key" \
        || { echo "❌ FATAL: could not chmod experiment key inside ${VM_NAME}"; exit 1; }

    touch /local/.cad_cloned
fi

################################################################################
# Step 5: Install k0s inside the VM
################################################################################
# Preconditions
#   – /local/.vm_setup_done exists   (the VM has been created and given a fixed IP)
#   – /local/.k0s_in_vm_done does NOT exist  (k0s has not yet been installed inside the VM)
#   – for the controller only, /local/.cad_cloned must already exist (Step 5a)
################################################################################

if [ -f "/local/.vm_setup_done" ] && [ -f "/local/.net_setup_done" ] && [ ! -f "/local/.k0s_in_vm_done" ] \
    && ( [ "$INSTANCE_ID" -ne 0 ] || [ -f "/local/.cad_cloned" ] ); then
    step_log "Installing k0s inside VM ${VM_NAME} (${INTERNAL_IP})"

    # 1. Copy the k0s helper scripts (and the shared retry helpers they source) into
    #    /tmp inside the guest.
    step_log "Copying k0s install files to vm"
    scp $SSH_OPTS /local/repository/scripts/master_install_k0.sh ubuntu@"${INTERNAL_IP}":/tmp/
    scp $SSH_OPTS /local/repository/scripts/worker_install_k0.sh ubuntu@"${INTERNAL_IP}":/tmp/
    scp $SSH_OPTS /local/repository/scripts/common_k0.sh ubuntu@"${INTERNAL_IP}":/tmp/
    scp $SSH_OPTS /local/repository/scripts/retry_helpers.sh ubuntu@"${INTERNAL_IP}":/tmp/
    step_log "Copying shared experiment key into the guest default identity path"
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "mkdir -p /home/ubuntu/.ssh && chmod 700 /home/ubuntu/.ssh"
    scp $SSH_OPTS "${HOME}/.ssh/id_rsa" ubuntu@"${INTERNAL_IP}":/home/ubuntu/.ssh/id_rsa
    scp $SSH_OPTS "${HOME}/.ssh/id_rsa.pub" ubuntu@"${INTERNAL_IP}":/home/ubuntu/.ssh/id_rsa.pub
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "chmod 600 /home/ubuntu/.ssh/id_rsa && chmod 644 /home/ubuntu/.ssh/id_rsa.pub"
    
    # 3. Run the relevant install script inside the guest. A guest-side failure must
    #    abort here so the `.k0s_in_vm_done` marker below is NOT written for a node
    #    that never actually joined (the iteration-3 silent-failure mode).
    if [ "$INSTANCE_ID" -eq 0 ]; then
        # Controller VM
        ROLE_SCRIPT="/tmp/master_install_k0.sh"
        ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "bash $ROLE_SCRIPT" \
            || { echo "❌ FATAL: master (controller) k0s install failed inside ${VM_NAME}"; exit 1; }
    else
        ROLE_SCRIPT="/tmp/worker_install_k0.sh"
        CONTROLLER_VM_IP="10.2.1.2"   # internal IP of the controller VM
        ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "bash $ROLE_SCRIPT" \
            || { echo "❌ FATAL: worker k0s install/join failed inside ${VM_NAME}"; exit 1; }
    fi
    # The slot checker is part of the dilated-TSC chain, so it only applies on a
    # node that actually built it in Step 2. On a non-Intel node (the controller,
    # ManagerHardware=d6515) Step 2 is skipped wholesale, and installing the unit
    # there just leaves a service that can never start: it mmaps
    # /dev/shm/my-little-shared-memory, which only custom_tsc creates. That is
    # what used to happen -- node0 sat in 'failed' from provisioning onward and
    # nothing ever reported it.
    if [ -f "/local/.tsc_skipped" ]; then
        step_log "Skipping slot checker install: no dilated-TSC support on this CPU"
    else
        # The binary itself is built once in Step 2, into /local/chronos/bin. It
        # used to be compiled here into /local/repository/scripts, which CloudLab
        # re-clones on every boot -- so the enabled unit came back after a reboot
        # with its ExecStart target deleted and crash-looped into 'failed'.
        [ -x /local/chronos/bin/slotcheckerservice ] \
            || { echo "❌ FATAL: /local/chronos/bin/slotcheckerservice missing (Step 2 did not complete)"; exit 1; }
        sudo install -D -m 0644 /local/repository/scripts/slotcheckerservice.service \
            /etc/systemd/system/slotcheckerservice.service
        sudo systemctl daemon-reload
        sudo systemctl enable slotcheckerservice
        sudo systemctl start slotcheckerservice
    fi

    touch /local/.k0s_in_vm_done
fi

################################################################################
# Step 6: Deploy the core and setup auto-deployment scripts
################################################################################
# Preconditions
#   – /local/.k0s_in_vm_done exists   (k0s has been installed inside the VM)
#   – /local/.audo_deploy_setup does NOT exist  (auto deployment scripts have not yet been setup)
#   - $INSTANCE_ID must be 0 (this is the node hosting the k8s master node)
################################################################################
if [ -f "/local/.k0s_in_vm_done" ] && [ ! -f "/local/.audo_deploy_setup" ] && [ "$INSTANCE_ID" -eq 0 ]; then
    step_log "Deploying the core and setting up the auto-deployment scripts"

    # chronos-auto-deploy + parallel are already set up by Step 5a, above,
    # so that download_images.sh (run from inside master_install_k0.sh, as
    # part of Step 5) has them available before k0s is even installed.

    step_log "Writing Chronos shell helpers to ~/.chronos"
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "cat > \$HOME/.chronos <<'EOF'
export KUBECONFIG=~/admin.conf

# Ubuntu's default .bashrc defines \`alias l=\"ls -CF\"\`. Bash expands aliases
# at parse time, so without this the \`l() {\` function definition below fails
# with \"syntax error near unexpected token '('\" (the alias gets expanded
# before the parser sees it as a function name).
unalias l 2>/dev/null

s() {
  helm install --values values.yaml \$1 ./\$1/
}

ns() {
  helm uninstall \$1
}

k() {
  kubectl \"\$@\"
}

l() {
  kubectl logs \"\$@\"
}

p() {
  kubectl get pods \"\$@\"
}

pw() {
  kubectl get pods -o wide \"\$@\"
}
EOF
grep -qxF '[ -f ~/.chronos ] && source ~/.chronos' \$HOME/.bashrc || echo '[ -f ~/.chronos ] && source ~/.chronos' >> \$HOME/.bashrc"

    touch /local/.audo_deploy_setup
fi

################################################################################
# Step 7: One-click phobos (controlPlane = phobos-console)
################################################################################
# Preconditions
#   - /local/.audo_deploy_setup exists (controller VM has k0s, the shared key, kubectl)
#   - /local/.phobos_started does NOT exist
#   - $INSTANCE_ID must be 0 and $CONTROL_PLANE must be phobos-console
# Copies scripts/phobos into the controller VM and starts controller_setup.sh there, detached: it waits for every
# other node to join, prepares hypervisors/VMs, builds and stages the UE bundle and proxy, deploys Open5GS,
# installs and starts phobos-console, runs preflight and deploys numGNB x numUE.  Progress:
# ins0vm:~/.phobos/setup.log ; result: ins0vm:~/PHOBOS_READY.  Re-running resumes after the last finished step.
################################################################################
if [ -f "/local/.audo_deploy_setup" ] && [ ! -f "/local/.phobos_started" ] && [ "$INSTANCE_ID" -eq 0 ] \
    && [ "$CONTROL_PLANE" = "phobos-console" ]; then
    step_log "Starting one-click phobos inside the controller VM (${VM_NAME})"
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "mkdir -p /home/ubuntu/phobos-setup" \
        || { echo "FATAL: cannot reach ${VM_NAME}"; exit 1; }
    scp $SSH_OPTS /local/repository/scripts/phobos/* ubuntu@"${INTERNAL_IP}":/home/ubuntu/phobos-setup/ \
        || { echo "FATAL: could not copy scripts/phobos into ${VM_NAME}"; exit 1; }
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "chmod +x /home/ubuntu/phobos-setup/*.sh /home/ubuntu/phobos-setup/*.py && \
        setsid nohup bash /home/ubuntu/phobos-setup/controller_setup.sh ${MACHINE_NUM} ${MACHINE_PNUM} ${NUM_GNB} ${NUM_UE} \
        '${GITHUB_USERNAME}' '${GITHUB_TOKEN}' ${PHOBOS_CONSOLE_BRANCH} ${PHOBOS_5G_BRANCH} ${PHOBOS_OAI_BRANCH} \
        > /home/ubuntu/phobos-setup/run.out 2>&1 < /dev/null &" \
        || { echo "FATAL: could not start controller_setup.sh in ${VM_NAME}"; exit 1; }
    touch /local/.phobos_started
fi

################################################################################
# Step 5: All done
################################################################################
step_log "All steps already completed. Nothing to do."
