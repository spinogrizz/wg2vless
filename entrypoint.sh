#!/usr/bin/env bash
set -euo pipefail

# ============ Logging ============

# Colors (disabled if not tty)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  CYAN=''
  NC=''
fi

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $*"; }
die()       { log_error "$@"; exit 1; }

# ============ Utils ============

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

urldecode() {
  printf '%b' "${1//%/\\x}"
}

# ============ Defaults ============

init_defaults() {
  DATA_DIR="${DATA_DIR:-/data}"
  XRAY_CONFIG="${XRAY_CONFIG:-/tmp/config.json}"
  TEMPLATE_DIR="${TEMPLATE_DIR:-/app/templates}"

  WG_PORT="${WG_PORT:-51820}"
  WG_SERVER_IP="${WG_SERVER_IP:-10.66.66.1}"
  WG_CLIENT_IP="${WG_CLIENT_IP:-10.66.66.2}"
  WG_SUBNET_CIDR="${WG_SUBNET_CIDR:-10.66.66.0/24}"
  WG_MTU="${WG_MTU:-1420}"
  WG_DNS="${WG_DNS:-1.1.1.1,8.8.8.8}"
  WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0,::/0}"
  WG_ENDPOINT="${WG_ENDPOINT:-}"

  XRAY_LOGLEVEL="${XRAY_LOGLEVEL:-warning}"

  # VLESS defaults
  VLESS_HOST="${VLESS_HOST:-}"
  VLESS_PORT="${VLESS_PORT:-}"
  VLESS_UUID="${VLESS_UUID:-}"
  VLESS_SECURITY="${VLESS_SECURITY:-reality}"
  VLESS_SNI="${VLESS_SNI:-}"
  VLESS_FLOW="${VLESS_FLOW:-xtls-rprx-vision}"
  VLESS_FP="${VLESS_FP:-chrome}"
  VLESS_PBK="${VLESS_PBK:-}"
  VLESS_SID="${VLESS_SID:-}"
  VLESS_SPIDERX="${VLESS_SPIDERX:-/}"
  VLESS_TRANSPORT="${VLESS_TRANSPORT:-tcp}"

  # Key file paths
  mkdir -p "${DATA_DIR}"
  SERVER_PRIV="${DATA_DIR}/server_private.key"
  SERVER_PUB="${DATA_DIR}/server_public.key"
  CLIENT_PRIV="${DATA_DIR}/client_private.key"
  CLIENT_PUB="${DATA_DIR}/client_public.key"
}

# ============ WireGuard Keys ============

gen_wg_keypair() {
  wg genkey | tee "$1" | wg pubkey > "$2"
}

ensure_wg_keys() {
  if [[ ! -s "$SERVER_PRIV" || ! -s "$SERVER_PUB" ]]; then
    log_info "Generating server WireGuard keypair..."
    gen_wg_keypair "$SERVER_PRIV" "$SERVER_PUB"
  fi

  if [[ ! -s "$CLIENT_PRIV" || ! -s "$CLIENT_PUB" ]]; then
    log_info "Generating client WireGuard keypair..."
    gen_wg_keypair "$CLIENT_PRIV" "$CLIENT_PUB"
  fi

  SERVER_PRIVATE_KEY="$(cat "$SERVER_PRIV")"
  SERVER_PUBLIC_KEY="$(cat "$SERVER_PUB")"
  CLIENT_PRIVATE_KEY="$(cat "$CLIENT_PRIV")"
  CLIENT_PUBLIC_KEY="$(cat "$CLIENT_PUB")"

  log_info "WireGuard keys loaded"
}

# ============ VLESS Parsing ============

parse_vless_url() {
  local url="$1" base query hostport userinfo

  url="${url#vless://}"
  base="${url%%\?*}"
  query=""
  if [[ "$url" == *\?* ]]; then
    query="${url#*\?}"
    query="${query%%#*}"
  fi

  userinfo="${base%@*}"
  hostport="${base#*@}"

  VLESS_UUID="$userinfo"
  VLESS_HOST="${hostport%:*}"
  VLESS_PORT="${hostport##*:}"

  IFS='&' read -ra pairs <<< "$query"
  for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    val="$(urldecode "${pair#*=}")"
    case "$key" in
      security) VLESS_SECURITY="$val" ;;
      sni) VLESS_SNI="$val" ;;
      flow) VLESS_FLOW="$val" ;;
      fp) VLESS_FP="$val" ;;
      pbk) VLESS_PBK="$val" ;;
      sid) VLESS_SID="$val" ;;
      spiderX|spx) VLESS_SPIDERX="$val" ;;
      type) VLESS_TRANSPORT="$val" ;;
    esac
  done

  log_info "Parsed VLESS URL for ${VLESS_HOST}:${VLESS_PORT}"
}

parse_vless_config() {
  if [[ -n "${VLESS_URL:-}" ]]; then
    log_info "Parsing VLESS configuration from URL..."
    parse_vless_url "$VLESS_URL"
  else
    log_info "Using VLESS configuration from environment variables"
  fi
}

validate_vless_config() {
  [[ -n "$VLESS_HOST" ]] || die "VLESS_HOST or VLESS_URL is required"
  [[ -n "$VLESS_PORT" ]] || die "VLESS_PORT or VLESS_URL is required"
  [[ -n "$VLESS_UUID" ]] || die "VLESS_UUID or VLESS_URL is required"

  if [[ "$VLESS_SECURITY" == "reality" ]]; then
    [[ -n "$VLESS_SNI" ]] || die "VLESS_SNI or VLESS_URL with sni= is required for REALITY"
    [[ -n "$VLESS_PBK" ]] || die "VLESS_PBK or VLESS_URL with pbk= is required for REALITY"
  elif [[ "$VLESS_SECURITY" == "tls" ]]; then
    [[ -n "$VLESS_SNI" ]] || die "VLESS_SNI or VLESS_URL with sni= is required for TLS"
  fi

  log_info "VLESS config validated: ${VLESS_HOST}:${VLESS_PORT} (security: ${VLESS_SECURITY})"
}

# ============ Config Generation ============

build_stream_settings() {
  local stream_settings

  if [[ "$VLESS_SECURITY" == "reality" ]]; then
    stream_settings="$(jq -nc \
      --arg network "$VLESS_TRANSPORT" \
      --arg serverName "$VLESS_SNI" \
      --arg fingerprint "$VLESS_FP" \
      --arg publicKey "$VLESS_PBK" \
      --arg shortId "$VLESS_SID" \
      --arg spiderX "$VLESS_SPIDERX" \
      '{
        network: $network,
        security: "reality",
        realitySettings: {
          serverName: $serverName,
          fingerprint: $fingerprint,
          publicKey: $publicKey,
          shortId: $shortId,
          spiderX: $spiderX
        }
      }')"
  elif [[ "$VLESS_SECURITY" == "tls" ]]; then
    stream_settings="$(jq -nc \
      --arg network "$VLESS_TRANSPORT" \
      --arg serverName "$VLESS_SNI" \
      --arg fingerprint "$VLESS_FP" \
      '{
        network: $network,
        security: "tls",
        tlsSettings: {
          serverName: $serverName,
          fingerprint: $fingerprint
        }
      }')"
  else
    stream_settings="$(jq -nc \
      --arg network "$VLESS_TRANSPORT" \
      '{network: $network}')"
  fi

  echo "$stream_settings"
}

generate_xray_config() {
  log_info "Generating Xray configuration..."

  # Build computed values and export for envsubst
  export STREAM_SETTINGS="$(build_stream_settings)"

  # Build DNS array from comma-separated list
  IFS=',' read -ra DNS_ARR <<< "$WG_DNS"
  export DNS_JSON="$(printf '%s\n' "${DNS_ARR[@]}" | jq -R . | jq -s .)"

  # Export all variables needed by template
  export XRAY_LOGLEVEL WG_PORT SERVER_PRIVATE_KEY WG_MTU
  export CLIENT_PUBLIC_KEY WG_CLIENT_IP
  export VLESS_HOST VLESS_PORT VLESS_UUID VLESS_FLOW

  envsubst < "${TEMPLATE_DIR}/xray.json.tmpl" > "$XRAY_CONFIG"

  log_info "Xray config written to ${XRAY_CONFIG}"
}

validate_xray_config() {
  if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
    log_error "Generated Xray config is invalid JSON:"
    cat "$XRAY_CONFIG" >&2
    exit 1
  fi
  log_info "Xray config validated successfully"
}

generate_wg_client_config() {
  local wg_client_conf="${DATA_DIR}/client.conf"

  log_info "Generating WireGuard client configuration..."

  # Export variables for envsubst (set default for endpoint)
  export WG_ENDPOINT="${WG_ENDPOINT:-<YOUR_SERVER_IP>}"
  export CLIENT_PRIVATE_KEY WG_CLIENT_IP WG_DNS
  export SERVER_PUBLIC_KEY WG_PORT WG_ALLOWED_IPS WG_MTU

  envsubst < "${TEMPLATE_DIR}/client.conf.tmpl" > "$wg_client_conf"

  log_info "WireGuard client config saved to ${wg_client_conf}"

  # Print config for easy copying
  echo ""
  echo "========== WireGuard Client Config =========="
  cat "$wg_client_conf"
  echo "============================================="
  echo ""
}

# ============ Main ============

main() {
  log_info "Starting wg2vless bridge..."

  # Check required commands
  need_cmd xray
  need_cmd wg
  need_cmd jq
  need_cmd envsubst

  # Initialize
  init_defaults
  ensure_wg_keys

  # Parse and validate VLESS config
  parse_vless_config
  validate_vless_config

  # Generate configs
  generate_xray_config
  validate_xray_config
  generate_wg_client_config

  # Run Xray
  log_info "Starting Xray..."
  exec xray run -config "$XRAY_CONFIG"
}

main "$@"
