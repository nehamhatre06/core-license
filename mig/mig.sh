#!/bin/bash
set -euo pipefail
set -x  # Optional: for debug logging

# Directories
#BINDIR="$(dirname "$0")"
BINDIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
STATUS_FILE="/run/meter_license_status"
LOG_FILE="/run/meter_license_log"
DONE_MARKER="/var/local/uploader/.license_done"

# Skip if already done
if [ -f "$DONE_MARKER" ]; then
    echo "License already generated, skipping"
    exit 0
fi

# Reset status and log
rm -f "$STATUS_FILE" "$LOG_FILE"
echo 2 > "$STATUS_FILE"  # Running

# Trap errors
trap 'echo 1 > $STATUS_FILE; cat "$LOG_FILE"' ERR
trap 'cd /tmp; rm -rf "$WD"' EXIT

# Temporary working directory
WD="$(mktemp -d)"
cd "$WD"

# Generate TLS key
openssl ecparam -genkey -name prime256v1 -noout -out meter.key 2> "$LOG_FILE"
TLS_PUBKEY="$(openssl ec -in meter.key -pubout -outform DER | base64 -w0)" 2> "$LOG_FILE"

# Generate SSH key
ssh-keygen -t ed25519 -N '' -f "${HOSTNAME}"_ed25519 2> "$LOG_FILE"
SSH_PUBKEY="$(cat "${HOSTNAME}"_ed25519.pub)" 2> "$LOG_FILE"

# Fetch certificate from server
echo -ne "$HOSTNAME\n$TLS_PUBKEY\n$SSH_PUBKEY\n" | \
    ssh -T -o UserKnownHostsFile="$BINDIR/known_hosts" \
        -o StrictHostKeyChecking=yes \
        -o CheckHostIP=no \
        -o IdentitiesOnly=yes \
        -i "$BINDIR/meter-ca_ed25519" \
       meter@core-license.barcindia.in 2> "$LOG_FILE" \
    > ./certs

# Read TLS and SSH certs
exec {certs}<>certs
read TLS_CERT <&$certs
IFS='' read SSH_CERT <&$certs
exec {certs}<>-

# Create persistent directories
mkdir -p /var/local/uploader/certs /var/local/portkey

# Atomic write of TLS cert
tmp=$(mktemp /var/local/uploader/certs/.tmp.XXXX)
openssl x509 -in <(echo "$TLS_CERT" | base64 --decode) -inform DER -out "$tmp" -outform PEM 2> "$LOG_FILE"
mv "$tmp" /var/local/uploader/certs/meter.crt

# Move TLS key
mv meter.key /var/local/uploader/certs/meter.key 2> "$LOG_FILE"
cp "$BINDIR/ca.crt" /var/local/uploader/certs/ca.crt 2> "$LOG_FILE"

# Save environment variables
echo 'CERTS_PATH="/var/local/uploader/certs/"' > /var/local/uploader.env 2> "$LOG_FILE"
if [ "$(cat "$BINDIR/instance")" == "alpha" ]; then
    echo 'NATS_URL="nats://broker-core.barcindia.in:4222"' >> /var/local/uploader.env 2> "$LOG_FILE"
fi

# Save SSH cert
#echo "$SSH_CERT" > /var/local/portkey/"${HOSTNAME}"_ed25519-cert.pub 2> "$LOG_FILE"
#mv "${HOSTNAME}_ed25519" /var/local/portkey/"${HOSTNAME}"_ed25519-cert 2> "$LOG_FILE"

# Mark success
sync
touch "$DONE_MARKER"
echo 0 > "$STATUS_FILE"
exit 0
