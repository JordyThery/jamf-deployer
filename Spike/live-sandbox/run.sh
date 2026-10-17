#!/bin/zsh
# Phase 0 live spike runner. Credentials come from the login Keychain and are
# passed to tofu as environment variables only — never written to disk.
#
# One-time setup (run these yourself; values never touch this repo):
#   security add-generic-password -U -s JamfDeployer-Spike -a base-url       -w 'https://eu.api.jamfcloud.com'
#   security add-generic-password -U -s JamfDeployer-Spike -a client-id      -w '<client id>'
#   security add-generic-password -U -s JamfDeployer-Spike -a client-secret  -w '<client secret>'
#   security add-generic-password -U -s JamfDeployer-Spike -a environment-id -w '<environment uuid>'
#
# Usage: ./run.sh [plan|apply|refresh|destroy|output]
set -euo pipefail

HERE="${0:A:h}"
ROOT="${HERE:h:h}"
TOFU="$ROOT/Vendor/opentofu/bin/tofu"
FIX="$ROOT/Fixtures/live"
mkdir -p "$FIX"

kc() { security find-generic-password -s JamfDeployer-Spike -a "$1" -w; }

export TF_CLI_CONFIG_FILE="$ROOT/Spike/tofu.tfrc"
export JAMFPLATFORM_BASE_URL="$(kc base-url)"
export JAMFPLATFORM_CLIENT_ID="$(kc client-id)"
export JAMFPLATFORM_CLIENT_SECRET="$(kc client-secret)"
export JAMFPLATFORM_ENVIRONMENT_ID="$(kc environment-id)"
export TF_ENCRYPTION='
key_provider "pbkdf2" "passphrase" {
  passphrase = "spike-only-passphrase-not-a-secret"
}
method "aes_gcm" "default" {
  keys = key_provider.pbkdf2.passphrase
}
state {
  method   = method.aes_gcm.default
  enforced = true
}
plan {
  method   = method.aes_gcm.default
  enforced = true
}'

cd "$HERE"
MODE="${1:-plan}"

case "$MODE" in
  plan)
    "$TOFU" init -input=false
    "$TOFU" plan -input=false -out=plan.bin -json | tee "$FIX/plan-stream.jsonl"
    "$TOFU" show -json plan.bin > "$FIX/show-plan.json"
    echo "Plan captured. Review, then ./run.sh apply"
    ;;
  apply)
    "$TOFU" apply -input=false -json plan.bin | tee "$FIX/apply-stream.jsonl"
    "$TOFU" output -json > "$FIX/outputs.json"
    ;;
  refresh)
    "$TOFU" plan -refresh-only -input=false -json | tee "$FIX/plan-refresh-only.jsonl"
    ;;
  destroy)
    "$TOFU" plan -destroy -input=false -out=plan-destroy.bin -json | tee "$FIX/plan-stream-destroy.jsonl"
    "$TOFU" apply -input=false -json plan-destroy.bin | tee "$FIX/apply-stream-destroy.jsonl"
    ;;
  output)
    "$TOFU" output -json
    ;;
  *)
    echo "usage: run.sh [plan|apply|refresh|destroy|output]" >&2
    exit 64
    ;;
esac
