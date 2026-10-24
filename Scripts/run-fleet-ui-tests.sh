#!/bin/zsh
# Runs the fleet UI tests (FleetUITests): the demo catalog's Fleet preset,
# PreStages included, deployed to one tenant through the Jamf Platform API,
# checked for changes, a block conflict flagged, and everything removed
# again. Between steps it counts the fleet objects in Jamf; anything left
# afterwards is deleted.
#
#   Scripts/run-fleet-ui-tests.sh <keychain-service> <catalog-folder> <ADE instance name>
#
# The tenant needs an Automated Device Enrollment instance with that name.
# <catalog-folder> is a checkout of the demo catalog; its HEAD is tagged as a
# local release for the run. Credentials come from the login Keychain
# (base-url, client-id, client-secret, environment-id) and reach the test
# runner only as environment variables. FLEET_REGION sets the tenant's region
# (default US). Never point this at a production tenant.
set -e
cd "$(dirname "$0")/.."
SERVICE="$1"; CATALOG="$2"; ADE="$3"
PREFIX="UIF - "
HELPERS="$(dirname "$0")/catalog-test"
kc() { security find-generic-password -s "$SERVICE" -a "$1" -w }
WORK="$(mktemp -d /tmp/jamf-deployer-fleettest.XXXXXX)"
cleanup() {
    (( CLEANED )) && return 0
    CLEANED=1
    setopt local_options no_err_exit
    echo "Cleaning up"
    /usr/bin/python3 "$HELPERS/purge_prefix.py" "$SERVICE" "$PREFIX" delete
    rm -f ~/Documents/"Jamf Deployer Recovery — Fleet Test.txt"
    rm -rf "$WORK"
}
CLEANED=0
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

git clone -q "$CATALOG" "$WORK/work"
git -C "$WORK/work" tag -l | xargs git -C "$WORK/work" tag -d > /dev/null
git -C "$WORK/work" tag v9.0.0
git clone -q --bare "$WORK/work" "$WORK/catalog.git"
export TEST_RUNNER_UITEST_CATALOG_URL="file://$WORK/catalog.git"
export TEST_RUNNER_UITEST_CATALOG_TAG="v9.0.0"
export TEST_RUNNER_FLEET_ADE_NAME="$ADE"
export TEST_RUNNER_FLT_CLIENT_ID="$(kc client-id)"
export TEST_RUNNER_FLT_CLIENT_SECRET="$(kc client-secret)"
export TEST_RUNNER_FLT_ENVIRONMENT_ID="$(kc environment-id)"
export TEST_RUNNER_FLT_REGION="${FLEET_REGION:-US}"

defaults write be.jordythery.jamf-deployer NSNavLastRootDirectory -string "$HOME/Documents"
touch "Jamf DeployerUITests/"*.swift
xcodebuild build -project "Jamf Deployer.xcodeproj" -scheme "Jamf Deployer" -configuration Debug -destination "platform=macOS,arch=arm64" -quiet
xcodebuild build-for-testing -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination "platform=macOS" -quiet

run() {
    local log="$WORK/$1.log"
    for attempt in 1 2; do
        xcodebuild test-without-building -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination 'platform=macOS' \
            -only-testing:"Jamf DeployerUITests/FleetUITests/$1" > "$log" 2>&1
        if grep -qE "Test Case .*(passed|failed)" "$log"; then break; fi
        echo "  $1 produced no result (attempt $attempt): $(grep -m1 -E "Testing failed|error" "$log")"
        sleep 5
    done
    grep -E "error:|Test Case .*(passed|failed)" "$log" || true
}

set +e
echo "Fleet objects before the run:"; /usr/bin/python3 "$HELPERS/purge_prefix.py" "$SERVICE" "$PREFIX" count
for step in test1ConnectAndSetPrefix test2AddCatalog test3DeployFleetPreset; do run $step; done
echo "Fleet objects after deploying:"; /usr/bin/python3 "$HELPERS/purge_prefix.py" "$SERVICE" "$PREFIX" count
for step in test4NoChangesAfterDeploy test5ConflictIsFlagged test6RemoveEverything; do run $step; done
echo "Fleet objects after removing:"; /usr/bin/python3 "$HELPERS/purge_prefix.py" "$SERVICE" "$PREFIX" count
run test7RemoveTenantAndCatalog
set -e
