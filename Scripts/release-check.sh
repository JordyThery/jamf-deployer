#!/bin/zsh
# Jamf Deployer's release check (JTKit ROADMAP step 11). Claude runs it
# unattended with nohup; the report lands in
# ~/Library/Application Support/JTKit Release Check/runs/.
#
#   Scripts/release-check.sh [--local-jtkit] [--tenants] [--stop-before-live]
#   Scripts/release-check.sh --local-jtkit --fault break-build|fail-live-step|interrupt-live
#     (tests the check itself; never part of a release check)
#
# Tenants are roles on the local allow-list (never named here): jamf-test-a
# over the Jamf Pro API, jamf-test-b over the Jamf Platform API.
cd "$(dirname "$0")/.." || exit 1

APP_NAME="Jamf Deployer"
APP_CODE="JD"
PROJECT="Jamf Deployer.xcodeproj"
SCHEME="Jamf Deployer Release Check"
UNIT_TESTS="Jamf DeployerTests"
UI_TESTS="Jamf DeployerUITests"
SMOKE_CLASS="DemoSmokeUITests"
SMOKE_FILE="$PWD/Jamf DeployerUITests/DemoSmokeUITests.swift"
SIGNIN_TEST="Jamf DeployerTests/LiveSignInTests"
# One selection per tenant, so the check stops at the first that fails
LIVE_TESTS=("Jamf DeployerTests/LiveDeployTests/tenantA()" "Jamf DeployerTests/LiveDeployTests/tenantB()")
CLEANUP_TEST="Jamf DeployerTests/LiveCleanupTests"
ROLES=(jamf-test-a jamf-test-b)
# role:service:item, read from the Keychain service the allow-list names
CREDENTIALS=(
    "jamf-test-a:jamfPro:jamfpro-username"
    "jamf-test-a:jamfPro:jamfpro-password"
    "jamf-test-b:jamfPlatform:client-id"
    "jamf-test-b:jamfPlatform:client-secret"
)
# Older UI-test objects, swept once on the first live run
LEGACY_PREFIXES="UIT - |UIC - |UIF - |UIT EX - |UIT RN - "
STORE="$HOME/Library/Application Support/Jamf Deployer/store"
FINGERPRINT_PATHS=("$STORE/tenants" "$STORE/.git/HEAD" "$STORE/.git/refs")
KEYCHAIN_PREFIXES=("be.jordythery.jamf-deployer.")

# The template comes from the JTKit under test: the local checkout with
# --local-jtkit, otherwise the published version this project resolves.
if [[ " $* " == *" --local-jtkit "* ]]; then
    LIB="${JTKIT_LOCAL:-$HOME/Developer/JTKit}/Scripts/release-check-lib.sh"
else
    PACKAGES="$HOME/Library/Developer/Xcode/DerivedData/JTKitReleaseCheck-$APP_CODE/SourcePackages"
    xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
        -clonedSourcePackagesDirPath "$PACKAGES" > /dev/null || exit 1
    LIB="$PACKAGES/checkouts/JTKit/Scripts/release-check-lib.sh"
fi
[[ -f "$LIB" ]] || { print -u2 "No release-check template at $LIB (JTKit 0.12.0 or later)"; exit 1 }
source "$LIB"
release_check_main "$@"
