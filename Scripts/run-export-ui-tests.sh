#!/bin/zsh
# Runs the Export as Terraform UI tests (ExportUITests) against a test tenant
# and a private test repository: deploy demo blocks and a custom object,
# export for review, then move the tenant to the repository. Between steps it
# checks the repository, creates the tenant's GitHub Environment with the
# exported create-environments.sh, runs the repository's own change check (it
# must find no changes) and destroys the objects with the repository's
# Destroy workflow. Everything is cleaned up afterwards.
#
#   Scripts/run-export-ui-tests.sh <owner/repository>
#
# The repository must be a private test repository you can push to: its
# branches are replaced for the run (main is parked and restored).
# Credentials come from the login Keychain (base-url, client-id,
# client-secret, environment-id and jamfpro-* under EXPORT_SERVICE, default
# JamfDeployer-Spike) and reach the test runner and GitHub only as
# environment variables and standard input. Never point this at a
# production tenant. EXPORT_CONNECTION=jamfpro connects the tenant through
# the Jamf Pro API with a user account (jamfpro-username, jamfpro-password).
# EXPORT_EXTRAS=1 (Platform only) also deploys the Jamf Protect baseline
# (protect-url, protect-client-id, protect-client-secret) and a test block
# with a secret setting, so the moved repository needs both. EXPORT_REGION
# sets the tenant's region (default US).
set -e
[[ -n "$1" ]] || { echo "usage: $0 <owner/repository>" >&2; exit 64 }
cd "$(dirname "$0")/.."
REPO="$1"
A="${EXPORT_SERVICE:-JamfDeployer-Spike}"
kc() { security find-generic-password -s "$1" -a "$2" -w }
WORK="$(mktemp -d /tmp/jamf-deployer-exporttest.XXXXXX)"
HELPERS="$(dirname "$0")/catalog-test"
REVIEW="$HOME/Documents/UIT Export Review"
MOVE="$HOME/Documents/UIT Export Move"
TENANT=export-sandbox

jp() { /usr/bin/python3 "$HELPERS/jpcall.py" "$A" "
cats = [x for x in call('GET', '/api/v1/categories?page-size=2000')['results'] if x['name'].startswith('UIT EX - ')]
eas = [x for x in call('GET', '/api/v1/computer-extension-attributes?page-size=2000')['results'] if x['name'].startswith('UIT EX - ')]
$1"; }
# A branch's commit, or nothing (gh prints error bodies to standard output).
head_of() { local sha; sha=$(gh api "repos/$REPO/git/refs/heads/$1" --jq .object.sha 2> /dev/null) || return 0
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && echo "$sha"; return 0 }
wait_run() { # wait_run <workflow file>: waits for its latest run and prints the outcome
    sleep 15
    for _ in $(seq 1 60); do
        s=$(gh run list --repo "$REPO" --workflow "$1" --limit 1 --json status,conclusion --jq '.[0].status+" "+.[0].conclusion')
        [[ "$s" == completed* ]] && { echo "  $1: ${s#completed }"; return; }
        sleep 10
    done
    echo "  $1: timed out"
}

# Removes everything the run created; runs once, however the script ends.
cleanup() {
    (( CLEANED )) && return 0
    CLEANED=1
    setopt local_options no_err_exit
    echo "Cleaning up"
    pkill -x "Jamf Deployer" 2> /dev/null
    jp "
for c in cats:
    call('DELETE', '/api/v1/categories/' + c['id']); print('  deleted', c['name'])
for e in eas:
    call('DELETE', '/api/v1/computer-extension-attributes/' + e['id']); print('  deleted', e['name'])"
    if [[ "$EXTRAS" == 1 ]]; then
        /usr/bin/python3 "$HELPERS/protectcall.py" "$A" "
P = 'UIT EX - '
for plan in items('query(\$d:OrderDirection!,\$f:PlanOrderField!){listPlans(input:{order:{direction:\$d,field:\$f},pageSize:100}){items{id name}}}', 'created'):
    if plan['name'].startswith(P): gql('mutation(\$id:ID!){deletePlan(id:\$id){id}}', {'id': plan['id']}); print('  deleted', plan['name'])
for action in items('query(\$d:OrderDirection!,\$f:ActionConfigsOrderField!){listActionConfigs(input:{order:{direction:\$d,field:\$f},pageSize:100}){items{id name}}}', 'created'):
    if action['name'].startswith(P): gql('mutation(\$id:ID!){deleteActionConfigs(id:\$id){id}}', {'id': action['id']}); print('  deleted', action['name'])
for exceptions in items('query(\$d:OrderDirection!,\$f:ExceptionSetOrderField!){listExceptionSets(input:{order:{direction:\$d,field:\$f},pageSize:100}){items{uuid name}}}', 'created'):
    if exceptions['name'].startswith(P): gql('mutation(\$u:ID!){deleteExceptionSet(uuid:\$u){uuid}}', {'u': exceptions['uuid']}); print('  deleted', exceptions['name'])
for telemetry in items('query(\$d:OrderDirection!,\$f:TelemetryOrderField!){listTelemetriesV2(input:{order:{direction:\$d,field:\$f},pageSize:100}){items{id name}}}', 'created'):
    if telemetry['name'].startswith(P): gql('mutation(\$id:ID!){deleteTelemetryV2(id:\$id){id}}', {'id': telemetry['id']}); print('  deleted', telemetry['name'])
"
    fi
    gh api -X DELETE "repos/$REPO/environments/$TENANT" > /dev/null 2>&1
    gh api -X DELETE "repos/$REPO/environments/$TENANT-plan" > /dev/null 2>&1
    parked="$(head_of uitest-parking)"
    if [[ -n "$parked" ]]; then
        gh api -X PATCH "repos/$REPO" -f default_branch=uitest-parking > /dev/null 2>&1
        gh api -X DELETE "repos/$REPO/git/refs/heads/main" > /dev/null 2>&1
        gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/main -f sha="$parked" > /dev/null 2>&1
        if [[ "$(head_of main)" == "$parked" ]]; then
            gh api -X PATCH "repos/$REPO" -f default_branch=main > /dev/null 2>&1
            for branch in $(gh api "repos/$REPO/branches" --jq '.[].name' 2> /dev/null | grep -v '^main$'); do
                gh api -X DELETE "repos/$REPO/git/refs/heads/$branch" > /dev/null 2>&1
            done
        else
            echo "WARNING: main could not be restored; the original is on uitest-parking" >&2
        fi
    fi
    # Step logs are kept for diagnosis; they hold no credentials.
    mkdir -p /tmp/jamf-deployer-export-logs
    cp "$WORK"/*.log(N) /tmp/jamf-deployer-export-logs/ 2> /dev/null
    rm -rf "$REVIEW" "$MOVE" "$WORK"
    rm -f ~/Documents/"Jamf Deployer Recovery — Export Sandbox.txt"
    if [[ -n "$DETAILS_BEFORE" ]]; then
        defaults write be.jordythery.jamf-deployer showsTechnicalDetails -bool "$([[ "$DETAILS_BEFORE" == 1 ]] && echo true || echo false)"
    else
        defaults delete be.jordythery.jamf-deployer showsTechnicalDetails 2> /dev/null
    fi
}
CLEANED=0
# The preview step needs technical details; your own setting comes back.
DETAILS_BEFORE="$(defaults read be.jordythery.jamf-deployer showsTechnicalDetails 2> /dev/null || true)"
defaults write be.jordythery.jamf-deployer showsTechnicalDetails -bool true
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

CONNECTION="${EXPORT_CONNECTION:-platform}"
export TEST_RUNNER_EXPORT_CONNECTION="$CONNECTION"
if [[ "$CONNECTION" == jamfpro ]]; then
    export TEST_RUNNER_JPX_URL="https://$(kc $A jamfpro-fqdn)"
    export TEST_RUNNER_JPX_USERNAME="$(kc $A jamfpro-username)"
    export TEST_RUNNER_JPX_PASSWORD="$(kc $A jamfpro-password)"
    SECRET_ID=jamfpro-username SECRET_KEY=jamfpro-password
else
    export TEST_RUNNER_SBX_CLIENT_ID="$(kc $A client-id)"
    export TEST_RUNNER_SBX_CLIENT_SECRET="$(kc $A client-secret)"
    export TEST_RUNNER_SBX_ENVIRONMENT_ID="$(kc $A environment-id)"
    SECRET_ID=client-id SECRET_KEY=client-secret
    export TEST_RUNNER_SBX_REGION="${EXPORT_REGION:-US}"
fi
EXTRAS="${EXPORT_EXTRAS:-0}"
export TEST_RUNNER_EXPORT_EXTRAS="$EXTRAS"
# EXPORT_UEM_CONNECT=create: Security Cloud makes the UEM Connect itself (the
# tenant must have none); otherwise it uses the existing one.
export TEST_RUNNER_EXPORT_UEM_CONNECT="${EXPORT_UEM_CONNECT:-existing}"
if [[ "$EXTRAS" == 1 ]]; then
    export TEST_RUNNER_SBX_PROTECT_URL="$(kc $A protect-url)"
    export TEST_RUNNER_SBX_PROTECT_CLIENT_ID="$(kc $A protect-client-id)"
    export TEST_RUNNER_SBX_PROTECT_CLIENT_SECRET="$(kc $A protect-client-secret)"
    # A throwaway value: the repository must get it right, or its check finds a change.
    export TEST_RUNNER_EXPORT_SECRET="$(openssl rand -hex 12)"
fi
export TEST_RUNNER_EXPORT_REPOSITORY="https://github.com/$REPO.git"
export TEST_RUNNER_EXPORT_REVIEW_DIR="$REVIEW"
export TEST_RUNNER_EXPORT_MOVE_DIR="$MOVE"

# The demo catalog as a local release.
git clone -q "${CATALOG_SOURCE:-https://github.com/JordyThery/jamf-deployer-catalog}" "$WORK/work"
git -C "$WORK/work" tag -l | xargs git -C "$WORK/work" tag -d > /dev/null
if [[ "$EXTRAS" == 1 ]]; then
    cp -R "$HELPERS/uit-secret-marker" "$WORK/work/blocks/"
    git -C "$WORK/work" add blocks/uit-secret-marker
    git -C "$WORK/work" -c user.name=uitest -c user.email=uitest@localhost commit -qm "UIT secret marker"
fi
git -C "$WORK/work" tag v1.0.0
git clone -q --bare "$WORK/work" "$WORK/catalog.git"
export TEST_RUNNER_UITEST_CATALOG_URL="file://$WORK/catalog.git"

# The repository starts without main or a state branch: main is parked.
SHA="$(head_of main)"
if [[ -n "$SHA" ]]; then
    gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/uitest-parking -f sha="$SHA" > /dev/null
    gh api -X PATCH "repos/$REPO" -f default_branch=uitest-parking > /dev/null
fi
for branch in $(gh api "repos/$REPO/branches" --jq '.[].name' | grep -v '^uitest-parking$'); do
    gh api -X DELETE "repos/$REPO/git/refs/heads/$branch" > /dev/null
done
rm -rf "$REVIEW" "$MOVE"; mkdir -p "$REVIEW" "$MOVE"

xcodebuild build -project "Jamf Deployer.xcodeproj" -scheme "Jamf Deployer" -configuration Debug -destination "platform=macOS,arch=arm64" -quiet
defaults write be.jordythery.jamf-deployer NSNavLastRootDirectory -string "$HOME/Documents"
touch "Jamf DeployerUITests/"*.swift
xcodebuild build-for-testing -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination "platform=macOS" -quiet

run() {
    local log="$WORK/$1.log"
    for attempt in 1 2; do
        xcodebuild test-without-building -project "Jamf Deployer.xcodeproj" -scheme "Jamf DeployerUITests" -destination 'platform=macOS' \
            -resultBundlePath "$WORK/$1-$attempt.xcresult" \
            -only-testing:"Jamf DeployerUITests/ExportUITests/$1" > "$log" 2>&1
        if grep -qE "Test Case .*(passed|failed)" "$log"; then break; fi
        echo "  $1 produced no result (attempt $attempt)"
        sleep 5
    done
    grep -E "error:|Test Case .*(passed|failed)" "$log" || true
}

set +e
run test01ConnectAndDeploy
jp "print('  in Jamf:', len(cats), 'categories,', len(eas), 'attributes')"
run test01bPreviewShowsTheEngineWork

run test02ExportForReview
echo "Review export:"
echo "  tenant files: $(ls "$REVIEW/tenants/$TENANT" 2> /dev/null | tr '\n' ' ')"
echo "  modules: $(ls "$REVIEW/modules" 2> /dev/null | tr '\n' ' ')"
echo "  workflows: $(ls "$REVIEW/.github/workflows" 2> /dev/null | tr '\n' ' ')"
echo "  not a Git repository: $([[ -d "$REVIEW/.git" ]] && echo no || echo yes)"
TF="$HOME/Library/Application Support/Jamf Deployer/terraform/1.16.6/terraform"
if [[ -x "$TF" ]]; then
    "$TF" fmt -check -recursive "$REVIEW" > /dev/null && echo "  terraform fmt: clean" || { echo "  terraform fmt: NOT clean"; "$TF" fmt -check -recursive "$REVIEW" | sed 's/^/    /'; }
    "$TF" -chdir="$REVIEW/tenants/$TENANT" init -backend=false -input=false > /dev/null 2>&1
    echo "  terraform validate: $("$TF" -chdir="$REVIEW/tenants/$TENANT" validate -no-color | head -1)"
    rm -rf "$REVIEW/tenants/$TENANT/.terraform" "$REVIEW/tenants/$TENANT/.terraform.lock.hcl"
fi

run test03MoveToRepository
echo "Repository after the move:"
echo "  branches: $(gh api "repos/$REPO/branches" --jq '[.[].name] | join(", ")')"
echo "  tenant files on main: $(gh api "repos/$REPO/contents/tenants/$TENANT?ref=main" --jq '[.[].name] | join(", ")' 2> /dev/null)"
echo "  create-environments.sh committed: $(gh api "repos/$REPO/contents/create-environments.sh?ref=main" --jq .name 2> /dev/null || echo no)"
gh api "repos/$REPO/contents/tenants/$TENANT/terraform.tfstate?ref=terraform-state" --jq .content 2> /dev/null | base64 -d \
    | /usr/bin/python3 -c "import json,sys; s=json.load(sys.stdin); print('  state resources:', len(s['resources']), '| providers:', sorted({r['provider'] for r in s['resources']}))"
gh api -X PATCH "repos/$REPO" -f default_branch=main > /dev/null

echo "Creating the Environment with the exported script"
# Each secret is asked twice: for the tenant, then for its plans (Return: the same).
(cd "$MOVE" && {
    kc $A $SECRET_ID; echo; kc $A $SECRET_KEY; echo
    if [[ "$EXTRAS" == 1 ]]; then
        kc $A protect-client-id; echo; kc $A protect-client-secret; echo
        echo "$TEST_RUNNER_EXPORT_SECRET"; echo
    fi
} | ./create-environments.sh "$REPO" > /dev/null)
echo "  variables: $(gh variable list --repo "$REPO" --env "$TENANT" --json name --jq '[.[].name] | join(", ")')"
echo "  secrets: $(gh secret list --repo "$REPO" --env "$TENANT" --json name --jq '[.[].name] | join(", ")')"
echo "  plan secrets: $(gh secret list --repo "$REPO" --env "$TENANT-plan" --json name --jq '[.[].name] | join(", ")')"
echo "  branch policy: $(gh api "repos/$REPO/environments/$TENANT/deployment-branch-policies" --jq '[.branch_policies[].name] | join(", ")')"

echo "The repository's change check (must find no changes)"
gh workflow run drift.yml --repo "$REPO" --ref main > /dev/null; wait_run drift.yml
echo "  open change issues: $(gh issue list --repo "$REPO" --state open --label drift --json title --jq "map(select(.title == \"Changed in Jamf: $TENANT\")) | length")"

echo "A pull request (planned with the tenant's plan Environment)"
git clone -q "https://github.com/$REPO.git" "$WORK/clone"
git -C "$WORK/clone" checkout -q -b uitest-pr
printf '\n# A change to review.\n' >> "$WORK/clone/tenants/$TENANT/main.tf"
"$TF" fmt "$WORK/clone/tenants/$TENANT" > /dev/null 2>&1 || true
git -C "$WORK/clone" -c user.name=uitest -c user.email=uitest@localhost commit -qam "A change to review"
git -C "$WORK/clone" push -q origin uitest-pr
PR_URL=$(gh pr create --repo "$REPO" --base main --head uitest-pr --title "A change to review" --body "UI test")
wait_run plan.yml
echo "  plan comment: $(gh pr view "$PR_URL" --json comments --jq '.comments[].body' | grep -m1 -oE 'No changes\.|[0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy' || echo none)"
echo "  plan Environment deployments: $(gh api "repos/$REPO/deployments?environment=$TENANT-plan" --jq length)"
gh pr close "$PR_URL" --delete-branch > /dev/null

echo "The repository's Destroy workflow"
# Only when everything the moved state manages is the test's own.
FOREIGN=$(gh api "repos/$REPO/contents/tenants/$TENANT/terraform.tfstate?ref=terraform-state" --jq .content 2> /dev/null | base64 -d \
    | /usr/bin/python3 -c "
import json, sys
s = json.load(sys.stdin)
# A UEM Connect has no name; it is the test's own when the test made it.
own_uem = '$TEST_RUNNER_EXPORT_UEM_CONNECT' == 'create'
names = [i['attributes'].get('name', '') for r in s['resources'] if r['mode'] == 'managed'
         if not (own_uem and r['type'] == 'jamfplatform_security_cloud_uem_connect') for i in r['instances']]
print(sum(not n.startswith('UIT EX - ') for n in names) if names else 1)")
if [[ "$FOREIGN" == "0" ]]; then
    gh workflow run destroy.yml --repo "$REPO" --ref main -f tenant=$TENANT -f confirm=$TENANT > /dev/null; wait_run destroy.yml
else
    echo "  WARNING: the moved state holds objects the test did not create; Destroy skipped" >&2
fi
jp "print('  left in Jamf:', len(cats) + len(eas), 'UIT EX objects')"
echo "  left in the moved state: $(gh api "repos/$REPO/contents/tenants/$TENANT/terraform.tfstate?ref=terraform-state" --jq .content 2> /dev/null | base64 -d \
    | /usr/bin/python3 -c "import json,sys; s=json.load(sys.stdin); print(sum(len(r['instances']) for r in s['resources'] if r['mode']=='managed'), 'objects')")"

run test04RemoveTenantAndCatalog
set -e
cleanup
trap - EXIT INT TERM
