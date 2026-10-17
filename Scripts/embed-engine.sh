#!/bin/sh
# Xcode run-script build phase: copies the deployment engine, provider
# mirror, jamformer and the built-in catalog into the app bundle, then signs
# the copied executables with the app's identity (required for notarization).
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

rm -rf "${RESOURCES}/Vendor/providers" "${RESOURCES}/Catalog"
cp -R "${SRC}/Vendor/providers" "${RESOURCES}/Vendor/providers"
cp -R "${SRC}/Catalog" "${RESOURCES}/Catalog"

# Re-sign the copied tools with the app's identity and the hardened runtime
# so the notary service accepts them. Skipped for ad-hoc debug signing.
if [ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" != "" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY_NAME}" != "-" ]; then
  for tool in "${RESOURCES}/Vendor/opentofu/bin/tofu" "${RESOURCES}/Vendor/jamformer/jamformer"; do
    codesign --force --options runtime --timestamp \
      --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${tool}"
  done
fi
