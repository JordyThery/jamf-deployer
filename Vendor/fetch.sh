#!/bin/zsh
# Re-fetches the pinned, checksum-verified engine and tool binaries that are
# kept out of git. Run after a fresh clone. Versions change only via this file.
set -euo pipefail

HERE="${0:A:h}"

OPENTOFU_VERSION="1.13.2"
JAMFPLATFORM_VERSION="1.6.0"
JAMFPROTECT_VERSION="0.12.0"
JAMFPRO_VERSION="0.42.0"
JAMFORMER_VERSION="0.6.1"
# jamformer's download has no LICENSE; the one from its repository at that tag.
# Update the checksum with the version, and the text in JamfDeployerCore/Licences.
JAMFORMER_LICENSE_SHA256="a0df87821e031b784e010f350e83ce099201fbf4a06718e8d8662430be5c5640"
BACKEND_GIT_VERSION="0.1.12"

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

echo "== jamfpro provider $JAMFPRO_VERSION (Deployment Theory, MPL-2.0) =="
DIR="$HERE/providers/registry.opentofu.org/deploymenttheory/jamfpro"
mkdir -p "$DIR"; cd "$DIR"
for arch in arm64 amd64; do
  [[ -f "terraform-provider-jamfpro_${JAMFPRO_VERSION}_darwin_${arch}.zip" ]] || \
    curl -sL -O "https://github.com/deploymenttheory/terraform-provider-jamfpro/releases/download/v${JAMFPRO_VERSION}/terraform-provider-jamfpro_${JAMFPRO_VERSION}_darwin_${arch}.zip"
done
curl -sL -O "https://github.com/deploymenttheory/terraform-provider-jamfpro/releases/download/v${JAMFPRO_VERSION}/terraform-provider-jamfpro_${JAMFPRO_VERSION}_SHA256SUMS"
shasum -a 256 -c <(grep darwin "terraform-provider-jamfpro_${JAMFPRO_VERSION}_SHA256SUMS")

echo "== jamformer $JAMFORMER_VERSION =="
mkdir -p "$HERE/jamformer"
cd "$HERE/jamformer"
BASE="https://github.com/Jamf-Concepts/jamformer/releases/download/v${JAMFORMER_VERSION}"
[[ -f "jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz" ]] || \
  curl -sL -O "$BASE/jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz"
curl -sL -O "$BASE/checksums.txt"
shasum -a 256 -c <(grep " jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz$" checksums.txt)
tar -xzf "jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz" jamformer
curl -fsSL -o LICENSE "https://raw.githubusercontent.com/Jamf-Concepts/jamformer/v${JAMFORMER_VERSION}/LICENSE"
echo "${JAMFORMER_LICENSE_SHA256}  LICENSE" | shasum -a 256 -c

echo "== terraform-backend-git $BACKEND_GIT_VERSION (plumber-cd, Apache-2.0) =="
mkdir -p "$HERE/terraform-backend-git"
cd "$HERE/terraform-backend-git"
BASE="https://github.com/plumber-cd/terraform-backend-git/releases/download/v${BACKEND_GIT_VERSION}"
curl -sL -o terraform-backend-git-darwin-arm64 "$BASE/terraform-backend-git-darwin-arm64"
curl -sL -O "$BASE/SHA256SUMS"
shasum -a 256 -c <(grep "darwin-arm64$" SHA256SUMS)
mv -f terraform-backend-git-darwin-arm64 terraform-backend-git
chmod +x terraform-backend-git
curl -sL -o LICENSE "https://raw.githubusercontent.com/plumber-cd/terraform-backend-git/v${BACKEND_GIT_VERSION}/LICENSE"

echo "All vendored binaries fetched and verified."
