#!/bin/sh
# Xcode run-script build phase: copies the deployment engine, provider
# mirror, jamformer and the built-in catalog into the app bundle, then signs
# every copied executable with the app's identity — including the provider
# binaries inside the mirror's zip archives, which the notary service
# inspects and rejects when unsigned.
#
# Add as the LAST build phase of the "Jamf Deployer" target with
# "Based on dependency analysis" unchecked.
set -eu

SRC="${SRCROOT}"
RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

if [ ! -x "${SRC}/Vendor/opentofu/bin/tofu" ]; then
  echo "warning: Vendor binaries missing — run Vendor/fetch.sh first (debug builds fall back to the repo copies)."
  exit 0
fi

mkdir -p "${RESOURCES}/Vendor/opentofu/bin"
cp -f "${SRC}/Vendor/opentofu/bin/tofu" "${RESOURCES}/Vendor/opentofu/bin/tofu"
cp -f "${SRC}/Vendor/opentofu/bin/LICENSE" "${RESOURCES}/Vendor/opentofu/bin/LICENSE"

mkdir -p "${RESOURCES}/Vendor/jamformer"
cp -f "${SRC}/Vendor/jamformer/jamformer" "${RESOURCES}/Vendor/jamformer/jamformer"

# Provider mirror: the app is arm64-only, so only darwin_arm64 archives are
# bundled. SHA256SUMS files describe the original archives and are dropped —
# the mirror's hashes are re-derived by the engine at init.
rm -rf "${RESOURCES}/Vendor/providers" "${RESOURCES}/Catalog"
(cd "${SRC}/Vendor" && find providers -name "*_darwin_arm64.zip" -print0 | \
  xargs -0 -I{} sh -c 'mkdir -p "$0/$(dirname "$1")" && cp -f "$1" "$0/$1"' "${RESOURCES}/Vendor" {})
cp -R "${SRC}/Catalog" "${RESOURCES}/Catalog"

# Debug builds sign ad hoc and skip the notarization-grade signing below.
if [ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" = "" ] || [ "${EXPANDED_CODE_SIGN_IDENTITY_NAME}" = "-" ]; then
  exit 0
fi

# Prefer the team's Developer ID Application identity. Archives build with
# the development identity and Xcode re-signs with Developer ID only at
# export — which cannot reach inside the mirror's zip archives, so their
# contents must carry the distribution signature already.
IDENTITY="$(security find-identity -v -p codesigning | \
  grep "Developer ID Application" | grep "${DEVELOPMENT_TEAM:-}" | \
  head -1 | awk '{print $2}')"
if [ -z "${IDENTITY}" ]; then
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY}"
fi

sign() {
  codesign --force --options runtime --timestamp \
    --sign "${IDENTITY}" "$1"
}

sign "${RESOURCES}/Vendor/opentofu/bin/tofu"
sign "${RESOURCES}/Vendor/jamformer/jamformer"

# Sign the provider binaries inside each mirror archive: unzip, sign every
# Mach-O, re-zip in place.
find "${RESOURCES}/Vendor/providers" -name "*.zip" | while read -r archive; do
  workdir="$(mktemp -d)"
  unzip -qq "${archive}" -d "${workdir}"
  find "${workdir}" -type f | while read -r entry; do
    if file -b "${entry}" | grep -q "Mach-O"; then
      sign "${entry}"
    fi
  done
  rm -f "${archive}"
  (cd "${workdir}" && zip -qq -r -X "${archive}" .)
  rm -rf "${workdir}"
done
