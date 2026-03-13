#!/bin/sh
set -e

# Required env vars
: "${JWKS_JSON:?ERROR: JWKS_JSON environment variable is required}"
: "${UPSTREAM_HOST:?ERROR: UPSTREAM_HOST environment variable is required (e.g. api.anthropic.com)}"

# Optional with defaults
UPSTREAM_PORT="${UPSTREAM_PORT:-443}"
JWT_ISSUER="${JWT_ISSUER:-langsmith:self-hosted:prod-us}"
JWT_AUDIENCE="${JWT_AUDIENCE:-test-audience}"

# Substitute all placeholders in envoy.yaml using Python for safe string replacement
# (sed interprets & and \ in replacement strings, which can corrupt JSON)
python3 -c "
import os
template = open('/etc/envoy/envoy.yaml').read()
replacements = {
    'JWKS_JSON_PLACEHOLDER': os.environ['JWKS_JSON'],
    'UPSTREAM_HOST_PLACEHOLDER': os.environ['UPSTREAM_HOST'],
    'UPSTREAM_PORT_PLACEHOLDER': os.environ.get('UPSTREAM_PORT', '443'),
    'JWT_ISSUER_PLACEHOLDER': os.environ.get('JWT_ISSUER', 'langsmith:self-hosted:prod-us'),
    'JWT_AUDIENCE_PLACEHOLDER': os.environ.get('JWT_AUDIENCE', 'test-audience'),
}
result = template
for k, v in replacements.items():
    result = result.replace(k, v)
open('/etc/envoy/envoy.yaml', 'w').write(result)
"

echo "Starting Envoy..."
echo "  Upstream: ${UPSTREAM_HOST}:${UPSTREAM_PORT}"
echo "  JWT issuer: ${JWT_ISSUER}"
echo "  JWT audience: ${JWT_AUDIENCE}"
exec envoy -c /etc/envoy/envoy.yaml
