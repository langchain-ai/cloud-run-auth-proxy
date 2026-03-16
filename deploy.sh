#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Deploy LangSmith Auth Proxy to Cloud Run
#
# Prerequisites:
#   - gcloud CLI authenticated with appropriate permissions
#   - RSA public key for JWKS at $PUB_KEY_PATH
#   - LLM_PROVIDER_API_KEY env var set (for initial secret creation)
#
# Usage:
#   export PROJECT_ID=my-gcp-project
#   export REGION=us-central1
#   export PUB_KEY_PATH=/path/to/pub.pem
#   export UPSTREAM_URL=https://api.anthropic.com       # or https://gateway.example.com/api/v1
#   export LLM_PROVIDER_API_KEY=sk-ant-...              # your provider API key
#   ./deploy.sh
#
# Optional:
#   export HTTP_PROXY_HOST=proxy.corp.com               # corporate proxy hostname
#   export HTTP_PROXY_PORT=3128                          # corporate proxy port (default: 3128)
#   export NO_PROXY=internal.host,.internal.corp         # hosts to bypass proxy
#   export JWT_VALIDATION_ENABLED=true                   # set false to disable JWT filter
#   export EXT_AUTHZ_ENABLED=true                        # set false to disable ext_authz filter
###############################################################################

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID env var}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-langsmith-auth-proxy}"
PUB_KEY_PATH="${PUB_KEY_PATH:?Set PUB_KEY_PATH to RSA public key PEM file}"
SECRET_NAME="${SECRET_NAME:-llm-provider-api-key}"
SERVICE_NAME="${SERVICE_NAME:-langsmith-auth-proxy}"
UPSTREAM_URL="${UPSTREAM_URL:?Set UPSTREAM_URL env var (e.g. https://api.anthropic.com)}"
JWT_ISSUER="${JWT_ISSUER:-langsmith}"
JWT_AUDIENCE="${JWT_AUDIENCE:-test-audience}"
JWT_VALIDATION_ENABLED="${JWT_VALIDATION_ENABLED:-true}"
EXT_AUTHZ_ENABLED="${EXT_AUTHZ_ENABLED:-true}"
HTTP_PROXY_HOST="${HTTP_PROXY_HOST:-}"
HTTP_PROXY_PORT="${HTTP_PROXY_PORT:-3128}"
NO_PROXY="${NO_PROXY:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Label applied to every resource we create, so teardown can verify ownership.
MANAGED_BY_LABEL="managed-by=langsmith-auth-proxy-deploy"

# --- Temp file cleanup on exit (success or failure) ---
TMPFILES=""
cleanup() {
  if [ -n "$TMPFILES" ]; then
    echo "$TMPFILES" | while IFS= read -r f; do
      [ -n "$f" ] && rm -f "$f"
    done
  fi
}
trap cleanup EXIT

mktmp() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/deploy-XXXXXX")
  TMPFILES="${TMPFILES}${TMPFILES:+
}${f}"
  echo "$f"
}

echo "=== LangSmith Auth Proxy - Cloud Run Deploy ==="
echo "Project:    $PROJECT_ID"
echo "Region:     $REGION"
echo "Repository: $REPOSITORY"
echo "Upstream:   ${UPSTREAM_URL}"
if [ -n "$HTTP_PROXY_HOST" ]; then
  echo "HTTP Proxy: ${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}"
  [ -n "$NO_PROXY" ] && echo "NO_PROXY:   ${NO_PROXY}"
fi
echo ""

# --- Step 1: Ensure Artifact Registry repository exists ---
echo "--- Step 1: Ensure Artifact Registry repository ---"
if ! gcloud artifacts repositories describe "$REPOSITORY" \
    --location="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  echo "Creating Artifact Registry repository: $REPOSITORY"
  gcloud artifacts repositories create "$REPOSITORY" \
    --repository-format=docker \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --labels="$MANAGED_BY_LABEL"
else
  echo "Repository $REPOSITORY already exists"
fi
echo ""

# --- Step 2: Build and push images ---
echo "--- Step 2: Build and push container images ---"
IMAGE_PREFIX="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"
IMAGE_TAG="$(date +%Y%m%d%H%M%S)"
echo "Image tag: $IMAGE_TAG"

# Cloud Build needs a cloudbuild.yaml to use a non-default Dockerfile name.
# Use --no-cache to ensure fresh builds pick up all file changes.
CB_AUTHZ=$(mktmp yaml)
cat > "$CB_AUTHZ" <<EOF
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '--no-cache', '-t', '${IMAGE_PREFIX}/auth-proxy-ext-authz:${IMAGE_TAG}', '-f', 'Dockerfile.ext-authz', '.']
images: ['${IMAGE_PREFIX}/auth-proxy-ext-authz:${IMAGE_TAG}']
EOF

CB_ENVOY=$(mktmp yaml)
cat > "$CB_ENVOY" <<EOF
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '--no-cache', '-t', '${IMAGE_PREFIX}/auth-proxy-envoy:${IMAGE_TAG}', '-f', 'Dockerfile.envoy', '.']
images: ['${IMAGE_PREFIX}/auth-proxy-envoy:${IMAGE_TAG}']
EOF

echo "Building both images in parallel..."
BUILD_LOG_AUTHZ=$(mktmp log)
BUILD_LOG_ENVOY=$(mktmp log)

gcloud builds submit "$SCRIPT_DIR" \
  --config="$CB_AUTHZ" \
  --project="$PROJECT_ID" \
  >"$BUILD_LOG_AUTHZ" 2>&1 &
PID_AUTHZ=$!

gcloud builds submit "$SCRIPT_DIR" \
  --config="$CB_ENVOY" \
  --project="$PROJECT_ID" \
  >"$BUILD_LOG_ENVOY" 2>&1 &
PID_ENVOY=$!

BUILD_FAILED=0
wait $PID_AUTHZ || { echo "ext-authz build failed:"; cat "$BUILD_LOG_AUTHZ"; BUILD_FAILED=1; }
wait $PID_ENVOY || { echo "envoy build failed:"; cat "$BUILD_LOG_ENVOY"; BUILD_FAILED=1; }
if [ "$BUILD_FAILED" -ne 0 ]; then exit 1; fi
echo "Both images built successfully"
echo ""

# --- Step 3: Create Secret Manager secret (if not exists) ---
echo "--- Step 3: Ensure Secret Manager secret ---"
if ! gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" &>/dev/null; then
  if [ -z "${LLM_PROVIDER_API_KEY:-}" ]; then
    echo "ERROR: Secret $SECRET_NAME does not exist and LLM_PROVIDER_API_KEY env var is not set." >&2
    exit 1
  fi
  echo "Creating secret: $SECRET_NAME"
  echo -n "$LLM_PROVIDER_API_KEY" | gcloud secrets create "$SECRET_NAME" \
    --data-file=- \
    --project="$PROJECT_ID" \
    --labels="$MANAGED_BY_LABEL"
else
  echo "Secret $SECRET_NAME already exists"
  if [ -n "${LLM_PROVIDER_API_KEY:-}" ]; then
    echo "Updating secret with new value..."
    echo -n "$LLM_PROVIDER_API_KEY" | gcloud secrets versions add "$SECRET_NAME" \
      --data-file=- \
      --project="$PROJECT_ID"
  fi
fi

# Grant Cloud Run service account access to the secret
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$PROJECT_ID" \
  --quiet
echo ""

# --- Step 4: Generate JWKS JSON from RSA public key ---
echo "--- Step 4: Generate JWKS JSON ---"
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required to generate JWKS" >&2
  exit 1
fi

JWKS_JSON=$(python3 - "$PUB_KEY_PATH" <<'PYEOF'
import json, sys, base64, subprocess

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

pem_path = sys.argv[1]

result = subprocess.run(
    ["openssl", "rsa", "-pubin", "-in", pem_path, "-text", "-noout"],
    capture_output=True, text=True, check=True
)
lines = result.stdout.split("\n")

# Parse modulus
mod_lines = []
in_mod = False
for line in lines:
    if "Modulus:" in line:
        in_mod = True
        continue
    if in_mod:
        stripped = line.strip()
        if stripped.startswith("Exponent:"):
            break
        mod_lines.append(stripped.replace(":", ""))

if not mod_lines:
    raise ValueError("Could not parse RSA modulus from openssl output")
mod_hex = "".join(mod_lines)
mod_bytes = bytes.fromhex(mod_hex)
if mod_bytes[0] == 0:
    mod_bytes = mod_bytes[1:]

# Parse exponent
exp_int = None
for line in lines:
    if "Exponent:" in line:
        exp_int = int(line.split("(")[0].split(":")[1].strip())
        break
if exp_int is None:
    raise ValueError("Could not parse RSA exponent from openssl output")

exp_bytes = exp_int.to_bytes((exp_int.bit_length() + 7) // 8, "big")

jwks = {
    "keys": [{
        "kty": "RSA",
        "alg": "RS256",
        "use": "sig",
        "n": b64url(mod_bytes),
        "e": b64url(exp_bytes),
    }]
}

print(json.dumps(jwks, separators=(",", ":")))
PYEOF
)

echo "JWKS generated successfully"
echo ""

# --- Step 5: Render service.yaml ---
echo "--- Step 5: Render service.yaml ---"
RENDERED=$(mktmp yaml)
python3 -c "
import sys
template = open(sys.argv[1]).read()
# JWKS goes inside YAML single quotes, so escape any ' as ''
jwks_yaml_safe = sys.argv[5].replace(\"'\", \"''\")
replacements = {
    '__PROJECT_ID__': sys.argv[2],
    '__REGION__': sys.argv[3],
    '__REPOSITORY__': sys.argv[4],
    'JWKS_JSON_PLACEHOLDER': jwks_yaml_safe,
    '__IMAGE_TAG__': sys.argv[6],
    '__UPSTREAM_URL__': sys.argv[7],
    '__JWT_ISSUER__': sys.argv[8],
    '__JWT_AUDIENCE__': sys.argv[9],
    '__SECRET_NAME__': sys.argv[10],
    '__JWT_VALIDATION_ENABLED__': sys.argv[11],
    '__EXT_AUTHZ_ENABLED__': sys.argv[12],
    '__HTTP_PROXY_HOST__': sys.argv[13],
    '__HTTP_PROXY_PORT__': sys.argv[14],
    '__NO_PROXY__': sys.argv[15],
}
result = template
for placeholder, value in replacements.items():
    result = result.replace(placeholder, value)
open(sys.argv[16], 'w').write(result)
" "$SCRIPT_DIR/service.yaml" \
  "$PROJECT_ID" "$REGION" "$REPOSITORY" "$JWKS_JSON" "$IMAGE_TAG" \
  "$UPSTREAM_URL" "$JWT_ISSUER" "$JWT_AUDIENCE" \
  "$SECRET_NAME" "$JWT_VALIDATION_ENABLED" "$EXT_AUTHZ_ENABLED" \
  "$HTTP_PROXY_HOST" "$HTTP_PROXY_PORT" "$NO_PROXY" \
  "$RENDERED"

echo "Rendered service definition"
echo ""

# --- Step 6: Deploy to Cloud Run ---
echo "--- Step 6: Deploy to Cloud Run ---"
gcloud run services replace "$RENDERED" \
  --region="$REGION" \
  --project="$PROJECT_ID"

# Allow unauthenticated access (adjust if you want IAM auth)
echo ""
echo "Setting IAM policy for public access..."
gcloud run services add-iam-policy-binding "$SERVICE_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --member="allUsers" \
  --role="roles/run.invoker" \
  --quiet

# --- Step 7: Get service URL ---
echo ""
echo "--- Deployment Complete ---"
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format='value(status.url)')
echo "Service URL: $SERVICE_URL"
echo ""
echo "Test with:"
echo "  PROXY_URL=$SERVICE_URL ./test-cloud-run.sh"
echo ""
echo "Tear down with:"
echo "  ./teardown.sh"
