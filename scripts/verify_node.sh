#!/usr/bin/env bash
# verify_node.sh <instance-id> — fail-loud post-setup verification for an
# inner-VM node (node0..machineNum).
#
# Runs as the FINAL startup service on every outer node that hosts an inner VM.
# Its purpose is to make a silently-incomplete node impossible: if the inner VM
# was never created, or was created but never joined the k0s cluster, this exits
# non-zero so CloudLab flags the node as failed instead of the experiment
# reporting "ready" while a controller/UE-hosting VM is actually missing. That
# silent mode is exactly what a transient /local/repository clone failure caused
# — the whole node was skipped and nothing noticed until the cluster was used.
#
# Every check targets THIS node's own inner VM only, so the verification is not
# racy against other nodes provisioning in parallel.
set -uo pipefail

INSTANCE_ID="${1:?usage: verify_node.sh <instance-id>}"
VM_NAME="ins${INSTANCE_ID}vm"
INTERNAL_IP="10.2.$((1 + INSTANCE_ID)).2"   # fixed inner IP assigned in build_kernel.sh
CONTROLLER_IP="10.2.1.2"                     # inner IP of the controller VM (ins0vm)
SSH_OPTS="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oConnectTimeout=15"
# How long to wait for the node to report Ready (CNI/kubelet registration lag).
: "${VERIFY_READY_TIMEOUT:=300}"

source /local/repository/scripts/retry_helpers.sh

fail() { echo "❌ FATAL(verify ${VM_NAME}): $*" >&2; exit 1; }
log()  { echo "[verify ${VM_NAME}] $*"; }

# 1. The inner VM must exist and be running.
sudo virsh list --state-running --name 2>/dev/null | grep -qx "${VM_NAME}" \
    || fail "domain is not in running state (virsh)"
log "domain running ✓"

# 2. The k0s install/join step must have completed on this node (marker written
#    only after a successful in-guest install/join in build_kernel.sh).
[ -f /local/.k0s_in_vm_done ] || fail "k0s install/join step never completed (marker missing)"
log "k0s join step completed ✓"

# 3. The correct k0s service must be active inside the guest.
if [ "${INSTANCE_ID}" -eq 0 ]; then
    SVC=k0scontroller; NODE_NAME=controller
else
    SVC=k0sworker;     NODE_NAME="${VM_NAME}"
fi
ssh ${SSH_OPTS} ubuntu@"${INTERNAL_IP}" "systemctl is-active ${SVC}" 2>/dev/null | grep -qx active \
    || fail "${SVC} is not active inside the guest"
log "${SVC} active inside guest ✓"

# 4. Authoritative: the controller must report this node Ready within the budget.
WAIT="sudo k0s kubectl wait --for=condition=Ready node/${NODE_NAME} --timeout=${VERIFY_READY_TIMEOUT}s"
if [ "${INSTANCE_ID}" -eq 0 ]; then
    ssh ${SSH_OPTS} ubuntu@"${INTERNAL_IP}" "${WAIT}" \
        || fail "controller did not become Ready within ${VERIFY_READY_TIMEOUT}s"
else
    deadline=$((SECONDS + VERIFY_READY_TIMEOUT))
    while true; do
        remaining=$((deadline - SECONDS))
        [ "${remaining}" -gt 0 ] || fail "controller never observed ${NODE_NAME} register within ${VERIFY_READY_TIMEOUT}s"

        if out=$(ssh ${SSH_OPTS} ubuntu@"${INTERNAL_IP}" \
            "ssh ${SSH_OPTS} ubuntu@${CONTROLLER_IP} 'sudo k0s kubectl get node ${NODE_NAME} -o name'" 2>&1); then
            break
        fi

        if grep -q 'NotFound' <<<"${out}"; then
            sleep 5
            continue
        fi

        if is_retryable_controller_transport_error "${out}"; then
            sleep 5
            continue
        fi

        fail "could not query controller for ${NODE_NAME}: ${out}"
    done
    log "controller observed ${NODE_NAME} register ✓"

    remaining=$((deadline - SECONDS))
    [ "${remaining}" -gt 0 ] || fail "controller observed ${NODE_NAME} register but it did not become Ready within ${VERIFY_READY_TIMEOUT}s"
    while true; do
        remaining=$((deadline - SECONDS))
        [ "${remaining}" -gt 0 ] || fail "controller observed ${NODE_NAME} register but it did not become Ready within ${VERIFY_READY_TIMEOUT}s"

        WAIT="sudo k0s kubectl wait --for=condition=Ready node/${NODE_NAME} --timeout=${remaining}s"
        if out=$(ssh ${SSH_OPTS} ubuntu@"${INTERNAL_IP}" \
            "ssh ${SSH_OPTS} ubuntu@${CONTROLLER_IP} '${WAIT}'" 2>&1); then
            break
        fi

        if is_retryable_controller_transport_error "${out}"; then
            sleep 5
            continue
        fi

        fail "controller observed ${NODE_NAME} register but readiness check failed: ${out}"
    done
fi
log "controller reports ${NODE_NAME} Ready ✓"

# 5. The Chronos runtime chain on the OUTER node. k0s Ready is not sufficient:
#    every check above passes on a node whose custom_tsc module is unloaded and
#    whose slot checker is dead, and such a node reports healthy while being
#    unable to take part in an experiment at all. globalsc reaches this node's
#    checker on the outer IP 10.1.$((INSTANCE_ID + 2)).1, so a silent failure
#    here surfaces only as "Still waiting for components" much later.
#
#    Skipped on a node with no dilated-TSC chain. build_kernel.sh writes
#    /local/.tsc_skipped when it bypasses the kernel/TSC build entirely -- the
#    controller, which is not a dilated component (dilateFirstNode: False;
#    globalsc's component list starts at 10.1.2.1), or an unsupported CPU vendor.
if [ -f /local/.tsc_skipped ]; then
    log "dilated-TSC chain not applicable on this CPU — skipping runtime-chain checks"
    echo "✅ verify OK: ${VM_NAME} is running and Ready in the k0s cluster"
    echo "   (no dilated-TSC chain on this node by design)"
    exit 0
fi

# Read /proc/modules directly rather than `lsmod | grep -q`. This script runs
# under `set -o pipefail`, and `grep -q` exits on its first match, closing the
# pipe while lsmod is still writing -- lsmod then takes SIGPIPE and the pipeline
# reports 141, so the check fails even though the module IS loaded. Whether that
# happens depends on how much output remains unwritten when grep exits, which
# makes it an intermittent false failure. No pipe, no race.
grep -q '^custom_tsc ' /proc/modules \
    || fail "custom_tsc module is not loaded (guest TSC would not be dilated)"
log "custom_tsc loaded ✓"

SHM=/dev/shm/my-little-shared-memory
[ -e "$SHM" ] || fail "$SHM missing (custom_tsc did not create its shared-memory region)"
SHM_SIZE=$(stat -c %s "$SHM" 2>/dev/null || echo 0)
[ "$SHM_SIZE" -eq 10000 ] || fail "$SHM is ${SHM_SIZE} bytes, expected 10000"
log "shared-memory region present ✓"

[ -x /local/chronos/bin/slotcheckerservice ] \
    || fail "/local/chronos/bin/slotcheckerservice missing or not executable"
log "slot checker binary present ✓"

# Bounded wait rather than an instant assertion: this script runs as the startup
# service immediately after build_kernel.sh starts the unit, so the process may
# not have bound its sockets yet. Without the wait this check is racy and fails
# provisioning on a node that is actually fine.
: "${VERIFY_SLOTCHECKER_TIMEOUT:=60}"
sc_deadline=$((SECONDS + VERIFY_SLOTCHECKER_TIMEOUT))
while true; do
    # Capture once and match against the string, for the same pipefail/SIGPIPE
    # reason as the /proc/modules check above -- `ss | grep -q` is racy here.
    ss_out=$(sudo ss -lnup 2>/dev/null || true)
    if systemctl is-active --quiet slotcheckerservice \
       && grep -q ':8080\b' <<<"$ss_out" \
       && grep -q ':4322\b' <<<"$ss_out"; then
        break
    fi
    [ "$SECONDS" -lt "$sc_deadline" ] || fail \
        "slotcheckerservice did not become active and bound to UDP 8080/4322 within ${VERIFY_SLOTCHECKER_TIMEOUT}s (state: $(systemctl is-active slotcheckerservice 2>&1))"
    sleep 3
done
log "slotcheckerservice active and listening on UDP 8080 and 4322 ✓"

echo "✅ verify OK: ${VM_NAME} is running and Ready in the k0s cluster,"
echo "   and this node's Chronos runtime chain (custom_tsc → shm → slot checker) is up"
