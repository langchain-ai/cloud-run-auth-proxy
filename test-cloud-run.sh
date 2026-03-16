#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Test LangSmith Auth Proxy on Cloud Run
#
# Tests JWT validation and upstream proxying. The valid-JWT test (test 4) uses
# Anthropic as the example upstream — adjust the model/body if you're using a
# different LLM provider.
#
# Usage:
#   PROXY_URL=https://langsmith-auth-proxy-xxx.run.app \
#   PRIV_KEY=/path/to/priv.pem \
#   ./test-cloud-run.sh
###############################################################################

PRIV_KEY="${PRIV_KEY:-$(dirname "$0")/keys/priv.pem}"
PROXY_URL="${PROXY_URL:?Set PROXY_URL to your Cloud Run service URL}"

# --- Generate a valid JWT signed with our RS256 private key ---
generate_jwt() {
  local exp_offset="${1:-300}" # seconds from now
  local aud="${2:-test-audience}"
  local iss="${3:-langsmith}"

  local header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

  local now=$(date +%s)
  local exp=$((now + exp_offset))
  local iat=$((exp - 300))
  local nbf=$iat
  local payload_json=$(cat <<EOJSON
{
  "iss": "${iss}",
  "aud": "${aud}",
  "sub": "test-user-123",
  "iat": ${iat},
  "exp": ${exp},
  "nbf": ${nbf},
  "jti": "test-$(uuidgen | tr '[:upper:]' '[:lower:]')",
  "actor_type": "user",
  "workspace_id": "ws-test-123",
  "organization_id": "org-test-456",
  "model_provider": "Anthropic",
  "model_name": "claude-sonnet-4-20250514",
  "streaming": false,
  "request_id": "req-$(uuidgen | tr '[:upper:]' '[:lower:]')",
  "ls_user_id": "ls-user-789"
}
EOJSON
)
  local payload=$(echo -n "$payload_json" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

  local signature=$(echo -n "${header}.${payload}" | \
    openssl dgst -sha256 -sign "$PRIV_KEY" | \
    openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

  echo "${header}.${payload}.${signature}"
}

PASS=0
FAIL=0

check() {
  local test_name="$1"
  local got="$2"
  local expected="$3"
  if [ "$got" = "$expected" ]; then
    echo "PASS: $test_name (got $got)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $test_name (got $got, expected $expected)"
    FAIL=$((FAIL + 1))
  fi
}

echo "========================================="
echo "Auth Proxy Cloud Run Tests"
echo "Target: $PROXY_URL"
echo "========================================="

# Test 1: Healthz (no JWT required)
echo ""
echo "--- Test 1: GET /healthz (should return 200, no JWT needed) ---"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY_URL/healthz")
check "GET /healthz" "$HTTP_CODE" "200"

# Test 2: Request without JWT (should 401)
echo ""
echo "--- Test 2: POST without JWT (should return 401) ---"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PROXY_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hello"}]}')
check "POST without JWT" "$HTTP_CODE" "401"

# Test 3: Request with garbage JWT (should 401)
echo ""
echo "--- Test 3: POST with garbage JWT (should return 401) ---"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PROXY_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "X-LangSmith-LLM-Auth: garbage.not.valid" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hello"}]}')
check "POST with garbage JWT" "$HTTP_CODE" "401"

# Test 4: Request with valid JWT -> real upstream completion (Anthropic example)
echo ""
echo "--- Test 4: POST with valid JWT (should return 200 with completion) ---"
VALID_JWT=$(generate_jwt 300 "test-audience" "langsmith")
RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$PROXY_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "X-LangSmith-LLM-Auth: $VALID_JWT" \
  -d '{"model":"claude-sonnet-4-20250514","max_tokens":50,"messages":[{"role":"user","content":"Say hello in exactly 5 words."}]}')
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')
check "POST with valid JWT" "$HTTP_CODE" "200"
if [ "$HTTP_CODE" = "200" ]; then
  # Anthropic example: check for message response
  if echo "$BODY" | jq -e '.type == "message"' >/dev/null 2>&1; then
    CONTENT=$(echo "$BODY" | jq -r '.content[0].text')
    echo "  Upstream response: \"$CONTENT\""
  else
    echo "  Upstream response: $(echo "$BODY" | head -c 300)"
  fi
fi

# Test 5: Expired JWT (should 401)
echo ""
echo "--- Test 5: POST with expired JWT (should return 401) ---"
EXPIRED_JWT=$(generate_jwt -300 "test-audience" "langsmith")
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PROXY_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "X-LangSmith-LLM-Auth: $EXPIRED_JWT" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hello"}]}')
check "POST with expired JWT" "$HTTP_CODE" "401"

# Test 6: Wrong audience (should 403)
echo ""
echo "--- Test 6: POST with wrong audience (should return 403) ---"
WRONG_AUD_JWT=$(generate_jwt 300 "wrong-audience" "langsmith")
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PROXY_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "X-LangSmith-LLM-Auth: $WRONG_AUD_JWT" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hello"}]}')
check "POST with wrong audience" "$HTTP_CODE" "403"

# Test 7: Wrong issuer (should 401)
echo ""
echo "--- Test 7: POST with wrong issuer (should return 401) ---"
WRONG_ISS_JWT=$(generate_jwt 300 "test-audience" "wrong-issuer")
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PROXY_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "X-LangSmith-LLM-Auth: $WRONG_ISS_JWT" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hello"}]}')
check "POST with wrong issuer" "$HTTP_CODE" "401"

echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed (out of 7)"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
