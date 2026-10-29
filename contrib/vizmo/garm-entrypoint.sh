#!/bin/sh
# Starts GARM. With GARM_RENDER_CONFIG=true it first writes config.toml and
# the Azure provider config from environment variables, so a platform such as
# Coolify can run GARM with only env vars and one data volume. Without it,
# GARM starts exactly as in the upstream image.
set -eu

CONFIG_DIR="${GARM_CONFIG_DIR:-/etc/garm}"
CONFIG_FILE="$CONFIG_DIR/config.toml"

if [ "${GARM_RENDER_CONFIG:-false}" != "true" ]; then
	exec /bin/garm --config "$CONFIG_FILE" "$@"
fi

DATA_DIR="${GARM_DATA_DIR:-/var/lib/garm}"
AZURE_CONFIG_FILE="$CONFIG_DIR/garm-provider-azure.toml"

die() {
	echo "garm-entrypoint: $*" >&2
	exit 1
}

# random_secret LENGTH prints LENGTH random alphanumeric characters.
random_secret() {
	head -c 512 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"
}

# persistent_secret FILE LENGTH prints the secret kept in FILE, creating it
# on first start. The file lives on the data volume next to the database,
# because the database passphrase must never change once data is encrypted.
persistent_secret() {
	if [ ! -s "$1" ]; then
		random_secret "$2" >"$1.tmp"
		mv "$1.tmp" "$1"
	fi
	cat "$1"
}

# literal NAME VALUE prints VALUE as a TOML literal string.
literal() {
	case "$2" in
	*\'*) die "$1 must not contain a single quote" ;;
	esac
	printf "'%s'" "$2"
}

: "${AZURE_LOCATION:?AZURE_LOCATION is required}"
: "${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID is required}"
: "${AZURE_TENANT_ID:?AZURE_TENANT_ID is required}"
: "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID is required}"

# The service principal signs in with either a client secret or a
# certificate. AZURE_CLIENT_CERTIFICATE holds the PEM with the certificate
# and private key, as-is or base64 encoded (one line, easier to paste).
AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET:-}"
AZURE_CLIENT_CERTIFICATE="${AZURE_CLIENT_CERTIFICATE:-}"
if [ -z "$AZURE_CLIENT_SECRET" ] && [ -z "$AZURE_CLIENT_CERTIFICATE" ]; then
	die "set AZURE_CLIENT_SECRET or AZURE_CLIENT_CERTIFICATE"
fi
if [ -n "$AZURE_CLIENT_SECRET" ] && [ -n "$AZURE_CLIENT_CERTIFICATE" ]; then
	die "set only one of AZURE_CLIENT_SECRET and AZURE_CLIENT_CERTIFICATE"
fi

umask 077
mkdir -p "$CONFIG_DIR" "$DATA_DIR"

AZURE_CERTIFICATE_FILE="$CONFIG_DIR/azure-sp.pem"
if [ -n "$AZURE_CLIENT_CERTIFICATE" ]; then
	case "$AZURE_CLIENT_CERTIFICATE" in
	*"-----BEGIN"*) printf '%s\n' "$AZURE_CLIENT_CERTIFICATE" >"$AZURE_CERTIFICATE_FILE" ;;
	*) printf '%s' "$AZURE_CLIENT_CERTIFICATE" | base64 -d >"$AZURE_CERTIFICATE_FILE" ||
		die "AZURE_CLIENT_CERTIFICATE is neither PEM nor valid base64" ;;
	esac
	grep -q -- "-----BEGIN CERTIFICATE-----" "$AZURE_CERTIFICATE_FILE" ||
		die "AZURE_CLIENT_CERTIFICATE has no certificate"
	grep -q -- "PRIVATE KEY-----" "$AZURE_CERTIFICATE_FILE" ||
		die "AZURE_CLIENT_CERTIFICATE has no private key"
fi

JWT_SECRET="${GARM_JWT_SECRET:-$(persistent_secret "$DATA_DIR/jwt_secret" 64)}"
DB_PASSPHRASE="${GARM_DB_PASSPHRASE:-$(persistent_secret "$DATA_DIR/db_passphrase" 32)}"

# Build every quoted value before writing, so a bad value stops startup here
# instead of inside a command substitution in the heredocs below.
jwt_secret=$(literal GARM_JWT_SECRET "$JWT_SECRET")
db_passphrase=$(literal GARM_DB_PASSPHRASE "$DB_PASSPHRASE")
location=$(literal AZURE_LOCATION "$AZURE_LOCATION")
subscription_id=$(literal AZURE_SUBSCRIPTION_ID "$AZURE_SUBSCRIPTION_ID")
tenant_id=$(literal AZURE_TENANT_ID "$AZURE_TENANT_ID")
client_id=$(literal AZURE_CLIENT_ID "$AZURE_CLIENT_ID")
if [ -n "$AZURE_CLIENT_CERTIFICATE" ]; then
	client_credential="client_certificate_path = $(literal GARM_CONFIG_DIR "$AZURE_CERTIFICATE_FILE")"
else
	client_credential="client_secret = $(literal AZURE_CLIENT_SECRET "$AZURE_CLIENT_SECRET")"
fi
vnet_cidr=$(literal AZURE_VNET_CIDR "${AZURE_VNET_CIDR:-10.10.0.0/24}")

cat >"$CONFIG_FILE" <<EOF
[default]
enable_webhook_management = false

[logging]
enable_log_streamer = true
log_format = "text"
log_level = "${GARM_LOG_LEVEL:-info}"

[metrics]
enable = true
disable_auth = false

[jwt_auth]
secret = $jwt_secret
time_to_live = "${GARM_JWT_TTL:-8760h}"

[apiserver]
bind = "0.0.0.0"
port = ${GARM_PORT:-9997}
use_tls = false

[apiserver.webui]
enable = true

[database]
backend = "sqlite3"
passphrase = $db_passphrase

[database.sqlite3]
db_file = "$DATA_DIR/garm.db"

[[provider]]
name = "${GARM_AZURE_PROVIDER_NAME:-azure}"
provider_type = "external"
description = "Azure $AZURE_LOCATION"

[provider.external]
provider_executable = "/opt/garm/providers.d/garm-provider-azure"
config_file = "$AZURE_CONFIG_FILE"
EOF

cat >"$AZURE_CONFIG_FILE" <<EOF
location = $location
use_ephemeral_storage = false
use_accelerated_networking = ${AZURE_ACCELERATED_NETWORKING:-true}
virtual_network_cidr = $vnet_cidr

[credentials]
subscription_id = $subscription_id

[credentials.service_principal]
tenant_id = $tenant_id
client_id = $client_id
$client_credential
EOF

exec /bin/garm --config "$CONFIG_FILE" "$@"
