# procurement-local

Runs graph-procurement and procurement-platform on your machine with a stubbed vendor login, so you can send GraphQL queries and mutations to the subgraph without Auth0.

graph-procurement keeps its real JWT checks. The only change is where it fetches signing keys from: this folder serves its own key set on localhost, and `mint-token.sh` signs tokens with the matching private key. Whatever you put in the token's `sub` claim is the vendor user you are logged in as.

## Prerequisites

- A ws-monorepo checkout at `~/Workspace/ws-monorepo`, or set `REPO=/path/to/ws-monorepo`.
- Apply migrations to `procurement-platform`. From the monorepo:
  ```bash
  make ecr-login   # only if the postgres:18.3 image is not pulled yet
  ./deployment/scripts/database/start-db-and-migrate.sh deployment/database/procurement-platform-db
  ```
- `docker`, `bazel`, `grpcurl`, `jq`, `python3`, `openssl`, `curl` and `lsof` on your `PATH`.

## Usage

```bash
./start-procurement-local.sh          # token for the newest active vendor user in your database
./start-procurement-local.sh --seed   # first create a new vendor, vendor user and an RFQ open for 14 days
```

When it prints **Ready** you have:

| Service | Address |
|---------|---------|
| graph-procurement | `http://localhost:8081/graphql` |
| procurement-platform (gRPC) | `localhost:9090` |
| Key server | `http://localhost:8099/jwks.json` |

The token lasts one hour. It is also copied to the clipboard on macOS (`pbcopy`), ready to paste into Gavel or send it as a bearer token:

```bash
curl -s localhost:8081/graphql \
  -H "Authorization: Bearer $(cat token.txt)" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ vendor { id name } }"}'
```

### Logging in as a different vendor user

`sub` must be the `external_id` of a row in `procurement_platform.vendor_user`:

```bash
docker exec postgres_5432 psql -U postgres -t -A \
  -c "SELECT external_id FROM procurement_platform.vendor_user WHERE active"

SUB='<external_id>' ./mint-token.sh > token.txt
```

`mint-token.sh` also takes `TTL` (seconds, default 3600) and `EXTRA_CLAIMS` (raw JSON fragment, for example `EXTRA_CLAIMS='"scope":"read"'`). graph-procurement only reads `sub` today, so extra claims are ignored unless you are testing code that reads them.

### Changing ports

If a port is already taken, the script stops and names the process holding it rather than killing it. Pick other ports with:

```bash
PP_PORT=9091 GP_PORT=8082 JWKS_PORT=8098 ./start-procurement-local.sh
```

Tokens carry the key server's URL as their issuer, so mint new ones after changing `JWKS_PORT`.

## How it works

1. **Checks.** Confirms the tools, the free ports, the Postgres container (starting it if stopped) and the procurement schema.
2. **Key server.** Runs `python3 -m http.server` on this folder, so graph-procurement can fetch `jwks.json`.
3. **Build.** One `bazel build` of both services.
4. **procurement-platform.** Started with `TIER=dev`, `ENVIRONMENT=dev`, local Postgres without SSL or IAM, and gRPC on `PP_PORT`. The script waits for the gRPC health check.
5. **graph-procurement.** Started with `TIER=dev`, `ENVIRONMENT=dev` and these overrides, then the script waits for `/healthz`:
   - `PROCUREMENT_PLATFORM_SERVICE_ADDR=localhost:$PP_PORT` points it at the local backend.
   - `AUTH0_JWKS_URL`, `AUTH0_JWT_ISSUERS` and `AUTH0_JWT_AUDIENCES` point it at the local key server instead of Auth0.
6. **Token.** Mints a token for the seeded or newest vendor user and writes it to `token.txt`.
7. **Watch.** If any of the three processes exits, the script stops the others and exits, so you never query a half-running stack.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `Unable to load countries` at start-up | Due to `staticstore`. Expected when `enum.dev.sothelabs.com` is unreachable, countries only required by `auction-checkout` service |
| An authentication error from GraphQL | The token has expired, or was minted for a different `JWKS_PORT`. Run `mint-token.sh` again. |
| A service exits during start-up | The script prints the last 20 lines of its log. The full log is in `logs/`. |
