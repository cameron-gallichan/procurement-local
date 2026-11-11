#!/usr/bin/env bash
# Starts procurement-platform, graph-procurement and a local key server for stubbed vendor logins,
# then prints a token to query the graph with. Ctrl-C stops all three.
#
# Usage: ./start-procurement-local.sh [--seed]
#   --seed  registers a vendor, its user and an open RFQ first, and prints that vendor's token.
#
# Needs: Docker with the local Postgres from `make sql-start` (container postgres_5432),
# grpcurl, jq, python3, openssl, and mint-token.sh beside this script.
set -euo pipefail

SCRIPTS=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-$HOME/Workspace/ws-monorepo}
PP_PORT=${PP_PORT:-9090}      # procurement-platform gRPC
GP_PORT=${GP_PORT:-8081}      # graph-procurement HTTP
JWKS_PORT=${JWKS_PORT:-8099}  # local key server
AUD=graph-procurement-local
export ISS="http://localhost:$JWKS_PORT/"
LOGS=$SCRIPTS/logs
SVC=com.sothebys.procurementplatform.proto.service.ProcurementPlatformService
PP_TARGET=//src/go/src/procurement-platform/cmd/grpc:procurement-platform
GP_TARGET=//src/go/src/graph-procurement

SEED=false
[ "${1:-}" = "--seed" ] && SEED=true

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }
psql_q() { docker exec postgres_5432 psql -U postgres -d postgres -t -A -c "$1"; }

for tool in docker grpcurl jq python3 openssl curl; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
[ -x "$SCRIPTS/mint-token.sh" ] || die "mint-token.sh not found next to this script"
[ -d "$REPO/src/go/src/graph-procurement" ] || die "no monorepo at $REPO (set REPO=...)"

# Another branch's server is often on these ports, so stop rather than kill it.
for port in "$PP_PORT" "$GP_PORT" "$JWKS_PORT"; do
  # lsof exits 1 when nothing listens, which pipefail would turn into a silent exit.
  holder=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" (pid "$2")"}' || true)
  [ -z "$holder" ] || die "port $port is already used by $holder. Stop it, or pick other ports with PP_PORT, GP_PORT and JWKS_PORT."
done

say "Checking the local Postgres"
state=$(docker inspect -f '{{.State.Running}}' postgres_5432 2>/dev/null || echo missing)
case "$state" in
  true) ;;
  false) docker start postgres_5432 >/dev/null ;;
  *) die "no postgres_5432 container. From $REPO run: AWS_PROFILE=vikingdev make ecr-login && AWS_PROFILE=vikingdev make sql-start" ;;
esac
for _ in $(seq 1 30); do
  docker exec postgres_5432 pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
psql_q "SELECT 1 FROM procurement_platform.vendor LIMIT 1" >/dev/null 2>&1 \
  || die "the procurement_platform schema is missing. Apply the migrations with: ./deployment/scripts/database/start-db-and-migrate.sh deployment/database/procurement-platform-db"

mkdir -p "$LOGS"
PIDS=()
cleanup() {
  trap - EXIT INT TERM
  say "Stopping"
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# wait_for <name> <log> <pid> <command...>: polls the command until it succeeds or the process dies.
wait_for() {
  local name=$1 log=$2 pid=$3; shift 3
  for _ in $(seq 1 120); do
    "$@" >/dev/null 2>&1 && return 0
    kill -0 "$pid" 2>/dev/null || { tail -20 "$log" >&2; die "$name exited during start-up, see $log"; }
    sleep 1
  done
  die "$name did not become ready within 2 minutes, see $log"
}

say "Starting the key server on :$JWKS_PORT"
# Creates key.pem and jwks.json on the first run; later runs reuse the key so old tokens stay valid.
SUB=bootstrap "$SCRIPTS/mint-token.sh" >/dev/null
(cd "$SCRIPTS" && exec python3 -m http.server "$JWKS_PORT" --bind 127.0.0.1) >"$LOGS/jwks.log" 2>&1 &
PIDS+=($!)
wait_for "key server" "$LOGS/jwks.log" $! curl -sf "http://localhost:$JWKS_PORT/jwks.json"

say "Building both services (first build takes a few minutes)"
(cd "$REPO" && bazel build "$PP_TARGET" "$GP_TARGET") || die "bazel build failed"

say "Starting procurement-platform on :$PP_PORT (log: $LOGS/procurement-platform.log)"
(cd "$REPO" && GRPC_PORT="0.0.0.0:$PP_PORT" PG_SSL_CONFIG=disable PG_USE_IAM=false \
  LOG_JSON_FORMATTER_ENABLED=false ENVIRONMENT=dev TIER=dev SERVICE_NAME=procurement-platform \
  exec bazel run "$PP_TARGET") >"$LOGS/procurement-platform.log" 2>&1 &
PIDS+=($!)
wait_for procurement-platform "$LOGS/procurement-platform.log" $! \
  grpcurl -plaintext "localhost:$PP_PORT" grpc.health.v1.Health/Check

say "Starting graph-procurement on :$GP_PORT (log: $LOGS/graph-procurement.log)"
(cd "$REPO" && ENVIRONMENT=dev TIER=dev SERVICE_NAME=graph-procurement HTTP_SERVER_PORT="$GP_PORT" \
  PROCUREMENT_PLATFORM_SERVICE_ADDR="localhost:$PP_PORT" \
  AUTH0_JWKS_URL="http://localhost:$JWKS_PORT/jwks.json" AUTH0_JWT_ISSUERS="$ISS" AUTH0_JWT_AUDIENCES="$AUD" \
  exec bazel run "$GP_TARGET") >"$LOGS/graph-procurement.log" 2>&1 &
PIDS+=($!)
wait_for graph-procurement "$LOGS/graph-procurement.log" $! curl -sf "http://localhost:$GP_PORT/healthz"

if $SEED; then
  say "Seeding a vendor, its user and an open RFQ"
  stamp=$(date +%s)
  vendor_id=$(grpcurl -plaintext -d "{\"name\":\"Local Vendor $stamp\",\"categories\":[\"SHIPPING\"],\"country\":\"GB\",\"contact_email\":\"local-$stamp@example.com\"}" \
    "localhost:$PP_PORT" "$SVC/RegisterVendor" | jq -r .vendorId)
  grpcurl -plaintext -d "{\"vendor_id\":\"$vendor_id\",\"email\":\"local-user-$stamp@example.com\"}" \
    "localhost:$PP_PORT" "$SVC/RegisterVendorUser" >/dev/null
  closes=$(date -u -v+14d +%Y-%m-%dT17:00:00Z 2>/dev/null || date -u -d '+14 days' +%Y-%m-%dT17:00:00Z)
  grpcurl -plaintext -d "{\"subject_ref\":\"LOCAL-$stamp\",\"window\":{\"closes_at\":\"$closes\"},
    \"shipping\":{\"shipment_type\":\"OUTBOUND\",\"client_country\":\"GB\",\"property_status\":\"SOLD\"},
    \"items\":[{\"description\":\"Local test lot\",\"shipping\":{\"lot\":\"1\",\"item\":\"1\",\"sale_number\":\"NF20484\",
      \"measurement_system\":\"METRIC\",\"weight_unit\":\"KILOGRAM\",
      \"origin\":{\"city\":\"London\",\"country\":\"GB\"},\"destination\":{\"city\":\"New York\",\"country\":\"US\"},
      \"aggregate_price_cents\":100000,\"aggregate_price_currency\":\"GBP\"}}]}" \
    "localhost:$PP_PORT" "$SVC/CreateRFQ" >/dev/null
  sub=$(psql_q "SELECT external_id FROM procurement_platform.vendor_user WHERE vendor_id = '$vendor_id'")
else
  # The newest active vendor user, if any exist.
  sub=$(psql_q "SELECT u.external_id FROM procurement_platform.vendor_user u JOIN procurement_platform.vendor v ON v.id = u.vendor_id WHERE u.active AND v.active ORDER BY u.created_at DESC LIMIT 1")
fi

echo
say "Ready"
echo "  GraphQL:          http://localhost:$GP_PORT/graphql   (Apollo Sandbox at http://localhost:$GP_PORT/)"
echo "  gRPC backend:     localhost:$PP_PORT"
echo "  Key server:       http://localhost:$JWKS_PORT/jwks.json"
echo "  Logs:             $LOGS"
if [ -n "$sub" ]; then
  SUB="$sub" "$SCRIPTS/mint-token.sh" > "$SCRIPTS/token.txt"
  echo "  Token for vendor user $sub (valid 1 hour) saved to $SCRIPTS/token.txt"
  echo "  New token later:  SUB='$sub' $SCRIPTS/mint-token.sh"
  echo
  echo "  Try it:"
  echo "    curl -s localhost:$GP_PORT/graphql -H \"Authorization: Bearer \$(cat $SCRIPTS/token.txt)\" \\"
  echo "      -H 'Content-Type: application/json' -d '{\"query\":\"{ vendor { id name } }\"}'"
else
  echo "  No vendor exists yet. Re-run with --seed, or register one with RegisterVendor and RegisterVendorUser."
fi
echo
echo "Press Ctrl-C to stop everything."

# Exit when any service stops, so a crash is not mistaken for a running stack.
while true; do
  for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || { echo "A service stopped; see the logs in $LOGS" >&2; exit 1; }
  done
  sleep 2
done
