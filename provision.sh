#!/usr/bin/env bash
# Runs in GitHub Actions every 15 min. Tries to launch the Always-Free ARM
# On capacity error: quiet exit.
set -uo pipefail
export SUPPRESS_LABEL_WARNING=True

C="$OCI_COMPARTMENT"
AD="$OCI_AD"
SUBNET="$OCI_SUBNET"

# Already have a (non-terminated) gotit instance? Then stop hunting.
CNT=$(oci compute instance list --compartment-id "$C" \
  --query "length(data[?\"display-name\"=='gotit' && \"lifecycle-state\"!='TERMINATED'])" \
  --raw-output 2>/dev/null || echo 0)
if [ "${CNT:-0}" != "0" ]; then
  echo "gotit instance already exists (count=$CNT). Nothing to do."
  exit 0
fi

echo "$SSH_PUBKEY" > /tmp/key.pub

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

if [ $rc -ne 0 ] || [ -z "${ID:-}" ]; then
  if grep -q "Out of host capacity" /tmp/err.txt; then
    echo "Out of host capacity — retry next run."
    exit 0
  fi
  echo "Launch error (non-capacity):"; cat /tmp/err.txt
  exit 0  # never fail the workflow on transient errors
fi

IP=$(oci compute instance list-vnics --instance-id "$ID" \
  --query 'data[0]."public-ip"' --raw-output)
echo "SUCCESS instance=$ID ip=$IP"
