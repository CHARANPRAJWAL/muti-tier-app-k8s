#!/usr/bin/env bash
#
# test-hpa.sh - Test Horizontal Pod Autoscaler for the multi-tier app
#
# This script generates sustained CPU load on backend pods to trigger HPA
# scaling, then monitors the scaling events in real time.
#
# Prerequisites:
#   - kubectl configured and pointing to the correct cluster
#   - Application deployed in the 'mtapp' namespace
#   - Metrics Server installed (kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml)
#
# Usage:
#   ./test-hpa.sh                          # test backend HPA (default)
#   ./test-hpa.sh frontend                 # test frontend HPA
#   ./test-hpa.sh backend 120              # custom duration in seconds
#   ./test-hpa.sh backend 90 200           # custom duration & concurrency

set -euo pipefail

NAMESPACE="mtapp"
TARGET="${1:-backend}"
DURATION="${2:-120}"
CONCURRENCY="${3:-100}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Preflight checks ────────────────────────────────────────────────
check_prerequisites() {
    log "Running preflight checks..."

    if ! command -v kubectl &>/dev/null; then
        err "kubectl not found. Please install it first."
        exit 1
    fi

    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        err "Namespace '$NAMESPACE' not found. Is the app deployed?"
        exit 1
    fi

    if ! kubectl get hpa -n "$NAMESPACE" "${TARGET}-hpa" &>/dev/null; then
        err "HPA '${TARGET}-hpa' not found in namespace '$NAMESPACE'."
        exit 1
    fi

    # Check if metrics-server is running
    if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
        warn "Metrics Server not detected in kube-system."
        warn "HPA will not scale without it. Install with:"
        echo "  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
        echo ""
        read -rp "Continue anyway? [y/N]: " choice
        [[ "$choice" =~ ^[Yy]$ ]] || exit 0
    fi

    log "All preflight checks passed."
}

# ── Show current state ──────────────────────────────────────────────
show_state() {
    echo ""
    echo -e "${CYAN}━━━ Current HPA State ━━━${NC}"
    kubectl get hpa -n "$NAMESPACE" "${TARGET}-hpa"
    echo ""
    echo -e "${CYAN}━━━ Current Pods ━━━${NC}"
    kubectl get pods -n "$NAMESPACE" -l app="$TARGET" -o wide
    echo ""
    echo -e "${CYAN}━━━ Pod Resource Usage ━━━${NC}"
    kubectl top pods -n "$NAMESPACE" -l app="$TARGET" 2>/dev/null || warn "Metrics not available yet."
    echo ""
}

# ── Determine endpoint for load ─────────────────────────────────────
get_load_endpoint() {
    if [[ "$TARGET" == "backend" ]]; then
        echo "/api/health"
    else
        echo "/"
    fi
}

# ── Generate load using a temporary pod ─────────────────────────────
start_load_generator() {
    local endpoint
    endpoint=$(get_load_endpoint)

    local service_url
    if [[ "$TARGET" == "backend" ]]; then
        service_url="http://backend-service:5000${endpoint}"
    else
        service_url="http://frontend-service:80${endpoint}"
    fi

    local pod_name="hpa-load-generator"

    # Clean up any existing load generator pod
    kubectl delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found=true &>/dev/null

    log "Starting load generator pod..."
    log "  Target:      ${TARGET}-service"
    log "  Endpoint:    $endpoint"
    log "  Duration:    ${DURATION}s"
    log "  Concurrency: $CONCURRENCY parallel requests"
    echo ""

    kubectl run "$pod_name" \
        -n "$NAMESPACE" \
        --image=busybox:1.36 \
        --restart=Never \
        --labels="purpose=hpa-test" \
        -- /bin/sh -c "
            echo 'Load generator started at \$(date)';
            end=\$((SECONDS + ${DURATION}));
            count=0;
            while [ \$SECONDS -lt \$end ]; do
                for i in \$(seq 1 ${CONCURRENCY}); do
                    wget -q -O /dev/null ${service_url} &
                done
                wait;
                count=\$((count + ${CONCURRENCY}));
                echo \"Sent \$count requests so far...\";
            done;
            echo 'Load generation complete at \$(date). Total requests: '\$count;
        "

    # Wait for pod to be running
    log "Waiting for load generator pod to start..."
    kubectl wait --for=condition=Ready pod/"$pod_name" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
    log "Load generator is running."
}

# ── Monitor HPA scaling ────────────────────────────────────────────
monitor_scaling() {
    log "Monitoring HPA and pod scaling (Ctrl+C to stop)..."
    echo ""

    local start_time=$SECONDS
    local check_interval=10
    local prev_replicas=0

    while true; do
        local elapsed=$(( SECONDS - start_time ))
        echo -e "${CYAN}━━━ [${elapsed}s elapsed] ━━━${NC}"

        # HPA status
        kubectl get hpa -n "$NAMESPACE" "${TARGET}-hpa" --no-headers 2>/dev/null | \
            while read -r name ref targets minp maxp replicas age; do
                echo -e "  HPA:      $name"
                echo -e "  Targets:  $targets"
                echo -e "  Replicas: ${GREEN}$replicas${NC} (min=$minp, max=$maxp)"
            done

        # Pod count
        local current_replicas
        current_replicas=$(kubectl get pods -n "$NAMESPACE" -l app="$TARGET" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$current_replicas" != "$prev_replicas" ]]; then
            echo -e "  Pods:     ${YELLOW}$prev_replicas -> $current_replicas (CHANGED)${NC}"
            prev_replicas=$current_replicas
        else
            echo -e "  Pods:     $current_replicas"
        fi

        # Resource usage
        echo -e "  Resources:"
        kubectl top pods -n "$NAMESPACE" -l app="$TARGET" --no-headers 2>/dev/null | \
            while read -r pod cpu mem; do
                echo -e "    $pod  CPU=$cpu  MEM=$mem"
            done || echo "    (metrics not available)"

        # Load generator status
        local gen_status
        gen_status=$(kubectl get pod hpa-load-generator -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo -e "  Load Gen: $gen_status"

        echo ""
        sleep "$check_interval"
    done
}

# ── Cleanup ─────────────────────────────────────────────────────────
cleanup() {
    echo ""
    log "Cleaning up load generator pod..."
    kubectl delete pod hpa-load-generator -n "$NAMESPACE" --ignore-not-found=true &>/dev/null
    log "Cleanup complete."
    echo ""
    log "HPA will gradually scale back down over the next few minutes."
    log "Monitor with:  kubectl get hpa -n $NAMESPACE -w"
    exit 0
}

trap cleanup EXIT INT TERM

# ── Main ────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      HPA Autoscaling Test Script      ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    check_prerequisites
    show_state
    start_load_generator
    monitor_scaling
}

main
