#!/usr/bin/env bash
# Build the phobos UE bundle (nr-uesoftmodem + the plugins it dlopens + AWGN BLER curves) and the nFAPI proxy in a
# throw-away ubuntu:22.04 pod (the RAN/proxy images are jammy too), on a node that is not dilated, and copy the
# results to <out>/ue and <out>/proxy.   Usage: build_artifacts.sh <oai dir> <phobos-5g dir> <out dir> <node>
set -euo pipefail
OAI=$1 P5G=$2 OUT=$3 NODE=$4
POD=phobos-build
K="${KUBECTL:-kubectl}"
mkdir -p "$OUT/ue/awgn" "$OUT/proxy"
$K delete pod $POD --ignore-not-found --wait=true >/dev/null
cat <<YAML | $K apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $POD, labels: {app: phobos-build}}
spec:
  nodeName: $NODE
  restartPolicy: Never
  containers:
  - {name: b, image: docker.io/library/ubuntu:22.04, command: [sleep, infinity]}
YAML
$K wait --for=condition=Ready pod/$POD --timeout=600s >/dev/null
echo "build: sources -> $POD on $NODE"
tar -C "$OAI" --exclude=.git --exclude=cmake_targets/ran_build -cf - . | $K exec -i $POD -- sh -c 'mkdir -p /src && tar -C /src -xf -'
tar -C "$P5G" --exclude=.git --exclude=build --exclude=k8s/local/out -cf - . | $K exec -i $POD -- sh -c 'mkdir -p /p5g && tar -C /p5g -xf -'
echo "build: OAI dependencies (build_oai -I) -- the long part"
$K exec $POD -- sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -yqq sudo git build-essential libsctp-dev zlib1g-dev >/dev/null &&
  cd /src/cmake_targets && ./build_oai -I --install-optional-packages >/tmp/deps.log 2>&1 || { tail -30 /tmp/deps.log; exit 1; }'
echo "build: nr-uesoftmodem"
$K exec $POD -- sh -c 'cd /src/cmake_targets && ./build_oai --nrUE -w SIMU --ninja >/tmp/ue.log 2>&1 || { tail -30 /tmp/ue.log; exit 1; }'
echo "build: proxy"
$K exec $POD -- sh -c 'cd /p5g && make -j"$(nproc)" all >/tmp/proxy.log 2>&1 || { tail -30 /tmp/proxy.log; exit 1; }; make test-mobility 2>&1 | tail -1'
B=/src/cmake_targets/ran_build/build
for f in nr-uesoftmodem libcoding.so libdfts.so libldpc.so libldpc_orig.so libparams_libconfig.so libparams_yaml.so \
         librf_emulator.so librfsimulator.so libvrtsim.so; do
  $K exec $POD -- cat "$B/$f" > "$OUT/ue/$f" 2>/dev/null || echo "build: note: $f not produced (optional plugin)"
done
chmod 755 "$OUT/ue/nr-uesoftmodem"
cp "$OAI"/openair1/SIMULATION/NR_PHY/BLER_SIMULATIONS/AWGN/AWGN_results/mcs*_awgn_5G.csv "$OUT/ue/awgn/"
$K exec $POD -- cat /p5g/build/proxy > "$OUT/proxy/proxy"; chmod 755 "$OUT/proxy/proxy"
sz=$(stat -c %s "$OUT/ue/nr-uesoftmodem"); [ "$sz" -gt 10000000 ] || { echo "build: UE binary too small ($sz)"; exit 1; }
sz=$(stat -c %s "$OUT/proxy/proxy"); [ "$sz" -gt 3000000 ] || { echo "build: proxy binary too small ($sz)"; exit 1; }
echo "build: done -- $(ls "$OUT/ue" | wc -l) UE files, $(ls "$OUT/ue/awgn" | wc -l) AWGN curves, proxy $(stat -c %s "$OUT/proxy/proxy") bytes"
$K delete pod $POD --wait=false >/dev/null
