#!/usr/bin/env bash
# Mints a vendor JWT that graph-procurement's real JWTAuthenticator accepts, signed by a local key
# whose JWKS this directory serves. Usage: SUB=<vendor_user.external_id> ./mint-token.sh
set -euo pipefail
cd "$(dirname "$0")"

ISS=${ISS:-http://localhost:8099/}
AUD=${AUD:-graph-procurement-local}
SUB=${SUB:?set SUB to the vendor user external_id}
TTL=${TTL:-3600}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

if [ ! -f key.pem ]; then
  openssl genrsa -out key.pem 2048 2>/dev/null
fi

n=$(openssl rsa -in key.pem -noout -modulus | cut -d= -f2 | xxd -r -p | b64url)
printf '{"keys":[{"kty":"RSA","kid":"local-dev","alg":"RS256","use":"sig","n":"%s","e":"AQAB"}]}\n' "$n" > jwks.json

now=$(date +%s)
header='{"alg":"RS256","typ":"JWT","kid":"local-dev"}'
payload=$(printf '{"iss":"%s","aud":"%s","sub":"%s","iat":%d,"exp":%d%s}' \
  "$ISS" "$AUD" "$SUB" "$now" "$((now + TTL))" "${EXTRA_CLAIMS:+,$EXTRA_CLAIMS}")

signing_input="$(printf %s "$header" | b64url).$(printf %s "$payload" | b64url)"
signature=$(printf %s "$signing_input" | openssl dgst -sha256 -sign key.pem | b64url)

echo "$signing_input.$signature"
