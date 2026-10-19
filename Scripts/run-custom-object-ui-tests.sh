#!/bin/zsh
# Runs the custom object UI tests (CustomObjectUITests) against one test
# instance through both connections: a script and a computer extension
# attribute each, staged from the form, deployed, checked in Jamf, changed
# there, detected and restored. Everything named "UIT - CO …" is removed
# afterwards, with the recovery sheets.
#
# Credentials come from the login Keychain (base-url, client-id,
# client-secret, environment-id and jamfpro-* under CUSTOM_OBJECT_SERVICE,
# default JamfDeployer-Spike) and reach the test runner only as environment
# variables. Never point this at a production tenant.
set -e
cd "$(dirname "$0")/.."
A="${CUSTOM_OBJECT_SERVICE:-JamfDeployer-Spike}"
kc() { security find-generic-password -s "$1" -a "$2" -w }
WORK="$(mktemp -d /tmp/jamf-deployer-cotest.XXXXXX)"
HELPERS="$(dirname "$0")/catalog-test"

export TEST_RUNNER_SBX_CLIENT_ID="$(kc $A client-id)"
export TEST_RUNNER_SBX_CLIENT_SECRET="$(kc $A client-secret)"
export TEST_RUNNER_SBX_ENVIRONMENT_ID="$(kc $A environment-id)"
export TEST_RUNNER_JPSBX_URL="https://$(kc $A jamfpro-fqdn)"
export TEST_RUNNER_JPSBX_USERNAME="$(kc $A jamfpro-username)"
export TEST_RUNNER_JPSBX_PASSWORD="$(kc $A jamfpro-password)"

# Python statements against the instance's Jamf Pro API, with the test
# objects at hand: scripts and attributes named "UIT - CO …".
jp() {
    /usr/bin/python3 "$HELPERS/jpcall.py" "$A" "
scripts = [s for s in call('GET', '/api/v1/scripts?page-size=2000')['results'] if s['name'].startswith('UIT - CO')]
attributes = [a for a in call('GET', '/api/v1/computer-extension-attributes?page-size=2000')['results'] if a['name'].startswith('UIT - CO')]
$1"
}

xcodebuild build -project "Jamf Deployer.xcodeproj" -scheme "Jamf Deployer" -configuration Debug -destination "platform=macOS,arch=arm64" -quiet
defaults write be.jordythery.jamf-deployer NSNavLastRootDirectory -string "$HOME/Documents"
touch "Jamf DeployerUITests/"*.swift
xcodebuild build-for-testing -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination "platform=macOS" -quiet

run() {
    local log="$WORK/$1.log"
    for attempt in 1 2; do
        xcodebuild test-without-building -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination 'platform=macOS' \
            -only-testing:"Jamf DeployerUITests/CustomObjectUITests/$1" > "$log" 2>&1
        if grep -qE "Test Case .*(passed|failed)" "$log"; then break; fi
        echo "  $1 produced no result (attempt $attempt)"
        sleep 5
    done
    grep -E "error:|Test Case .*(passed|failed)" "$log" || true
}

set +e
for step in test01Connect test02DeployThroughThePlatformAPI test03DeployThroughTheJamfProAPI test04NoChangesAfterDeploy; do
    run $step
done
echo "In Jamf:"
jp "
for s in scripts:
    print('  script', s['name'], '| priority', s['priority'], '| contents', repr(s['scriptContents']))
for a in attributes:
    print('  attribute', a['name'], '|', a['dataType'], a['inputType'], a['inventoryDisplayType'], '| enabled', a['enabled'])
print('  found', len(scripts), 'scripts and', len(attributes), 'attributes (expected 2 and 2)')"
jp "
for s in scripts:
    s['scriptContents'] = 'echo changed'
    call('PUT', '/api/v1/scripts/' + s['id'], s)
for a in attributes:
    a['inventoryDisplayType'] = 'HARDWARE'
    call('PUT', '/api/v1/computer-extension-attributes/' + a['id'], a)
print('  changed every object in Jamf')"
run test05DetectAndRestore
jp "
print('  restored in Jamf:', all(s['scriptContents'] == 'echo UIT' for s in scripts) and all(a['inventoryDisplayType'] == 'GENERAL' for a in attributes))"
run test06RemoveTenants
set -e

echo "Cleaning up"
jp "
for s in scripts:
    call('DELETE', '/api/v1/scripts/' + s['id']); print('  deleted', s['name'])
for a in attributes:
    call('DELETE', '/api/v1/computer-extension-attributes/' + a['id']); print('  deleted', a['name'])"
rm -f ~/Documents/"Jamf Deployer Recovery — CO Platform.txt" ~/Documents/"Jamf Deployer Recovery — CO Jamf Pro.txt"
rm -rf "$WORK"
