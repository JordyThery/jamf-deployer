#!/bin/zsh
# Jamf Deployer's release check (JTKit ROADMAP step 11). Claude runs it
# unattended with nohup; the report lands in
# ~/Library/Application Support/JTKit Release Check/runs/.
#
#   Scripts/release-check.sh [--local-jtkit] [--tenants] [--stop-before-live]
#   Scripts/release-check.sh --local-jtkit --fault break-build|fail-live-step|interrupt-live
#     (tests the check itself; never part of a release check)
#
#   JD_LIVE_FULL=1 Scripts/release-check.sh --only <LiveFullUITests test>
#     (the full live UI suite, one test at a time; only when Jordy asks)
#
# Tenants are roles on the local allow-list (never named here): jamf-test-a
# over the Jamf Pro API (and its Jamf Platform API connection, for the full
# suite's Platform-to-Platform steps), jamf-test-b over the Jamf Platform
# API, and jamfpro-production, read only: a building block captured from it
# and previewed on jamf-test-b, never deployed. Production takes part when
# the allow-list's productionReads or --include-production lets it.
#
# Live steps, in order: the engine checks per tenant (unit tests), then the
# live UI tests in Jamf DeployerUITests/LiveUITests.swift: Connect a Tenant
# and Remove Tenant; deploy, Check for Changes, a change made in Jamf
# restored and another kept, Remove from Tenant; capture from production
# and preview on jamf-test-b. With JD_LIVE_FULL=1 the full suite
# (LiveFullUITests.swift) follows; it runs for an hour or more.
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
# One selection per step, so the check stops at the first that fails
LIVE_TESTS=(
    "Jamf DeployerTests/LiveDeployTests/tenantA()"
    "Jamf DeployerTests/LiveDeployTests/tenantB()"
    "Jamf DeployerUITests/LiveUITests/testConnect"
    "Jamf DeployerUITests/LiveUITests/testDeployDriftKeepRestore"
    "Jamf DeployerUITests/LiveUITests/testCaptureFromProductionPreviewOnTestB"
)
if [[ "${JD_LIVE_FULL:-}" == 1 ]]; then
    LIVE_TESTS+=(
        "Jamf DeployerUITests/LiveFullUITests/testCustomObjectsOnBothConnections"
        "Jamf DeployerUITests/LiveFullUITests/testCatalogBlocksOnBothConnections"
        "Jamf DeployerUITests/LiveFullUITests/testJamfProAPIFlows"
        "Jamf DeployerUITests/LiveFullUITests/testFunctionsAcrossTwoPlatformTenants"
        "Jamf DeployerUITests/LiveFullUITests/testRolloutInTwoRings"
        "Jamf DeployerUITests/LiveFullUITests/testFleetPresetConflictIsFlagged"
        "Jamf DeployerUITests/LiveFullUITests/testExportAsTerraformForReview"
    )
fi
CLEANUP_TEST="Jamf DeployerTests/LiveCleanupTests"
ROLES=(jamf-test-a jamf-test-b jamfpro-production)
# whatever the allow-list grants, production is only ever read
READ_ONLY_ROLES=(jamfpro-production)
# role:service:item, read from the Keychain service the allow-list names
CREDENTIALS=(
    "jamf-test-a:jamfPro:jamfpro-username"
    "jamf-test-a:jamfPro:jamfpro-password"
    "jamf-test-a:jamfPlatform:client-id"
    "jamf-test-a:jamfPlatform:client-secret"
    "jamf-test-b:jamfPlatform:client-id"
    "jamf-test-b:jamfPlatform:client-secret"
    "jamfpro-production:jamfPlatform:client-id"
    "jamfpro-production:jamfPlatform:client-secret"
)
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
