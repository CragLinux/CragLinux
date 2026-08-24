#!/bin/bash
set -euo pipefail

# Crag Linux - key management (docs/05 §6, docs/09 §4)
#
# Subcommands:
#   init-dev [--force]   (Re)generate the development-only RAUC PKI under
#                        keys/dev/. Committed to the repo on purpose: dev
#                        and CI builds exercise the full sign/verify path
#                        with loudly-fake keys. Idempotent unless --force.
#
# Prod PKI is deliberately NOT handled here (offline/HSM root; release
# signing certs live in the CI secret store — docs/05 §6).
#
# Generated files (all committed):
#   keys/dev/rauc-ca.pem            CA cert = the device keyring for dev images
#   keys/dev/rauc-ca.key.pem        CA private key (dev-only convenience)
#   keys/dev/rauc-signing.cert.pem  bundle signing cert (issued by the dev CA)
#   keys/dev/rauc-signing.key.pem   bundle signing key
#   keys/dev/ssh-test / .pub        SSH keypair injected into DEV-variant
#                                   images (root authorized_keys) so the
#                                   AD-020 test harness and `crag deploy`
#                                   (M4) can drive dev guests; never in prod

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEV_DIR="${PROJECT_ROOT}/keys/dev"

CMD="${1:?Usage: $0 init-dev [--force]}"
FORCE=false
[ "${2:-}" = "--force" ] && FORCE=true

[ "$CMD" = "init-dev" ] || { echo "ERROR: unknown subcommand: $CMD"; exit 1; }
command -v openssl >/dev/null || { echo "ERROR: openssl not found"; exit 1; }

CA_CERT="${DEV_DIR}/rauc-ca.pem"
CA_KEY="${DEV_DIR}/rauc-ca.key.pem"
SIGN_CERT="${DEV_DIR}/rauc-signing.cert.pem"
SIGN_KEY="${DEV_DIR}/rauc-signing.key.pem"

SSH_KEY="${DEV_DIR}/ssh-test"

if [ "$FORCE" = false ] && [ -f "$CA_CERT" ] && [ -f "$CA_KEY" ] && \
   [ -f "$SIGN_CERT" ] && [ -f "$SIGN_KEY" ] && [ -f "$SSH_KEY" ]; then
    echo "[INFO] Dev RAUC PKI already present in keys/dev/ (use --force to regenerate)"
    exit 0
fi

mkdir -p "$DEV_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Regenerate the RAUC chain only if any piece is missing (or --force):
# rotating the dev CA invalidates every already-built dev image's keyring.
if [ "$FORCE" = true ] || [ ! -f "$CA_CERT" ] || [ ! -f "$CA_KEY" ] || \
   [ ! -f "$SIGN_CERT" ] || [ ! -f "$SIGN_KEY" ]; then
    echo "[INFO] Generating dev RAUC CA (EC P-256, 10 years)..."
    openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY"
    openssl req -new -x509 -key "$CA_KEY" -out "$CA_CERT" -days 3650 \
        -subj "/O=TierOne Software/OU=CRAG DEV - DO NOT SHIP/CN=Crag Dev RAUC CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"

    echo "[INFO] Generating dev bundle signing cert (issued by the dev CA)..."
    openssl ecparam -name prime256v1 -genkey -noout -out "$SIGN_KEY"
    openssl req -new -key "$SIGN_KEY" -out "$TMP/signing.csr" \
        -subj "/O=TierOne Software/OU=CRAG DEV - DO NOT SHIP/CN=Crag Dev Bundle Signer"
    cat > "$TMP/signing.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning,emailProtection
EOF
    openssl x509 -req -in "$TMP/signing.csr" -CA "$CA_CERT" -CAkey "$CA_KEY" \
        -CAcreateserial -out "$SIGN_CERT" -days 3650 -extfile "$TMP/signing.ext"
    rm -f "${DEV_DIR}/rauc-ca.srl" "${CA_CERT%.pem}.srl" 2>/dev/null || :

    echo "[INFO] Verifying chain..."
    openssl verify -CAfile "$CA_CERT" "$SIGN_CERT"
fi

if [ ! -f "$SSH_KEY" ] || [ "$FORCE" = true ]; then
    echo "[INFO] Generating dev SSH test key (ed25519)..."
    rm -f "$SSH_KEY" "${SSH_KEY}.pub"
    ssh-keygen -q -t ed25519 -N "" -C "crag-dev-test-DO-NOT-SHIP" -f "$SSH_KEY"
fi

echo ""
echo "[INFO] Dev RAUC PKI written to keys/dev/:"
ls -l "$CA_CERT" "$CA_KEY" "$SIGN_CERT" "$SIGN_KEY"
echo ""
echo "  Keyring for dev/CI images: keys/dev/rauc-ca.pem"
echo "  Bundle signing:            rauc bundle --cert=keys/dev/rauc-signing.cert.pem --key=keys/dev/rauc-signing.key.pem"
