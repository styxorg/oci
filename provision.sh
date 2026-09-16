#!/usr/bin/env bash
# Keep retrying until the instance launches or a newer workflow cancels this run.
set -uo pipefail
export SUPPRESS_LABEL_WARNING=True

C="$OCI_COMPARTMENT"
AD="$OCI_AD"
SUBNET="$OCI_SUBNET"
INTERVAL=10
RATE_LIMIT_INTERVAL=60
attempt=1

echo "$SSH_PUBKEY" > /tmp/key.pub

while true; do
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Versuch #$attempt ..."

  CNT=$(oci compute instance list --compartment-id "$C" \
    --query "length(data[?\"display-name\"=='gotit' && \"lifecycle-state\"!='TERMINATED'])" \
    --raw-output 2>/dev/null || echo 0)
  if [ "${CNT:-0}" != "0" ]; then
    echo "gotit instance already exists (count=$CNT). Nothing to do."
    exit 0
  fi

  set +e
  ID=$(oci compute instance launch \
    --compartment-id "$C" \
    --availability-domain "$AD" \
    --shape VM.Standard.A1.Flex \
    --shape-config '{"ocpus":1,"memoryInGBs":6}' \
    --image-id "ocid1.image.oc1.eu-frankfurt-1.aaaaaaaafdyk3lbm3xfyp7mry2v5zk7yopvuzanxoodsoxnczaygxe4lltfq" \
    --subnet-id "$SUBNET" \
    --assign-public-ip true \
    --ssh-authorized-keys-file /tmp/key.pub --display-name gotit \
    --query 'data.id' --raw-output --wait-for-state RUNNING 2>/tmp/err.txt)
  rc=$?
  set -e

  if [ $rc -eq 0 ] && [ -n "${ID:-}" ]; then
    IP=$(oci compute instance list-vnics --instance-id "$ID" \
      --query 'data[0]."public-ip"' --raw-output)
    echo "SUCCESS instance=$ID ip=$IP"
    exit 0
  fi

  if grep -q "Too many requests for the user" /tmp/err.txt; then
    echo "Zu viele Requests. Nächster Versuch in ${RATE_LIMIT_INTERVAL}s ..."
    sleep "$RATE_LIMIT_INTERVAL"
    attempt=$((attempt + 1))
    continue
  fi

  if grep -q "Out of host capacity\|The connection to endpoint timed out" /tmp/err.txt; then
    if grep -q "The connection to endpoint timed out" /tmp/err.txt; then
      echo "Verbindung zum Endpoint abgelaufen. Nächster Versuch in ${INTERVAL}s ..."
    else
      echo "Out of host capacity. Nächster Versuch in ${INTERVAL}s ..."
    fi
  else
    echo "Unerwarteter Fehler; Workflow wird beendet:"
    cat /tmp/err.txt
    exit 1
  fi

  attempt=$((attempt + 1))
  sleep "$INTERVAL"
done
