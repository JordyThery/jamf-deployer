#!/bin/zsh
# Runs the function UI tests (FunctionUITests) against two test tenants:
# connect, catalog sources, deploys, drift, removals, adoption, App Store
# picker, hand-over, Day 0, export, clone, snapshot, settings. Between steps
# it changes objects in Jamf to create drift, and afterwards removes
# everything the run created.
#
# Credentials come from the login Keychain (generic passwords with the
# accounts base-url, client-id, client-secret and environment-id) and reach
# the test runner only as environment variables. Override the Keychain
# services with ROLLOUT_SERVICE_A / ROLLOUT_SERVICE_B. Never point this at
# a production tenant.
set -e
cd "$(dirname "$0")/.."
A="${ROLLOUT_SERVICE_A:-JamfDeployer-Spike}"
B="${ROLLOUT_SERVICE_B:-JamfDeployer-Demo}"
kc() { security find-generic-password -s "$1" -a "$2" -w }
WORK="$(mktemp -d /tmp/jamf-deployer-uitest.XXXXXX)"
# Removes everything the run created; runs once, however the script ends.
cleanup() {
    (( CLEANED )) && return 0
    CLEANED=1
    setopt local_options no_err_exit
    echo "Cleaning up"
    if (( $+functions[api] )); then
        for service in "$A" "$B"; do
            api "$service" "
for c in test:
    call('DELETE', '/pro/v1/categories/' + c['id'])
    print('  deleted', c['name'], 'on $service')"
        done
    fi
    rm -f ~/Documents/"Jamf Deployer Recovery — UI Sandbox.txt" ~/Documents/"Jamf Deployer Recovery — UI Demo.txt"
    rm -f ~/Documents/AsBuilt-"UI Sandbox"-*.md(N) ~/Documents/Snapshot-"UI Demo"-*.zip(N)
    rm -rf ~/Library/Application\ Support/Jamf\ Deployer/cloned-blocks/blocks/clone-uisandbox-*(N) ~/Library/Application\ Support/Jamf\ Deployer/cloned-blocks/blocks/uit-captured-categories
    rm -rf "$WORK"
}
CLEANED=0
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# A local catalog with exactly two release tags: v1.0.0 is the demo catalog
# (CATALOG_SOURCE, default the public one, at its default branch) and v1.0.1
# changes the categories block, so a catalog-release rollout has something
# to deploy. Public tags are dropped: they would be "the latest release".
git clone -q "${CATALOG_SOURCE:-https://github.com/JordyThery/jamf-deployer-catalog}" "$WORK/work"
git -C "$WORK/work" tag -l | xargs git -C "$WORK/work" tag -d > /dev/null
git -C "$WORK/work" tag v1.0.0
git -C "$WORK/work" checkout -q -b uitest
sed -i '' 's/"version": "1.0.0"/"version": "1.0.1"/' "$WORK/work/blocks/categories/block.json"
sed -i '' 's/priority = 9/priority = 8/' "$WORK/work/blocks/categories/main.tf"
git -C "$WORK/work" -c user.name="UI test" -c user.email="uitest@localhost" commit -qam "UI test release"
git -C "$WORK/work" tag v1.0.1
git clone -q --bare "$WORK/work" "$WORK/catalog.git"

export TEST_RUNNER_SBX_CLIENT_ID="$(kc $A client-id)"
export TEST_RUNNER_SBX_CLIENT_SECRET="$(kc $A client-secret)"
export TEST_RUNNER_SBX_ENVIRONMENT_ID="$(kc $A environment-id)"
export TEST_RUNNER_DEMO_CLIENT_ID="$(kc $B client-id)"
export TEST_RUNNER_DEMO_CLIENT_SECRET="$(kc $B client-secret)"
export TEST_RUNNER_DEMO_ENVIRONMENT_ID="$(kc $B environment-id)"
export TEST_RUNNER_UITEST_CATALOG_URL="file://$WORK/catalog.git"

# Calls the Jamf API for one Keychain service: api <service> <python statements>
api() {
    BASE="$(kc $1 base-url)" CID="$(kc $1 client-id)" SEC="$(kc $1 client-secret)" ENVID="$(kc $1 environment-id)" \
    /usr/bin/python3 -c "
import json, os, urllib.parse, urllib.request
base = os.environ['BASE'].rstrip('/')
body = urllib.parse.urlencode({'grant_type': 'client_credentials', 'client_id': os.environ['CID'], 'client_secret': os.environ['SEC']}).encode()
token = json.load(urllib.request.urlopen(urllib.request.Request(base + '/auth/token', data=body)))['access_token']
def call(method, path, payload=None):
    request = urllib.request.Request(base + path, method=method, data=json.dumps(payload).encode() if payload else None, headers={
        'Authorization': 'Bearer ' + token, 'X-Environment-Id': os.environ['ENVID'], 'Accept': 'application/json', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request) as response:
        data = response.read()
        return json.loads(data) if data else None
categories = call('GET', '/pro/v1/categories?page-size=2000')['results']
test = [c for c in categories if c['name'].startswith('UIT - ')]
$2"
}

# Save panels open in ~/Documents, where the cleanup below looks.
defaults write be.jordythery.jamf-deployer NSNavLastRootDirectory -string "$HOME/Documents"
# Touching the test sources forces a fresh test bundle.
touch "Jamf DeployerUITests/"*.swift
xcodebuild build -project "Jamf Deployer.xcodeproj" -scheme "Jamf Deployer" -configuration Debug -destination "platform=macOS,arch=arm64" -quiet
xcodebuild build-for-testing -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination "platform=macOS" -quiet

# Runs one step; a step that produced no result (for example because the
# previous app instance was still quitting) is retried once.
run() {
    local log="$WORK/$1.log"
    for attempt in 1 2; do
        xcodebuild test-without-building -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination 'platform=macOS' \
            -only-testing:"Jamf DeployerUITests/FunctionUITests/$1" > "$log" 2>&1
        if grep -qE "Test Case .*(passed|failed)" "$log"; then break; fi
        echo "  $1 produced no result (attempt $attempt): $(grep -m1 -E "Testing failed|error" "$log")"
        sleep 5
    done
    grep -E "error:|Test Case .*(passed|failed)" "$log" || true
}
drift() {
    api "$A" "
security = next(c for c in test if c['name'] == 'UIT - Security')
call('PUT', '/pro/v1/categories/' + security['id'], {'name': security['name'], 'priority': $1})"
}

set +e
for step in test01ConnectAndSetPrefix test02AddGitCatalog test03SelectBlockAndDeploy; do run $step; done
drift 3; run test04DriftRestoreBaseline
drift 5; run test05DriftKeepChange
for step in test06DeployDemoBaseline test07RolloutCatalogRelease test08HistoryRollBack test09RemoveBlockFromTenant \
    test10StopManagingBlock test10bDownloadTerraform test11AdoptExistingObjects test11cAppStorePicker test12HandOver \
    test13DaySetupTab test14ExportAsBuiltDocumentation test15CloneToTenant test16RemoveClone test17SaveSnapshot test17bCaptureBlockAndDeployElsewhere \
    test18BlockDetailsAndSettings test19RemoveCatalogSource test20RemoveTenants; do
    run $step
done
set -e
