# One-click phobos (`controlPlane = phobos-console`)

Instantiate the profile with any number of worker nodes (`machineNum`), proxy nodes (`machinePNum`), the single
Global-SC node, and `numGNB` / `numUE`. When `ins0vm:~/PHOBOS_READY` appears, phobos-console is running on the
controller VM (port 8090; from outside `ssh -L 8090:localhost:8090` through node0) with the emulation deployed.

## Flow

| where | what | script |
|---|---|---|
| every node | kernel, fake_tsc, VM, NAT, k0s, slot checker (unchanged compute-server flow) | `build_kernel.sh`, `build_proxy.sh`, `build_globalsc.sh` |
| node0, Step 7 | copy `scripts/phobos/` into the controller VM, start `controller_setup.sh` detached | `build_kernel.sh` |
| controller VM | 1 wait until controller + (machineNum) dilated workers + proxies + globalsc are Ready | `controller_setup.sh` |
| | 2 clone phobos-console, phobos-5g, openairinterface5g (profile branches) | |
| | 3 every hypervisor of a dilated VM: NAT timeouts + early `nf_conntrack` load | `host_prep.sh` |
| | 3 every dilated VM: SCTP, reserved nFAPI ports, core dumps, quiet console, `/opt/phobos-ue` | `vm_prep.sh` |
| | 4 build the UE bundle (nr-uesoftmodem + plugins + AWGN curves) and the proxy in an ubuntu:22.04 pod on the last proxy node; stage to every VM / every proxy node | `build_artifacts.sh` |
| | 5 `console.yaml` from the live cluster (workers, slot-checker components, proxy node/IP, core node, N6 gateway) | `gen_console_yaml.py` |
| | 6 Open5GS + DN on the core VM (manifests templated), subscribers for max(1000, numUE) UEs | |
| | 7 console venv (Python 3.12 via uv), systemd unit `phobos-console`, start | |
| | 8 preflight, then the console's own deploy job: numGNB x numUE | |

Every step is idempotent and marked in `~/.phobos/<step>.done`; re-running
`~/phobos-setup/controller_setup.sh <same args>` resumes after the last finished step. Log: `~/.phobos/setup.log`.

## Size assumptions (none fixed)

* VM workers = nodes labelled `dilated=true` (hostnames `ins<k>vm`, addresses `10.2.<k+1>.2`); their hypervisors
  `10.1.<k+1>.1` become the Global-SC components (globalsc derives the component id from the third octet).
* Proxy nodes = `proxy-<i>` (`10.3.<i+1>.1`); the experiment's proxy pod runs on `proxy-0`, the build on the last one.
* Global-SC = node `globalsc`, `10.4.1.1` (always one).
* The core VM is the first dilated worker; its DN gateway is `10.2.<n>.1`.

## Changes still needed outside this repo (before this is truly one-click)

1. **Push the phobos sources.** The controller clones `ujjwalpawar/{phobos-console, phobos-5g, openairinterface5g}`
   at the profile's branches; work that is only local (uncommitted) is not deployed.
2. **phobos-console QA scripts** still hard-code the 3-VM testbed: `qa/heal.sh` (VM/hypervisor maps),
   `qa/stage-ue.sh`, `qa/watchdog.sh` (VM IPs), `qa/stage-proxy.sh` (proxy-0 only). They should read
   `settings.workers` / `globalsc.components` like the console and preflight already do.
3. **phobos-console `systemd/phobos-console.service`** hard-codes `/users/uzzu`; this setup writes its own unit.
4. **phobos-5g `k8s/local/open5gs.yaml`, `open5gs-dn.yaml`** hard-code `ins1vm` / `10.2.2.2`; this setup templates
   them, the repo should take the core node/IP as parameters.
5. **CPU pinning**: Global-SC and each proxy get a whole machine, so their fixed cores (globalsc core 18, proxy pod
   `taskset -c 19-23`) only need machines with >= 19 / >= 24 cores. The worker nodes pin the VM's vCPUs to 2..52
   (>= 56 CPUs) or 2..24 (>= 32) and the slot checker to core 2.
6. **Private repos** (`chronos-kernel`, `fake_tsc`) need the GitHub user/token parameters, as before.
