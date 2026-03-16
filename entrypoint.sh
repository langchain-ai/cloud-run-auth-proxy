#!/bin/sh
set -e

# Required env vars
: "${UPSTREAM_URL:?ERROR: UPSTREAM_URL environment variable is required (e.g. https://api.anthropic.com or https://gateway.example.com/api/v1)}"
: "${JWKS_JSON:?ERROR: JWKS_JSON environment variable is required}"

# Generate envoy.yaml using Python — mirrors the helm chart v0.0.5 config-map template.
# Python is used instead of sed/envsubst because:
#   1. We need conditionals (proxy on/off, path present/absent, TLS on/off, ext_authz on/off)
#   2. JWKS JSON contains characters that break sed
python3 <<'PYEOF'
import os, sys
from urllib.parse import urlparse

# --- Parse upstream URL ---
upstream_url = os.environ['UPSTREAM_URL']
parsed = urlparse(upstream_url)
scheme = parsed.scheme or 'https'
hostname = parsed.hostname
port = parsed.port or (443 if scheme == 'https' else 80)
path = (parsed.path or '').rstrip('/')

if not hostname:
    print(f"ERROR: UPSTREAM_URL '{upstream_url}' has no hostname. "
          f"Expected format: https://api.example.com or https://gateway.example.com/api/v1",
          file=sys.stderr)
    sys.exit(1)

# --- Config flags ---
jwt_enabled = os.environ.get('JWT_VALIDATION_ENABLED', 'true').lower() == 'true'
ext_authz_enabled = os.environ.get('EXT_AUTHZ_ENABLED', 'true').lower() == 'true'
jwks_json = os.environ['JWKS_JSON']
jwt_issuer = os.environ.get('JWT_ISSUER', 'langsmith')
jwt_audience = os.environ.get('JWT_AUDIENCE', 'test-audience')

# --- Proxy config ---
proxy_host = os.environ.get('HTTP_PROXY_HOST', '')
proxy_port = os.environ.get('HTTP_PROXY_PORT', '3128')
if proxy_host and not proxy_port.isdigit():
    print(f"ERROR: HTTP_PROXY_PORT must be an integer, got: {proxy_port!r}", file=sys.stderr)
    sys.exit(1)
no_proxy = [h.strip() for h in os.environ.get('NO_PROXY', '').split(',') if h.strip()]

use_proxy = False
if proxy_host:
    use_proxy = True
    for entry in no_proxy:
        if entry == '*':
            use_proxy = False
            break
        if entry == hostname:
            use_proxy = False
            break
        if entry.startswith('.') and (hostname.endswith(entry) or hostname == entry.lstrip('.')):
            use_proxy = False
            break

use_tls = scheme == 'https'
route_cluster = 'loopback_cluster' if use_proxy else 'upstream_provider'

# --- Envoy @type constants ---
T_HCM = 'type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager'
T_HEALTH = 'type.googleapis.com/envoy.extensions.filters.http.health_check.v3.HealthCheck'
T_JWT = 'type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication'
T_EXT_AUTHZ = 'type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz'
T_TCP_PROXY = 'type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy'
T_ROUTER = 'type.googleapis.com/envoy.extensions.filters.http.router.v3.Router'
T_TLS = 'type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext'

# --- Build envoy.yaml ---
lines = []

def w(indent, text=''):
    lines.append(' ' * indent + text)

def write_cluster(name, address, port_val, cluster_type='STRICT_DNS',
                  dns_family='V4_ONLY', tls_sni=None):
    w(4, f'- name: {name}')
    w(6, 'connect_timeout: 5s')
    w(6, f'type: {cluster_type}')
    if dns_family:
        w(6, f'dns_lookup_family: {dns_family}')
    w(6, 'load_assignment:')
    w(8, f'cluster_name: {name}')
    w(8, 'endpoints:')
    w(10, '- lb_endpoints:')
    w(14, '- endpoint:')
    w(18, 'address:')
    w(20, 'socket_address:')
    w(22, f'address: {address}')
    w(22, f'port_value: {port_val}')
    if tls_sni:
        w(6, 'transport_socket:')
        w(8, 'name: envoy.transport_sockets.tls')
        w(8, 'typed_config:')
        w(10, f'"@type": {T_TLS}')
        w(10, f'sni: {tls_sni}')

# -- Route config --
w(0, 'static_resources:')
w(2, 'listeners:')
w(4, '- name: listener_0')
w(6, 'address:')
w(8, 'socket_address:')
w(10, 'address: 0.0.0.0')
w(10, 'port_value: 10000')
w(6, 'filter_chains:')
w(8, '- filters:')
w(12, '- name: envoy.filters.network.http_connection_manager')
w(14, 'typed_config:')
w(16, f'"@type": {T_HCM}')
w(16, 'stat_prefix: ingress_http')
w(16, 'route_config:')
w(18, 'name: local_route')
w(18, 'virtual_hosts:')
w(20, '- name: upstream')
w(22, 'domains: ["*"]')
w(22, 'routes:')
w(24, '- match:')
w(28, 'prefix: "/"')
w(26, 'route:')
w(28, f'cluster: {route_cluster}')
w(28, f'host_rewrite_literal: {hostname}')
if path:
    w(28, f'prefix_rewrite: "{path}/"')
w(28, 'timeout: 0s')
w(28, 'idle_timeout: 300s')

# -- HTTP filters --
w(16, 'http_filters:')

# Health check filter (replaces separate /healthz route)
w(18, '- name: envoy.filters.http.health_check')
w(20, 'typed_config:')
w(22, f'"@type": {T_HEALTH}')
w(22, 'pass_through_mode: false')
w(22, 'headers:')
w(24, '- name: ":path"')
w(26, 'string_match:')
w(28, 'exact: "/healthz"')

# JWT authn filter (conditional)
if jwt_enabled:
    w(18, '- name: envoy.filters.http.jwt_authn')
    w(20, 'typed_config:')
    w(22, f'"@type": {T_JWT}')
    w(22, 'providers:')
    w(24, 'langsmith_jwt:')
    w(26, f'issuer: "{jwt_issuer}"')
    w(26, 'audiences:')
    w(28, f'- "{jwt_audience}"')
    w(26, 'local_jwks:')
    # NOTE: same single-quote escaping in deploy.sh for JWKS in service.yaml
    jwks_safe = jwks_json.replace("'", "''")
    w(28, "inline_string: '" + jwks_safe + "'")
    w(26, 'from_headers:')
    w(28, '- name: X-LangSmith-LLM-Auth')
    w(26, 'forward: true')
    w(22, 'rules:')
    w(24, '- match:')
    w(28, 'prefix: "/"')
    w(26, 'requires:')
    w(28, 'provider_name: langsmith_jwt')

# ext_authz filter (conditional)
if ext_authz_enabled:
    w(18, '- name: envoy.filters.http.ext_authz')
    w(20, 'typed_config:')
    w(22, f'"@type": {T_EXT_AUTHZ}')
    w(22, 'failure_mode_allow: false')
    w(22, 'allowed_headers:')
    w(24, 'patterns:')
    w(26, '- safe_regex:')
    w(30, 'regex: ".*"')
    w(22, 'http_service:')
    w(24, 'server_uri:')
    w(26, 'uri: http://localhost:10002')
    w(26, 'cluster: ext_authz_service')
    w(26, 'timeout: 10s')
    w(24, 'path_prefix: "/check"')
    w(24, 'authorization_response:')
    w(26, 'allowed_upstream_headers:')
    w(28, 'patterns:')
    w(30, '- safe_regex:')
    w(34, 'regex: ".*"')
    w(26, 'allowed_client_headers:')
    w(28, 'patterns:')
    w(30, '- exact: "www-authenticate"')
    w(30, '- prefix: "x-"')

# Router filter (always present)
w(18, '- name: envoy.filters.http.router')
w(20, 'typed_config:')
w(22, f'"@type": {T_ROUTER}')

# -- Second listener for proxy tunneling --
if use_proxy:
    w(4, '- name: listener_1')
    w(6, 'address:')
    w(8, 'socket_address:')
    w(10, 'address: 127.0.0.1')
    w(10, 'port_value: 10001')
    w(6, 'filter_chains:')
    w(8, '- filters:')
    w(12, '- name: envoy.filters.network.tcp_proxy')
    w(14, 'typed_config:')
    w(16, f'"@type": {T_TCP_PROXY}')
    w(16, 'stat_prefix: tcp_to_proxy')
    w(16, 'cluster: proxy_cluster')
    w(16, 'tunneling_config:')
    w(18, f'hostname: {hostname}:{port}')

# -- Clusters --
w(2)
w(2, 'clusters:')

if use_proxy:
    write_cluster('loopback_cluster', '127.0.0.1', 10001,
                  cluster_type='STATIC', dns_family=None,
                  tls_sni=hostname if use_tls else None)
    write_cluster('proxy_cluster', proxy_host, proxy_port)
else:
    write_cluster('upstream_provider', hostname, port,
                  cluster_type='LOGICAL_DNS',
                  tls_sni=hostname if use_tls else None)

if ext_authz_enabled:
    write_cluster('ext_authz_service', '127.0.0.1', 10002)

config = '\n'.join(lines) + '\n'
with open('/etc/envoy/envoy.yaml', 'w') as f:
    f.write(config)
PYEOF

echo "Starting Envoy..."
echo "  Upstream: ${UPSTREAM_URL}"
echo "  JWT issuer: ${JWT_ISSUER:-langsmith}"
echo "  JWT audience: ${JWT_AUDIENCE:-test-audience}"
echo "  JWT validation: ${JWT_VALIDATION_ENABLED:-true}"
echo "  Ext authz: ${EXT_AUTHZ_ENABLED:-true}"
if [ -n "${HTTP_PROXY_HOST:-}" ]; then
  echo "  HTTP proxy: ${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT:-3128}"
  [ -n "${NO_PROXY:-}" ] && echo "  NO_PROXY: ${NO_PROXY}"
fi
exec envoy -c /etc/envoy/envoy.yaml
