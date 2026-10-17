#!/bin/zsh
# Re-fetches the pinned, checksum-verified engine and tool binaries that are
# kept out of git. Run after a fresh clone. Versions change only via this file.
set -euo pipefail

HERE="${0:A:h}"

OPENTOFU_VERSION="1.13.1"
JAMFPLATFORM_VERSION="1.5.0"
JAMFPROTECT_VERSION="0.12.0"
JAMFORMER_VERSION="0.6.0"

echo "== OpenTofu $OPENTOFU_VERSION =="
mkdir -p "$HERE/opentofu/bin"
cd "$HERE/opentofu"
for arch in arm64 amd64; do
  [[ -f "tofu_${OPENTOFU_VERSION}_darwin_${arch}.zip" ]] || \
    curl -sL -O "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_darwin_${arch}.zip"
done
curl -sL -O "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_SHA256SUMS"
shasum -a 256 -c <(grep "darwin.*zip" "tofu_${OPENTOFU_VERSION}_SHA256SUMS")
unzip -oq "tofu_${OPENTOFU_VERSION}_darwin_arm64.zip" -d bin

echo "== jamfplatform provider $JAMFPLATFORM_VERSION =="
DIR="$HERE/providers/registry.opentofu.org/jamf/jamfplatform"
mkdir -p "$DIR"; cd "$DIR"
for arch in arm64 amd64; do
  [[ -f "terraform-provider-jamfplatform_${JAMFPLATFORM_VERSION}_darwin_${arch}.zip" ]] || \
    curl -sL -O "https://github.com/jamf/terraform-provider-jamfplatform/releases/download/v${JAMFPLATFORM_VERSION}/terraform-provider-jamfplatform_${JAMFPLATFORM_VERSION}_darwin_${arch}.zip"
done
curl -sL -O "https://github.com/jamf/terraform-provider-jamfplatform/releases/download/v${JAMFPLATFORM_VERSION}/terraform-provider-jamfplatform_${JAMFPLATFORM_VERSION}_SHA256SUMS"
shasum -a 256 -c <(grep darwin "terraform-provider-jamfplatform_${JAMFPLATFORM_VERSION}_SHA256SUMS")

echo "== jamfprotect provider $JAMFPROTECT_VERSION =="
DIR="$HERE/providers/registry.opentofu.org/jamf-concepts/jamfprotect"
mkdir -p "$DIR"; cd "$DIR"
for arch in arm64 amd64; do
  [[ -f "terraform-provider-jamfprotect_${JAMFPROTECT_VERSION}_darwin_${arch}.zip" ]] || \
    curl -sL -O "https://github.com/Jamf-Concepts/terraform-provider-jamfprotect/releases/download/v${JAMFPROTECT_VERSION}/terraform-provider-jamfprotect_${JAMFPROTECT_VERSION}_darwin_${arch}.zip"
done
curl -sL -O "https://github.com/Jamf-Concepts/terraform-provider-jamfprotect/releases/download/v${JAMFPROTECT_VERSION}/terraform-provider-jamfprotect_${JAMFPROTECT_VERSION}_SHA256SUMS"
shasum -a 256 -c <(grep darwin "terraform-provider-jamfprotect_${JAMFPROTECT_VERSION}_SHA256SUMS")

echo "== jamformer $JAMFORMER_VERSION =="
cd "$HERE/jamformer"
[[ -f "jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz" ]] || \
  curl -sL -O "https://github.com/Jamf-Concepts/jamformer/releases/download/v${JAMFORMER_VERSION}/jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz"
tar -xzf "jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz" jamformer

echo "All vendored binaries fetched and verified."
