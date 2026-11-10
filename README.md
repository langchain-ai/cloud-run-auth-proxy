# LangSmith Auth Proxy — Cloud Run

Deploy the LangSmith auth proxy on Google Cloud Run. This is the Cloud Run equivalent of the [`langsmith-auth-proxy` Helm chart](../helm/charts/langsmith-auth-proxy/) used on Kubernetes.

The proxy validates Ed25519 (EdDSA) JWTs issued by LangSmith and injects provider credentials before forwarding requests to your LLM provider. It is **provider-agnostic** — the only provider-specific piece is the ext_authz sidecar script, which you swap out per provider.

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
2. **LangSmith JWKS** — LangSmith signs proxy JWTs with its own Ed25519 key. `deploy.sh` downloads the public keys from LangSmith's `/.well-known/jwks.json` (SaaS by default; set `LANGSMITH_JWKS_URL` for self-hosted) and embeds them in the proxy. You do not need your own key pair. For self-hosted setup of the signing key, see [Configure a signing JWKS](https://docs.langchain.com/langsmith/kubernetes#configure-a-signing-jwks).
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
export UPSTREAM_URL=https://api.anthropic.com  # full URL — path is preserved if included
export LLM_PROVIDER_API_KEY=sk-ant-api03-...   # provider API key

# Optional (shown with defaults)
export REGION=us-central1
export JWT_ISSUER=langsmith
export JWT_AUDIENCE=test-audience
export SECRET_NAME=llm-provider-api-key
export LANGSMITH_JWKS_URL=https://api.smith.langchain.com/.well-known/jwks.json  # self-hosted: https://<your-langsmith>/.well-known/jwks.json
# export PUB_KEY_PATH=./keys/pub.pem          # Ed25519 public key instead of the URL (testing / no outbound access)

# Corporate proxy (optional)
export HTTP_PROXY_HOST=proxy.corp.com          # proxy hostname
export HTTP_PROXY_PORT=3128                    # proxy port (default: 3128)
export NO_PROXY=internal.host,.internal.corp   # hosts to bypass proxy

# Feature toggles (optional)
export JWT_VALIDATION_ENABLED=true             # set false to disable JWT filter
export EXT_AUTHZ_ENABLED=true                  # set false to disable ext_authz filter
```

### 2. Run

```bash
./deploy.sh
```

The JWKS is embedded at deploy time, so re-run `./deploy.sh` after LangSmith rotates its signing key.

`deploy.sh` will:

| Step | What it does |
|------|-------------|
| 1 | Create an Artifact Registry Docker repository (if needed) |
| 2 | Build and push the Envoy and ext-authz images via Cloud Build (parallel) |
| 3 | Create/update a Secret Manager secret with your API key and grant the Cloud Run service account access |
| 4 | Download the LangSmith JWKS (or build one from `PUB_KEY_PATH`) and keep only the public Ed25519 keys |
| 5 | Render `service.yaml` with all config values |
| 6 | Deploy to Cloud Run via `gcloud run services replace` |
| 7 | Set public access IAM policy (`allUsers` invoker) and print the service URL |

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

Tests 4-7 sign their own JWTs, so they only pass when the proxy was deployed to trust the test key. Create an Ed25519 test key pair and deploy with `PUB_KEY_PATH`:

```bash
mkdir -p keys
openssl genpkey -algorithm ed25519 -out keys/priv.pem
openssl pkey -in keys/priv.pem -pubout -out keys/pub.pem
PUB_KEY_PATH=./keys/pub.pem ./deploy.sh
```

The script needs OpenSSL 3.x. By default the script reads the private key from `keys/priv.pem` (relative to the script directory). Override with:

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
# Health check (no auth required)
curl https://langsmith-auth-proxy-xxx-uc.a.run.app/healthz
```

In production, JWTs are generated by LangSmith automatically when routing LLM requests through the proxy. For manual testing, use `test-cloud-run.sh` which generates short-lived JWTs using an Ed25519 test private key.

## Tear Down

```bash
export PROJECT_ID=my-gcp-project   # same as deploy
./teardown.sh
```

Only removes resources labeled `managed-by=langsmith-auth-proxy-deploy`, so it won't touch pre-existing secrets or repositories with the same names. Accepts the same `REGION`, `SECRET_NAME`, `SERVICE_NAME`, and `REPOSITORY` overrides as `deploy.sh`.

## Configuration Reference

All values are environment variables passed to `deploy.sh`:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PROJECT_ID` | yes | — | GCP project ID |
| `LANGSMITH_JWKS_URL` | no | `https://api.smith.langchain.com/.well-known/jwks.json` | LangSmith JWKS URL used to verify JWTs |
| `PUB_KEY_PATH` | no | — | Ed25519 public key PEM; used instead of `LANGSMITH_JWKS_URL` |
| `UPSTREAM_URL` | yes | — | Full upstream URL (e.g. `https://api.anthropic.com`, `https://gateway.example.com/api/v1`). If a path is included, all requests are prefixed with it. |
| `LLM_PROVIDER_API_KEY` | yes* | — | Provider API key. Only required on first deploy or to update the secret. |
| `REGION` | no | `us-central1` | Cloud Run and Artifact Registry region |
| `JWT_ISSUER` | no | `langsmith` | Expected `iss` claim in JWTs |
| `JWT_AUDIENCE` | no | `test-audience` | Expected `aud` claim in JWTs |
| `JWT_VALIDATION_ENABLED` | no | `true` | Set to `false` to disable the JWT validation filter |
| `EXT_AUTHZ_ENABLED` | no | `true` | Set to `false` to disable the ext_authz filter |
| `HTTP_PROXY_HOST` | no | — | Corporate HTTP proxy hostname. Uses a two-listener loopback pattern since Envoy ignores `HTTP_PROXY` env vars. |
| `HTTP_PROXY_PORT` | no | `3128` | Corporate HTTP proxy port |
| `NO_PROXY` | no | — | Comma-separated hostnames to bypass the proxy (e.g. `internal.host,.internal.corp`). Supports exact match and domain suffix (`.corp.com`). |
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
export UPSTREAM_URL=https://api.openai.com
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
| `envoy.yaml` | No | Reference-only — shows the default generated config. Overwritten at runtime by `entrypoint.sh`. |
| `entrypoint.sh` | No | Generates `envoy.yaml` from env vars (with conditionals for proxy, path, TLS, ext_authz) then starts Envoy |
| `Dockerfile.envoy` | No | Envoy image with entrypoint script |
| `ext-authz-anthropic.py` | **Yes** | Anthropic ext_authz sidecar (swap for your provider) |
| `Dockerfile.ext-authz` | No | Python image for ext_authz sidecar |
| `service.yaml` | No | Cloud Run service definition template |
| `deploy.sh` | No | Build, configure, and deploy — single command |
| `teardown.sh` | No | Label-safe removal of all deployed resources |
| `test-cloud-run.sh` | Partially | JWT tests are generic; test 4 request body is Anthropic-specific |
| `keys/` | — | Ed25519 key pair for testing (do not use in production) |

## How It Maps to the Helm Chart

| Concept | Kubernetes (Helm chart) | Cloud Run |
|---------|------------------------|-----------|
| Envoy config | ConfigMap from Go template | Generated at startup by `entrypoint.sh` (Python) |
| ext_authz sidecar | Pod sidecar container | Cloud Run sidecar with `container-dependencies` |
| API key secret | Kubernetes Secret | Secret Manager `secretKeyRef` |
| JWKS | Helm value `jwksJson` | `JWKS_JSON` env var |
| Upstream config | Helm value `upstream` (full URL) | `UPSTREAM_URL` env var (full URL with optional path) |
| JWT config | Helm values `jwtIssuer` / `jwtAudiences` | `JWT_ISSUER` / `JWT_AUDIENCE` env vars |
| Health check | `envoy.filters.http.health_check` filter | `envoy.filters.http.health_check` filter |
| Corporate proxy | `httpProxy.enabled` / `host` / `port` / `noProxy` | `HTTP_PROXY_HOST` / `HTTP_PROXY_PORT` / `NO_PROXY` env vars |
| Path preservation | Path component of `upstream` URL | Path component of `UPSTREAM_URL` |

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
- Missing or malformed `UPSTREAM_URL` env var

### JWT validation fails (401 on valid JWT)

- Verify JWKS matches your signing key — check the `JWKS_JSON` env var in the active revision
- Confirm `JWT_ISSUER` and `JWT_AUDIENCE` match the claims in your JWT

### 403 on valid JWT

- JWT signature is valid but the `aud` claim doesn't match `JWT_AUDIENCE`

### ext_authz errors (503)

- Check ext-authz container logs in Cloud Logging
- Verify the Secret Manager secret version is accessible to the service account
