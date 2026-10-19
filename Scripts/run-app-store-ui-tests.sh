#!/bin/zsh
# Runs the App Store UI tests (AppStoreUITests) against a test tenant on the
# Platform API: a licensed Mac app (APP_NAME, default Microsoft Word, which
# must not be in Jamf yet) is deployed to an empty static group the script
# creates, checked in Jamf, changed there, detected, restored and removed.
# The group, the app and the recovery sheet are removed afterwards.
#
# Credentials come from the login Keychain (base-url, client-id,
# client-secret, environment-id and jamfpro-* under APP_STORE_SERVICE,
# default JamfDeployer-Spike) and reach the test runner only as environment
# variables. Never point this at a production tenant.
set -e
cd "$(dirname "$0")/.."
A="${APP_STORE_SERVICE:-JamfDeployer-Spike}"
APP="${APP_NAME:-Microsoft Word}"
kc() { security find-generic-password -s "$1" -a "$2" -w }
WORK="$(mktemp -d /tmp/jamf-deployer-astest.XXXXXX)"
HELPERS="$(dirname "$0")/catalog-test"

export TEST_RUNNER_SBX_CLIENT_ID="$(kc $A client-id)"
export TEST_RUNNER_SBX_CLIENT_SECRET="$(kc $A client-secret)"
export TEST_RUNNER_SBX_ENVIRONMENT_ID="$(kc $A environment-id)"
export TEST_RUNNER_APP_NAME="$APP"

# Python statements against the Jamf Pro API, with the classic API's Mac
# apps at hand (classic(method, path, xml) returns parsed JSON or None).
jp() {
    /usr/bin/python3 "$HELPERS/jpcall.py" "$A" "
import json, urllib.request
def classic(method, path, xml=None):
    request = urllib.request.Request(base + '/JSSResource' + path, method=method, data=xml.encode() if xml else None,
        headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/json', 'Content-Type': 'application/xml'})
    with urllib.request.urlopen(request) as response:
        data = response.read()
        return json.loads(data) if data and method == 'GET' else None
apps = [a for a in classic('GET', '/macapplications')['mac_applications'] if a['name'] == 'UIT - $APP']
groups = [g for g in call('GET', '/api/v1/computer-groups') if g['name'] == 'UIT - AS Empty Macs']
$1"
}

jp "
assert not [a for a in classic('GET', '/macapplications')['mac_applications'] if a['name'] in ('$APP', 'UIT - $APP')], '$APP is already in Jamf'
if not groups:
    print('  created the empty group', call('POST', '/api/v2/computer-groups/static-groups', {'name': 'UIT - AS Empty Macs', 'assignments': []})['id'])"

xcodebuild build -project "Jamf Deployer.xcodeproj" -scheme "Jamf Deployer" -configuration Debug -destination "platform=macOS,arch=arm64" -quiet
defaults write be.jordythery.jamf-deployer NSNavLastRootDirectory -string "$HOME/Documents"
touch "Jamf DeployerUITests/"*.swift
xcodebuild build-for-testing -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination "platform=macOS" -quiet

run() {
    local log="$WORK/$1.log"
    for attempt in 1 2; do
        xcodebuild test-without-building -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination 'platform=macOS' \
            -only-testing:"Jamf DeployerUITests/AppStoreUITests/$1" > "$log" 2>&1
        if grep -qE "Test Case .*(passed|failed)" "$log"; then break; fi
        echo "  $1 produced no result (attempt $attempt)"
        sleep 5
    done
    grep -E "error:|Test Case .*(passed|failed)" "$log" || true
}

set +e
for step in test01Connect test02PickAndDeploy test03NoChangesAfterDeploy; do run $step; done
echo "In Jamf:"
jp "
for a in apps:
    app = classic('GET', '/macapplications/id/' + str(a['id']))['mac_application']
    print('  app', app['general']['name'], '| bundle', app['general']['bundle_id'], '|', app['general']['deployment_type'])
    print('  scope groups', [g['name'] for g in app['scope']['computer_groups']], '| all computers', app['scope']['all_computers'])
    print('  device-based licenses', app['vpp']['assign_vpp_device_based_licenses'], '| location', app['vpp']['vpp_admin_account_id'])
    classic('PUT', '/macapplications/id/' + str(a['id']),
        '<mac_application><general><deployment_type>Install Automatically/Prompt Users to Install</deployment_type></general></mac_application>')
    print('  changed the deployment type in Jamf')
print('  found', len(apps), 'app (expected 1)')"
run test04DetectAndRestore
jp "
for a in apps:
    print('  restored in Jamf:', classic('GET', '/macapplications/id/' + str(a['id']))['mac_application']['general']['deployment_type'])"
run test05RemoveBlockAndTenant
set -e

echo "Cleaning up"
jp "
print('  app left in Jamf after removal:', len(apps))
for a in apps:
    classic('DELETE', '/macapplications/id/' + str(a['id'])); print('  deleted', a['name'])
for g in groups:
    call('DELETE', '/api/v2/computer-groups/static-groups/' + str(g['id'])); print('  deleted', g['name'])"
rm -f ~/Documents/"Jamf Deployer Recovery — AS Platform.txt"
rm -rf "$WORK"
