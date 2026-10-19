#!/bin/zsh
# Runs the Jamf Pro API UI tests (JamfProUITests) against two test Jamf Pro
# instances with user accounts: connect, custom objects, drift, adoption,
# export, rollout, Day 0 and hand-over. Between steps it changes objects in
# Jamf through the Jamf Pro API, and afterwards removes everything the run
# created (categories named "UIT - JP …", recovery sheets, snapshots).
#
# Credentials come from the login Keychain (generic passwords with the
# accounts jamfpro-fqdn, jamfpro-username and jamfpro-password) and reach
# the test runner only as environment variables. Override the Keychain
# services with JAMFPRO_SERVICE_A / JAMFPRO_SERVICE_B. Never point this at
# a production instance.
set -e
cd "$(dirname "$0")/.."
A="${JAMFPRO_SERVICE_A:-JamfDeployer-Spike}"
B="${JAMFPRO_SERVICE_B:-JamfDeployer-Demo}"
kc() { security find-generic-password -s "$1" -a "$2" -w }
WORK="$(mktemp -d /tmp/jamf-deployer-jpuitest.XXXXXX)"

export TEST_RUNNER_JPSBX_URL="https://$(kc $A jamfpro-fqdn)"
export TEST_RUNNER_JPSBX_USERNAME="$(kc $A jamfpro-username)"
export TEST_RUNNER_JPSBX_PASSWORD="$(kc $A jamfpro-password)"
export TEST_RUNNER_JPDEMO_URL="https://$(kc $B jamfpro-fqdn)"
export TEST_RUNNER_JPDEMO_USERNAME="$(kc $B jamfpro-username)"
export TEST_RUNNER_JPDEMO_PASSWORD="$(kc $B jamfpro-password)"

# Calls the Jamf Pro API of one instance: jp <service> <python statements>
jp() {
    URL="https://$(kc $1 jamfpro-fqdn)" JPUSER="$(kc $1 jamfpro-username)" JPPASS="$(kc $1 jamfpro-password)" \
    /usr/bin/python3 -c "
import base64, json, os, urllib.request
base = os.environ['URL']
basic = base64.b64encode((os.environ['JPUSER'] + ':' + os.environ['JPPASS']).encode()).decode()
request = urllib.request.Request(base + '/api/v1/auth/token', method='POST', headers={'Authorization': 'Basic ' + basic})
token = json.load(urllib.request.urlopen(request))['token']
def call(method, path, payload=None):
    request = urllib.request.Request(base + path, method=method, data=json.dumps(payload).encode() if payload else None, headers={
        'Authorization': 'Bearer ' + token, 'Accept': 'application/json', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request) as response:
        data = response.read()
        return json.loads(data) if data else None
categories = call('GET', '/api/v1/categories?page-size=2000')['results']
test = [c for c in categories if c['name'].startswith('UIT - JP')]
def named(name):
    return next(c for c in test if c['name'] == name)
$2
call('POST', '/api/v1/auth/invalidate-token')"
}

# A temporary API role and client on instance A test API-client sign-in.
CREDS="$(jp "$A" "
role = call('POST', '/api/v1/api-roles', {'displayName': 'UIT - JP Role', 'privileges': ['Read Categories', 'Create Categories', 'Update Categories', 'Delete Categories', 'Read Scripts', 'Read Device Enrollment Program Instances', 'Read Volume Purchasing Locations']})
client = call('POST', '/api/v1/api-integrations', {'authorizationScopes': ['UIT - JP Role'], 'displayName': 'UIT - JP Client', 'enabled': True, 'accessTokenLifetimeSeconds': 1800})
secret = call('POST', '/api/v1/api-integrations/' + str(client['id']) + '/client-credentials')
print(role['id'], client['id'], secret['clientId'], secret['clientSecret'])")"
read ROLE_ID CLIENT_ID TEST_RUNNER_JPSBX_CLIENT_ID TEST_RUNNER_JPSBX_CLIENT_SECRET <<< "$CREDS"
export TEST_RUNNER_JPSBX_CLIENT_ID TEST_RUNNER_JPSBX_CLIENT_SECRET
# The temporary client can change categories, so it goes away however the
# script ends.
remove_client() {
    jp "$A" "
call('DELETE', '/api/v1/api-integrations/$CLIENT_ID')
call('DELETE', '/api/v1/api-roles/$ROLE_ID')
print('  deleted the temporary API client and role')"
}
trap remove_client EXIT

xcodebuild build -project "Jamf Deployer.xcodeproj" -scheme "Jamf Deployer" -configuration Debug -destination "platform=macOS,arch=arm64" -quiet
# Save panels open in ~/Documents, where the cleanup below looks.
defaults write be.jordythery.jamf-deployer NSNavLastRootDirectory -string "$HOME/Documents"
# Touching the test sources forces a fresh test bundle.
touch "Jamf DeployerUITests/"*.swift
xcodebuild build-for-testing -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination "platform=macOS" -quiet

# Runs one step; a step that produced no result is retried once.
run() {
    local log="$WORK/$1.log"
    for attempt in 1 2; do
        xcodebuild test-without-building -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination 'platform=macOS' \
            -only-testing:"Jamf DeployerUITests/JamfProUITests/$1" > "$log" 2>&1
        if grep -qE "Test Case .*(passed|failed)" "$log"; then break; fi
        echo "  $1 produced no result (attempt $attempt): $(grep -m1 -E "Testing failed|error" "$log")"
        sleep 5
    done
    grep -E "error:|Test Case .*(passed|failed)" "$log" || true
}

set +e
run test01ConnectWithJamfProAPI
run test02CustomObjectDeploys
jp "$A" "c = named('UIT - JP Category'); call('PUT', '/api/v1/categories/' + c['id'], {'name': c['name'], 'priority': 3})"
run test03DriftRestoreBaseline
jp "$B" "call('POST', '/api/v1/categories', {'name': 'UIT - JP Adopt', 'priority': 9})"
run test04AdoptExistingObject
jp "$B" "c = named('UIT - JP Adopt'); call('PUT', '/api/v1/categories/' + c['id'], {'name': c['name'], 'priority': 5})"
for step in test05DriftKeepChange test06ExportSnapshot test07Rollout test08DaySetupTab test09HandOver test10RemoveTenants \
    test11APIClientSignIn; do
    run $step
done
set -e

echo "Cleaning up"
for service in "$A" "$B"; do
    jp "$service" "
for c in test:
    call('DELETE', '/api/v1/categories/' + c['id'])
    print('  deleted', c['name'], 'on $service')"
done
rm -f ~/Documents/"Jamf Deployer Recovery — JP Sandbox.txt" ~/Documents/"Jamf Deployer Recovery — JP Demo.txt" \
    ~/Documents/"Jamf Deployer Recovery — JP Sandbox API Client.txt"
rm -f ~/Documents/Snapshot-"JP Sandbox"-*.zip(N)
rm -rf "$WORK"
