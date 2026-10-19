#!/bin/zsh
# Runs the catalog UI tests (CatalogUITests): every demo catalog block plus
# the App Catalog, deployed to one tenant through the Jamf Platform API or
# the Jamf Pro API, verified object by object in Jamf, drifted on every
# object type, restored and removed; plus six existing objects of different
# types adopted, drifted and restored. Afterwards the instance's tenant-wide
# settings are restored to what they were before the run.
#
#   Scripts/run-catalog-ui-tests.sh platform|jamfPro <keychain-service> <catalog-folder>
#
# <catalog-folder> is a checkout of the demo catalog; its HEAD is tagged as
# a local release for the run. Credentials come from the login Keychain:
# jamfpro-fqdn, jamfpro-username and jamfpro-password always (the checks
# between steps use the Jamf Pro API), plus base-url, client-id,
# client-secret and environment-id for Platform runs. They reach the test
# runner only as environment variables. Never point this at a production
# instance.
set -e
cd "$(dirname "$0")/.."
CONNECTION="$1"; SERVICE="$2"; CATALOG="$3"
kc() {
    local value
    value="$(security find-generic-password -s "$SERVICE" -a "$1" -w)" || { echo "Missing Keychain item $1 for $SERVICE" >&2; exit 1 }
    print -r -- "$value"
}
for item in jamfpro-fqdn jamfpro-username jamfpro-password; do kc $item > /dev/null; done
if [[ "$CONNECTION" == platform ]]; then
    for item in base-url client-id client-secret environment-id; do kc $item > /dev/null; done
fi
WORK="$(mktemp -d /tmp/jamf-deployer-catalogtest.XXXXXX)"
HELPERS="$(dirname "$0")/catalog-test"
PREFIX="UIC - "

git clone -q "$CATALOG" "$WORK/work"
git -C "$WORK/work" tag -l | xargs git -C "$WORK/work" tag -d > /dev/null
git -C "$WORK/work" tag v9.0.0
git clone -q --bare "$WORK/work" "$WORK/catalog.git"
export TEST_RUNNER_UITEST_CATALOG_URL="file://$WORK/catalog.git"
export TEST_RUNNER_UITEST_CATALOG_TAG="v9.0.0"
export TEST_RUNNER_CATALOG_CONNECTION="$CONNECTION"
if [[ "$CONNECTION" == jamfPro ]]; then
    export TEST_RUNNER_CATALOG_CREDENTIALS=CAT
    export TEST_RUNNER_CAT_URL="https://$(kc jamfpro-fqdn)"
    export TEST_RUNNER_CAT_USERNAME="$(kc jamfpro-username)"
    export TEST_RUNNER_CAT_PASSWORD="$(kc jamfpro-password)"
else
    export TEST_RUNNER_CATALOG_CREDENTIALS=CAT
    export TEST_RUNNER_CAT_CLIENT_ID="$(kc client-id)"
    export TEST_RUNNER_CAT_CLIENT_SECRET="$(kc client-secret)"
    export TEST_RUNNER_CAT_ENVIRONMENT_ID="$(kc environment-id)"
fi

/usr/bin/python3 "$HELPERS/settings.py" "$SERVICE" snapshot "$WORK/settings.json"
# The snapshot is only discarded once it has been restored.
trap 'if /usr/bin/python3 "$HELPERS/settings.py" "$SERVICE" restore "$WORK/settings.json"; then rm -rf "$WORK"; else echo "Settings snapshot kept in $WORK/settings.json"; fi' EXIT

xcodebuild build -project "Jamf Deployer.xcodeproj" -scheme "Jamf Deployer" -configuration Debug -destination "platform=macOS,arch=arm64" -quiet
defaults write be.jordythery.jamf-deployer NSNavLastRootDirectory -string "$HOME/Documents"
touch "Jamf DeployerUITests/"*.swift
xcodebuild build-for-testing -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination "platform=macOS" -quiet

run() {
    local log="$WORK/$1.log"
    for attempt in 1 2; do
        xcodebuild test-without-building -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination 'platform=macOS' \
            -only-testing:"Jamf DeployerUITests/CatalogUITests/$1" > "$log" 2>&1
        if grep -qE "Test Case .*(passed|failed)" "$log"; then break; fi
        echo "  $1 produced no result (attempt $attempt): $(grep -m1 -E "Testing failed|error" "$log")"
        sleep 5
    done
    grep -E "error:|Test Case .*(passed|failed)" "$log" || true
}
verify() {
    /usr/bin/python3 "$HELPERS/verify_objects.py" "$SERVICE" "$PREFIX" "$1" | grep -E "FAIL|failure"
    if [[ "$CONNECTION" == platform ]]; then
        /usr/bin/python3 "$HELPERS/verify_platform.py" "$SERVICE" "$PREFIX" "$1" | grep -E "FAIL|failure"
    fi
}
drift_count() {
    /usr/bin/python3 -c "
import json, glob
for path in glob.glob('$HOME/Library/Application Support/Jamf Deployer/store/tenants/*/tenant.json'):
    tenant = json.load(open(path))
    if tenant['name'] == 'Catalog Test':
        objects = [o for o in (tenant.get('driftReport') or {}).get('objects', []) if not o['isComputedOnly']]
        print('  changed objects reported:', len(objects))
        for o in objects: print('   ', o['address'], [f['path'] for f in o['fields']])"
}

set +e
for step in test01Connect test02AddCatalog test03ComposeBaseline test04DeployEverything; do run $step; done
echo "Verifying every object in Jamf"; verify present
run test05NoChangesAfterDeploy
echo "Changing one field on every object type"; /usr/bin/python3 "$HELPERS/drift_all.py" "$SERVICE" "$PREFIX" | grep -v "  changed"
run test06DetectsEveryChange; drift_count
run test07RestoreBaseline
echo "Verifying the restore"; verify present
echo "Creating six objects to adopt"; /usr/bin/python3 "$HELPERS/adopt_objects.py" "$SERVICE" "$PREFIX" create
run test07bAdoptObjectsOfEveryKind
/usr/bin/python3 "$HELPERS/adopt_objects.py" "$SERVICE" "$PREFIX" change
run test07cRestoreAdoptedObjects
run test08RemoveEverything
echo "Verifying the removal"; verify absent
run test09RemoveTenantAndCatalog
set -e
echo "Deleting the adopted objects"; /usr/bin/python3 "$HELPERS/adopt_objects.py" "$SERVICE" "$PREFIX" delete
rm -f ~/Documents/"Jamf Deployer Recovery — Catalog Test.txt"
