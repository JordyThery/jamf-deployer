#!/bin/zsh
# Re-fetches the pinned, checksum-verified engine and tool binaries that are
# kept out of git. Run after a fresh clone. Versions change only via this file
# (the Terraform that Capture and Adopt download is pinned separately, in
# Export/TerraformManager.swift).
#
# Every download is checked against a SHA-256 pinned here, never against a
# checksum file from the same release: a replaced release asset fails the
# check. When a version changes, take the new hashes from the release's
# checksum file (and compare them with a second source, such as the
# registry's), then update them here with the version.
set -euo pipefail

HERE="${0:A:h}"

OPENTOFU_VERSION="1.13.9"
OPENTOFU_SHA256_ARM64="29ba2f4c78556a8d25476e5070fe4745495ef649c4a3b827170eb7436d23feb3"
OPENTOFU_SHA256_AMD64="ac5505dd19d896f327d0ab727d4b853413c694931a7602b31f93c3a3e9d46d00"
JAMFPLATFORM_VERSION="1.10.0"
JAMFPLATFORM_SHA256_ARM64="bed5075734941532113709fca269ae332508be2257eafb6385b1234c97bc2e96"
JAMFPLATFORM_SHA256_AMD64="c1bac4838ebaece3f2e4cf317b66f7549752c250ebadd7b1b639a394860d496b"
JAMFPROTECT_VERSION="0.13.0"
JAMFPROTECT_SHA256_ARM64="422a791228cf72aec277385c6db223536b2a359237b293b324e3748e42467018"
JAMFPROTECT_SHA256_AMD64="9c36e9eb2250063090a07b0182bbee814afd5f7d5e65e9eae1cad13c42a73838"
JAMFPRO_VERSION="0.43.0"
JAMFPRO_SHA256_ARM64="88827a74d41cce224625956ddccf0afbcfe71480ee4cd8231761a04756079b14"
JAMFPRO_SHA256_AMD64="602e1436595c84a59f2a78fa0e0c88c5a55e5aec37959158172277db4a8bc12c"
JAMFORMER_VERSION="0.7.0"
JAMFORMER_SHA256="9b2880c015efff5578a92d139d8ad1392ed457cf6208e2838cac70e4888f0c1a"
# jamformer's download has no LICENSE; the one from its repository at that tag.
# Update the checksum with the version, and the text in JamfDeployerCore/Licences.
JAMFORMER_LICENSE_SHA256="a0df87821e031b784e010f350e83ce099201fbf4a06718e8d8662430be5c5640"
BACKEND_GIT_VERSION="0.1.12"
BACKEND_GIT_SHA256_ARM64="c91880b5786242fc8f721ecdc5b523f80af2ca2e165555337452e223f8d24997"
BACKEND_GIT_LICENSE_SHA256="c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4"

# verify <file> <sha256>
verify() {
  echo "$2  $1" | shasum -a 256 -c
}

# fetch <url> <file>: downloads unless already there; a failed request stops.
fetch() {
  [[ -f "$2" ]] || curl -fsSL -o "$2" "$1"
}

echo "== OpenTofu $OPENTOFU_VERSION =="
mkdir -p "$HERE/opentofu/bin"
cd "$HERE/opentofu"
BASE="https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}"
fetch "$BASE/tofu_${OPENTOFU_VERSION}_darwin_arm64.zip" "tofu_${OPENTOFU_VERSION}_darwin_arm64.zip"
fetch "$BASE/tofu_${OPENTOFU_VERSION}_darwin_amd64.zip" "tofu_${OPENTOFU_VERSION}_darwin_amd64.zip"
verify "tofu_${OPENTOFU_VERSION}_darwin_arm64.zip" "$OPENTOFU_SHA256_ARM64"
verify "tofu_${OPENTOFU_VERSION}_darwin_amd64.zip" "$OPENTOFU_SHA256_AMD64"
unzip -oq "tofu_${OPENTOFU_VERSION}_darwin_arm64.zip" -d bin

# provider <directory> <download base> <name> <version> <arm64 sha> <amd64 sha>
provider() {
  mkdir -p "$1"; cd "$1"
  fetch "$2/terraform-provider-$3_$4_darwin_arm64.zip" "terraform-provider-$3_$4_darwin_arm64.zip"
  fetch "$2/terraform-provider-$3_$4_darwin_amd64.zip" "terraform-provider-$3_$4_darwin_amd64.zip"
  verify "terraform-provider-$3_$4_darwin_arm64.zip" "$5"
  verify "terraform-provider-$3_$4_darwin_amd64.zip" "$6"
}

echo "== jamfplatform provider $JAMFPLATFORM_VERSION =="
provider "$HERE/providers/registry.opentofu.org/jamf/jamfplatform" \
  "https://github.com/jamf/terraform-provider-jamfplatform/releases/download/v${JAMFPLATFORM_VERSION}" \
  jamfplatform "$JAMFPLATFORM_VERSION" "$JAMFPLATFORM_SHA256_ARM64" "$JAMFPLATFORM_SHA256_AMD64"

echo "== jamfprotect provider $JAMFPROTECT_VERSION =="
provider "$HERE/providers/registry.opentofu.org/jamf-concepts/jamfprotect" \
  "https://github.com/Jamf-Concepts/terraform-provider-jamfprotect/releases/download/v${JAMFPROTECT_VERSION}" \
  jamfprotect "$JAMFPROTECT_VERSION" "$JAMFPROTECT_SHA256_ARM64" "$JAMFPROTECT_SHA256_AMD64"

echo "== jamfpro provider $JAMFPRO_VERSION (Deployment Theory, MPL-2.0) =="
provider "$HERE/providers/registry.opentofu.org/deploymenttheory/jamfpro" \
  "https://github.com/deploymenttheory/terraform-provider-jamfpro/releases/download/v${JAMFPRO_VERSION}" \
  jamfpro "$JAMFPRO_VERSION" "$JAMFPRO_SHA256_ARM64" "$JAMFPRO_SHA256_AMD64"

echo "== jamformer $JAMFORMER_VERSION =="
mkdir -p "$HERE/jamformer"
cd "$HERE/jamformer"
BASE="https://github.com/Jamf-Concepts/jamformer/releases/download/v${JAMFORMER_VERSION}"
fetch "$BASE/jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz" "jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz"
verify "jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz" "$JAMFORMER_SHA256"
tar -xzf "jamformer-${JAMFORMER_VERSION}-darwin-universal.tar.gz" jamformer
curl -fsSL -o LICENSE "https://raw.githubusercontent.com/Jamf-Concepts/jamformer/v${JAMFORMER_VERSION}/LICENSE"
verify LICENSE "$JAMFORMER_LICENSE_SHA256"

echo "== terraform-backend-git $BACKEND_GIT_VERSION (plumber-cd, Apache-2.0) =="
mkdir -p "$HERE/terraform-backend-git"
cd "$HERE/terraform-backend-git"
BASE="https://github.com/plumber-cd/terraform-backend-git/releases/download/v${BACKEND_GIT_VERSION}"
curl -fsSL -o terraform-backend-git-darwin-arm64 "$BASE/terraform-backend-git-darwin-arm64"
verify terraform-backend-git-darwin-arm64 "$BACKEND_GIT_SHA256_ARM64"
mv -f terraform-backend-git-darwin-arm64 terraform-backend-git
chmod +x terraform-backend-git
curl -fsSL -o LICENSE "https://raw.githubusercontent.com/plumber-cd/terraform-backend-git/v${BACKEND_GIT_VERSION}/LICENSE"
verify LICENSE "$BACKEND_GIT_LICENSE_SHA256"

echo "All vendored binaries fetched and verified."
