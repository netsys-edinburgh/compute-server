#!/usr/bin/env bash
# One-click phobos: from a freshly provisioned compute-server cluster to a running phobos-console with the emulation
# deployed.  Runs inside the controller VM (ins0vm) as ubuntu.  Size-agnostic: every count/address is discovered.
#
#   controller_setup.sh <machine_num> <proxy_num> <num_gnb> <num_ue> <github_user> <github_token> \
#                       [console_branch] [phobos5g_branch] [oai_branch]
#
# machine_num = hypervisor nodes incl. node0 (as build_kernel.sh's $3); the dilated VM workers are ins1vm..ins<m-1>vm.
# Steps are idempotent (~/.phobos/<step>.done); re-running resumes after the last completed step.
set -euo pipefail
MACHINE_NUM=$1 PROXY_NUM=$2 NUM_GNB=$3 NUM_UE=$4 GH_USER=${5:-} GH_TOKEN=${6:-}
B_CONSOLE=${7:-main} B_P5G=${8:-new-oai-port} B_OAI=${9:-phobos-ue}
H=/home/ubuntu
CONSOLE=$H/phobos-console P5G=$H/phobos-5g OAI=$H/openairinterface5g
STATE=$H/.phobos; mkdir -p "$STATE"
LOG=$STATE/setup.log; exec > >(tee -a "$LOG") 2>&1
HERE=$(cd "$(dirname "$0")" && pwd)
export KUBECONFIG=$H/admin.conf
K=kubectl; command -v kubectl >/dev/null || K="sudo k0s kubectl"
SSHO="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $H/.ssh/id_rsa"
step() { [ -f "$STATE/$1.done" ] && { echo "== $1: done before"; return 1; }; echo; echo "== $1 ($(date '+%F %T'))"; return 0; }
done_() { touch "$STATE/$1.done"; }
url() { [ -n "$GH_TOKEN" ] && echo "https://$GH_USER:$GH_TOKEN@github.com/$1.git" || echo "https://github.com/$1.git"; }
retry() { local n=0; until "$@"; do n=$((n+1)); [ $n -ge 5 ] && return 1; sleep $((n*10)); done; }

# 1. cluster complete: controller + (MACHINE_NUM-1) dilated workers + PROXY_NUM proxies + globalsc, all Ready
if step cluster; then
  want_w=$((MACHINE_NUM - 1)); want=$((1 + want_w + PROXY_NUM + 1))
  for i in $(seq 1 720); do
    ready=$($K get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
    w=$($K get nodes -l dilated=true --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
    [ "$ready" -ge "$want" ] && [ "$w" -ge "$want_w" ] && break
    [ $((i % 12)) -eq 1 ] && echo "waiting for nodes: $ready/$want Ready ($w/$want_w dilated workers)"
    sleep 10
  done
  [ "$ready" -ge "$want" ] || { echo "FATAL: only $ready/$want nodes Ready after 2 h"; $K get nodes; exit 1; }
  done_ cluster
fi
WORKERS=$($K get nodes -l dilated=true -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}')
PROXIES=$($K get nodes --no-headers -o custom-columns=N:.metadata.name | grep '^proxy-' | sort -t- -k2 -n)
echo "workers: $WORKERS | proxies: $(echo $PROXIES)"

# 2. sources
if step clone; then
  sudo apt-get install -yqq git python3 python3-venv curl >/dev/null || true
  [ -d $CONSOLE/.git ] || retry git clone -q -b "$B_CONSOLE" "$(url ujjwalpawar/phobos-console)" $CONSOLE
  [ -d $P5G/.git ]     || retry git clone -q -b "$B_P5G" "$(url ujjwalpawar/phobos-5g)" $P5G
  [ -d $OAI/.git ]     || retry git clone -q -b "$B_OAI" --depth 1 "$(url ujjwalpawar/openairinterface5g)" $OAI
  done_ clone
fi

# 3. host preparation: every hypervisor of a dilated VM (root) and every dilated VM
if step hosts; then
  for v in $WORKERS; do
    hv="10.1.$(echo $v | cut -d. -f3).1"
    ssh $SSHO root@$hv 'bash -s' < "$HERE/host_prep.sh"
    ssh $SSHO ubuntu@$v 'sudo bash -s' < "$HERE/vm_prep.sh"
  done
  done_ hosts
fi

# 4. build + stage the UE bundle (all VMs) and the proxy (all proxy nodes)
ART=$STATE/artifacts
if step build; then
  BUILD_NODE=$(echo $PROXIES | awk '{print $NF}')          # the last proxy: proxy-0 runs the experiment's proxy pod
  KUBECTL="$K" bash "$HERE/build_artifacts.sh" $OAI $P5G $ART "$BUILD_NODE"
  done_ build
fi
if step stage; then
  for v in $WORKERS; do
    tar -C $ART/ue -cf - . | ssh $SSHO ubuntu@$v 'sudo mkdir -p /opt/phobos-ue && sudo tar -C /opt/phobos-ue -xf - && sudo chown -R ubuntu:ubuntu /opt/phobos-ue'
  done
  for p in $PROXIES; do
    n=${p#proxy-}; pip="10.3.$((n + 1)).1"
    ssh $SSHO root@$pip 'mkdir -p /tmp/phobos-k8s/bin && cat > /tmp/phobos-k8s/bin/.proxy.new && chmod 755 /tmp/phobos-k8s/bin/.proxy.new && mv -f /tmp/phobos-k8s/bin/.proxy.new /tmp/phobos-k8s/bin/proxy' < $ART/proxy/proxy
  done
  done_ stage
fi

# 5. console configuration from the live cluster
if step config; then
  cp $H/admin.conf $CONSOLE/.kubeconfig
  INFO=$(python3 "$HERE/gen_console_yaml.py" $CONSOLE $P5G --numgnb $NUM_GNB --numue $NUM_UE --kubectl "$K")
  echo "$INFO" > $STATE/cluster.json; echo "$INFO"
  done_ config
fi
CORE=$(python3 -c "import json;print(json.load(open('$STATE/cluster.json'))['core'])")
CORE_IP=$(python3 -c "import json;print(json.load(open('$STATE/cluster.json'))['core_ip'])")

# 6. 5G core (Open5GS) + DN on the core VM, subscribers for every UE
if step core; then
  mkdir -p $P5G/k8s/local/out
  for f in open5gs.yaml open5gs-dn.yaml; do        # templated: the manifests name ins1vm / 10.2.2.2
    sed -e "s/nodeName: ins1vm/nodeName: $CORE/" -e "s/10\.2\.2\.2/$CORE_IP/g" $P5G/k8s/local/$f > $P5G/k8s/local/out/$f
    $K apply -f $P5G/k8s/local/out/$f
  done
  $K wait --for=condition=Ready pod/open5gs --timeout=900s
  $K wait --for=condition=Ready pod/dn --timeout=600s
  N=$(( NUM_UE > 1000 ? NUM_UE : 1000 ))
  (cd $P5G/k8s/local && KC="$K" retry bash open5gs-subscribers.sh $N)
  done_ core
fi

# 7. console: venv (Python 3.12 via uv: the focal VM ships 3.8), systemd unit, start
if step console; then
  command -v uv >/dev/null || { curl -LsSf https://astral.sh/uv/install.sh | sh; }
  export PATH=$H/.local/bin:$PATH
  (cd $CONSOLE && uv venv -q --python 3.12 .venv && uv pip install -q --python .venv/bin/python -r requirements.txt -r requirements-dev.txt)
  sudo tee /etc/systemd/system/phobos-console.service >/dev/null <<UNIT
[Unit]
Description=phobos 5G emulation console
After=network-online.target k0scontroller.service
Wants=network-online.target

[Service]
User=ubuntu
WorkingDirectory=$CONSOLE
Environment=KUBECONFIG=$CONSOLE/.kubeconfig
ExecStart=$CONSOLE/bin/phobos-console
Restart=on-failure
RestartSec=3
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload && sudo systemctl enable --now phobos-console
  for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8090/)" = 200 ] && break; sleep 3; done
  done_ console
fi

# 8. preflight, then the profile's emulation (numGNB x numUE) -- the console's own deploy job
if step preflight; then
  (cd $CONSOLE && KUBECONFIG=$CONSOLE/.kubeconfig .venv/bin/python -m pytest -m preflight -o addopts= -q tests/test_preflight.py) | tail -3 \
    || echo "WARNING: preflight reported problems (see above); continuing"
  done_ preflight
fi
if step deploy; then
  J=$(curl -s -X POST http://127.0.0.1:8090/api/deploy -H 'Content-Type: application/json' \
       -d "{\"gnbs\": $NUM_GNB, \"ues\": $NUM_UE, \"split_ues_over_gnbs\": true, \"label\": \"one-click\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  echo "deploy job $J"
  for i in $(seq 1 720); do
    s=$(curl -s http://127.0.0.1:8090/api/jobs/$J | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')
    [ "$s" != running ] && break; sleep 10
  done
  curl -s http://127.0.0.1:8090/api/jobs/$J | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["state"]);[print(" ",e["msg"]) for e in d["events"][-3:]]'
  [ "$s" = done ] || { echo "FATAL: deploy job $J ended $s"; exit 1; }
  done_ deploy
fi
IP=$(hostname -I | awk '{print $1}')
cat > $H/PHOBOS_READY <<READY
phobos is ready ($(date '+%F %T')).
  console:   http://$IP:8090  (ssh -L 8090:localhost:8090 to node0 / ins0vm from outside)
  cluster:   $(cat $STATE/cluster.json)
  emulation: $NUM_GNB gNB(s) x $NUM_UE UE(s) deployed (job in the console's Jobs tab)
  logs:      $LOG ; console: journalctl -u phobos-console
READY
cat $H/PHOBOS_READY
