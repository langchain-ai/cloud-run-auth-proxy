# LangSmith Auth Proxy — Cloud Run

Deploy the LangSmith auth proxy on Google Cloud Run. This is the Cloud Run equivalent of the [`langsmith-auth-proxy` Helm chart](../helm/charts/langsmith-auth-proxy/) used on Kubernetes.

The proxy validates RS256 JWTs issued by LangSmith and injects provider credentials before forwarding requests to your LLM provider. It is **provider-agnostic** — the only provider-specific piece is the ext_authz sidecar script, which you swap out per provider.

## Architecture

```
Client
  │  X-LangSmith-LLM-Auth: <JWT>
  ▼
┌──────────────────────────────────────────┐
│  Cloud Run Service (multi-container)     │
│                                          │
│  ┌──────────────┐    ┌────────────────┐  │
│  │  auth-proxy  │───▶│   ext-authz    │  │
│  │ (Envoy:10000)│    │ (Python:10002) │  │
│  │              │    │                │  │
│  │ 1. JWT check │    │ 3. Inject      │  │
│  │ 2. ext_authz │    │    API key +   │  │
│  │ 4. Forward   │    │    headers     │  │
│  └──────┬───────┘    └────────────────┘  │
│         │                                │
└─────────┼────────────────────────────────┘
          │
          ▼
    LLM Provider API
    (configurable: Anthropic, OpenAI, Azure, …)
```

## Prerequisites

1. **gcloud CLI** — authenticated with Owner or Editor role on the project
2. **RSA key pair** — the same keys used in your LangSmith deployment for JWT signing
3. **LLM provider API key**
4. **GCP APIs enabled:**

```bash
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  cloudbuild.googleapis.com \
  --project=$PROJECT_ID
```

## Deploy

### 1. Configure

```bash
# Required
export PROJECT_ID=my-gcp-project
export PUB_KEY_PATH=./keys/pub.pem            # RSA public key for JWKS
export UPSTREAM_HOST=api.anthropic.com         # your LLM provider hostname
export LLM_PROVIDER_API_KEY=sk-ant-api03-...   # provider API key

# Optional (shown with defaults)
export REGION=us-central1
export UPSTREAM_PORT=443
export JWT_ISSUER=langsmith:self-hosted:prod-us
export JWT_AUDIENCE=test-audience
export SECRET_NAME=llm-provider-api-key
```

### 2. Run

```bash
./deploy.sh
```

`deploy.sh` will:

| Step | What it does |
|------|-------------|
| 1 | Create an Artifact Registry Docker repository (if needed) |
| 2 | Build and push the Envoy and ext-authz images via Cloud Build |
| 3 | Create/update a Secret Manager secret with your API key |
| 4 | Generate JWKS JSON from your RSA public key |
| 5 | Render `service.yaml` with all config values |
| 6 | Deploy to Cloud Run via `gcloud run services replace` |
| 7 | Print the service URL |

On success you'll see:

```
--- Deployment Complete ---
Service URL: https://langsmith-auth-proxy-f34kggfazq-uc.a.run.app
```

## Test

The included test suite validates JWT enforcement end-to-end against the live Cloud Run service.

### Run

```bash
# Use the URL printed by deploy.sh
PROXY_URL=https://langsmith-auth-proxy-f34kggfazq-uc.a.run.app ./test-cloud-run.sh
```

By default the script reads the private key from `./keys/priv.pem`. Override with:

```bash
PROXY_URL=https://... PRIV_KEY=/path/to/priv.pem ./test-cloud-run.sh
```

### What it tests

| # | Test | Expected |
|---|------|----------|
| 1 | `GET /healthz` (no JWT) | 200 |
| 2 | `POST /v1/messages` without JWT | 401 |
| 3 | `POST /v1/messages` with garbage JWT | 401 |
| 4 | `POST /v1/messages` with valid JWT | 200 + upstream response |
| 5 | `POST /v1/messages` with expired JWT | 401 |
| 6 | `POST /v1/messages` with wrong audience | 403 |
| 7 | `POST /v1/messages` with wrong issuer | 401 |

Tests 1-3 and 5-7 are fully provider-agnostic. Test 4 sends an Anthropic-shaped request body — adjust the model/body in `test-cloud-run.sh` if you're using a different provider.

### Manual smoke test

```bash
# Health check (no auth)
curl https://langsmith-auth-proxy-xxx-uc.a.run.app/healthz

# With a valid JWT (generate one using openssl or your LangSmith instance)
curl -X POST https://langsmith-auth-proxy-xxx-uc.a.run.app/v1/messages \
  -H "Content-Type: application/json" \
  -H "X-LangSmith-LLM-Auth: <your-jwt>" \
  -d '{"model":"claude-sonnet-4-20250514","max_tokens":50,"messages":[{"role":"user","content":"hi"}]}'
```

## Tear Down

```bash
./teardown.sh
```

Only removes resources labeled `managed-by=langsmith-auth-proxy-deploy`, so it won't touch pre-existing secrets or repositories with the same names.

## Configuration Reference

All values are environment variables passed to `deploy.sh`:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PROJECT_ID` | yes | — | GCP project ID |
| `PUB_KEY_PATH` | yes | — | Path to RSA public key PEM file |
| `UPSTREAM_HOST` | yes | — | LLM provider hostname (e.g. `api.anthropic.com`, `api.openai.com`) |
| `LLM_PROVIDER_API_KEY` | yes* | — | Provider API key. Only required on first deploy or to update the secret. |
| `REGION` | no | `us-central1` | Cloud Run and Artifact Registry region |
| `UPSTREAM_PORT` | no | `443` | Upstream TLS port |
| `JWT_ISSUER` | no | `langsmith:self-hosted:prod-us` | Expected `iss` claim in JWTs |
| `JWT_AUDIENCE` | no | `test-audience` | Expected `aud` claim in JWTs |
| `SECRET_NAME` | no | `llm-provider-api-key` | Secret Manager secret name |
| `SERVICE_NAME` | no | `langsmith-auth-proxy` | Cloud Run service name |
| `REPOSITORY` | no | `langsmith-auth-proxy` | Artifact Registry repository name |

## Customizing for Your LLM Provider

The ext_authz sidecar is the **only** provider-specific component. It runs on `localhost:10002`, receives every authorized request from Envoy, and returns headers to inject before forwarding upstream.

### Included example: Anthropic

`ext-authz-anthropic.py` injects:
- `x-api-key: <key>`
- `anthropic-version: 2023-06-01`

### Writing your own: OpenAI example

Create `ext-authz-openai.py`:

```python
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
import os

API_KEY = os.environ["LLM_PROVIDER_API_KEY"]

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

class Handler(BaseHTTPRequestHandler):
    def do_any(self):
        self.send_response(200)
        self.send_header("Authorization", f"Bearer {API_KEY}")
        self.send_header("x-envoy-auth-headers-to-remove", "x-langsmith-llm-auth")
        self.end_headers()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_any

    def log_message(self, format, *args):
        print(f"ext_authz: {args[0]}", flush=True)

if __name__ == "__main__":
    server = ThreadedHTTPServer(("0.0.0.0", 10002), Handler)
    print("ext_authz listening on :10002", flush=True)
    server.serve_forever()
```

Then update `Dockerfile.ext-authz`:

```dockerfile
COPY ext-authz-openai.py .
CMD ["python", "ext-authz-openai.py"]
```

And deploy:

```bash
export UPSTREAM_HOST=api.openai.com
export LLM_PROVIDER_API_KEY=sk-...
./deploy.sh
```

### Requirements for any ext_authz script

- Listen on `0.0.0.0:10002` (Cloud Run probes can't reach `127.0.0.1`)
- Read `LLM_PROVIDER_API_KEY` from env
- Return HTTP 200 with provider headers on every request
- Include `x-envoy-auth-headers-to-remove: x-langsmith-llm-auth` to strip the JWT before forwarding

## Files

| File | Provider-specific? | Description |
|------|--------------------|-------------|
| `envoy.yaml` | No | Envoy config template — all values substituted at runtime |
| `entrypoint.sh` | No | Substitutes env vars into `envoy.yaml` then starts Envoy |
| `Dockerfile.envoy` | No | Envoy image with baked-in config template |
| `ext-authz-anthropic.py` | **Yes** | Anthropic ext_authz sidecar (swap for your provider) |
| `Dockerfile.ext-authz` | No | Python image for ext_authz sidecar |
| `service.yaml` | No | Cloud Run service definition template |
| `deploy.sh` | No | Build, configure, and deploy — single command |
| `teardown.sh` | No | Label-safe removal of all deployed resources |
| `test-cloud-run.sh` | Partially | JWT tests are generic; test 4 request body is Anthropic-specific |
| `keys/` | — | RSA key pair for testing (do not use in production) |

## How It Maps to the Helm Chart

| Concept | Kubernetes (Helm chart) | Cloud Run |
|---------|------------------------|-----------|
| Envoy config | ConfigMap from template | Baked into image, env vars substituted at startup |
| ext_authz sidecar | Pod sidecar container | Cloud Run sidecar with `container-dependencies` |
| API key secret | Kubernetes Secret | Secret Manager `secretKeyRef` |
| JWKS | Helm value `jwksJson` | `JWKS_JSON` env var |
| Upstream config | Helm values | `UPSTREAM_HOST` / `UPSTREAM_PORT` env vars |
| JWT config | Helm values `jwtIssuer` / `jwtAudiences` | `JWT_ISSUER` / `JWT_AUDIENCE` env vars |
| Health check | Envoy health_check filter | `direct_response` route on `/healthz` |

## Troubleshooting

### Deployment fails with startup probe errors

Check the container logs:
```bash
gcloud logging read \
  'resource.type="cloud_run_revision" resource.labels.service_name="langsmith-auth-proxy"' \
  --project=$PROJECT_ID --limit=30
```

Common causes:
- ext_authz binding to `127.0.0.1` instead of `0.0.0.0`
- Missing or invalid `LLM_PROVIDER_API_KEY` secret
- Missing `UPSTREAM_HOST` env var

### JWT validation fails (401 on valid JWT)

- Verify JWKS matches your signing key — check the `JWKS_JSON` env var in the active revision
- Confirm `JWT_ISSUER` and `JWT_AUDIENCE` match the claims in your JWT

### 403 on valid JWT

- JWT signature is valid but the `aud` claim doesn't match `JWT_AUDIENCE`

### ext_authz errors (503)

- Check ext-authz container logs in Cloud Logging
- Verify the Secret Manager secret version is accessible to the service account
