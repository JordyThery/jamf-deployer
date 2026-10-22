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

# Terraform for the repository checks: the app's own download, else the one on PATH.
TF="$HOME/Library/Application Support/Jamf Deployer/terraform/1.16.6/terraform"
[[ -x "$TF" ]] || TF="$(command -v terraform || true)"
TOFU="$(find ~/Library/Developer/Xcode/DerivedData/Jamf_Deployer-*/Build/Products/Debug/"Jamf Deployer.app" -path '*opentofu/bin/tofu' 2> /dev/null | head -1)"

set +e
run test01ConnectAndDeploy
jp "print('  in Jamf:', len(cats), 'categories,', len(eas), 'attributes')"
run test01bPreviewShowsTheEngineWork
echo "  plan.sh written next to main.tf: $(ls "$HOME/Library/Application Support/Jamf Deployer/store/tenants/"*/generated/plan.sh 2> /dev/null | wc -l | tr -d ' ')"

# Graduating to Terraform, stage 2a: the tenant by hand, from a copy of its
# workspace (the app's own copy stays as it is).
if [[ "$EXTRAS" != 1 && -x "$TF" && -x "$TOFU" ]]; then
    echo "Stage 2a: the tenant by hand"
    SUPPORT="$HOME/Library/Application Support/Jamf Deployer"
    TDIR="$(dirname "$(grep -l '"name" *: *"Export Sandbox"' "$SUPPORT"/store/tenants/*/tenant.json | head -1)")"
    SHEET=~/Documents/"Jamf Deployer Recovery — Export Sandbox.txt"
    H="$WORK/by-hand"; mkdir -p "$H"
    cp -R "$TDIR/generated" "$H/generated"; cp -R "$TDIR/state" "$H/state"
    (
        cd "$H/generated" && rm -rf .terraform .terraform.lock.hcl plan.bin drift.bin plan.sh
        if [[ "$CONNECTION" == jamfpro ]]; then
            export JAMFPRO_INSTANCE_FQDN="https://$(kc $A jamfpro-fqdn)" JAMFPRO_AUTH_PROVIDER=direct JAMFPRO_AUTH_METHOD=basic
            export JAMFPRO_BASIC_USERNAME="$(kc $A jamfpro-username)" JAMFPRO_BASIC_PASSWORD="$(kc $A jamfpro-password)"
            PROVIDER=deploymenttheory/jamfpro; PAR=-parallelism=1
        else
            export JAMFPLATFORM_BASE_URL="$(kc $A base-url)" JAMFPLATFORM_ENVIRONMENT_ID="$(kc $A environment-id)"
            export JAMFPLATFORM_CLIENT_ID="$(kc $A client-id)" JAMFPLATFORM_CLIENT_SECRET="$(kc $A client-secret)"
            PROVIDER=jamf/jamfplatform; PAR=
        fi
        PASSPHRASE="$(awk '/Recovery passphrase:/{getline; getline; gsub(/^[ \t]+/, ""); print; exit}' "$SHEET")"
        export TF_ENCRYPTION="
key_provider \"pbkdf2\" \"passphrase\" {
  passphrase = \"$PASSPHRASE\"
}
method \"aes_gcm\" \"old\" {
  keys = key_provider.pbkdf2.passphrase
}
method \"unencrypted\" \"plain\" {}
state {
  method   = method.unencrypted.plain
  fallback { method = method.aes_gcm.old }
}
plan {
  method   = method.unencrypted.plain
  fallback { method = method.aes_gcm.old }
}"
        "$TOFU" init -input=false > "$WORK/by-hand.log" 2>&1 \
            && "$TOFU" apply -refresh-only -auto-approve -input=false $PAR >> "$WORK/by-hand.log" 2>&1 \
            && echo "  decrypted once with OpenTofu" || echo "  OpenTofu decrypt FAILED (by-hand.log)"
        unset TF_ENCRYPTION
        echo "  state still encrypted: $(grep -c encrypted_data ../state/terraform.tfstate)"
        "$TF" init -input=false >> "$WORK/by-hand.log" 2>&1
        "$TF" state replace-provider -auto-approve "registry.opentofu.org/$PROVIDER" "registry.terraform.io/$PROVIDER" >> "$WORK/by-hand.log" 2>&1
        "$TF" plan -input=false -no-color -detailed-exitcode $PAR >> "$WORK/by-hand.log" 2>&1
        case $? in 0) echo "  terraform plan: No changes";; 2) echo "  terraform plan: CHANGES (by-hand.log)";; *) echo "  terraform plan: FAILED (by-hand.log)";; esac
    )
fi

run test02ExportForReview
echo "Review export:"
echo "  tenant files: $(ls "$REVIEW/tenants/$TENANT" 2> /dev/null | tr '\n' ' ')"
echo "  modules: $(ls "$REVIEW/modules" 2> /dev/null | tr '\n' ' ')"
echo "  workflows: $(ls "$REVIEW/.github/workflows" 2> /dev/null | tr '\n' ' ')"
echo "  not a Git repository: $([[ -d "$REVIEW/.git" ]] && echo no || echo yes)"
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

# Graduating to Terraform, stages 3 and 4, against the moved repository.
git clone -q "https://github.com/$REPO.git" "$WORK/clone"
G() { git -C "$WORK/clone" -c user.name=uitest -c user.email=uitest@localhost "$@"; }
latest_comment() { gh pr view "$1" --repo "$REPO" --json comments --jq '.comments[].body' | grep -m1 -oE 'No changes\.|[0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy' || echo none; }

echo "Stage 4: one change to every tenant (a shared module), merged and applied"
G checkout -q -b uitest-fleet
# Both versions of the block, as the guide says: Jamf Pro API tenants use jamfpro/.
/usr/bin/python3 - "$WORK/clone/modules/categories/main.tf" "$WORK/clone/modules/categories/jamfpro/main.tf" <<'EDIT'
import sys
for p in sys.argv[1:]:
    s = open(p).read()
    old = '"Maintenance", "Security"]'
    assert old in s, "categories list not found in " + p
    open(p, "w").write(s.replace(old, '"Maintenance", "Printers", "Security"]'))
EDIT
G commit -qam "Add a Printers category everywhere"
G push -q origin uitest-fleet
PR_URL=$(gh pr create --repo "$REPO" --base main --head uitest-fleet --title "Add a Printers category everywhere" --body "UI test")
wait_run plan.yml
echo "  plan comment: $(latest_comment "$PR_URL")"
echo "  plan Environment deployments: $(gh api "repos/$REPO/deployments?environment=$TENANT-plan" --jq length)"
gh pr merge "$PR_URL" --repo "$REPO" --merge --delete-branch > /dev/null
wait_run apply.yml
jp "print('  Printers in Jamf:', any(c['name'] == 'UIT EX - Printers' for c in cats))"

echo "Stage 4: an object made outside the code"
jp "call('POST', '/api/v1/categories', {'name': 'UIT EX - Hand made', 'priority': 9}); print('  made a category by hand')"
gh workflow run reconcile.yml --repo "$REPO" --ref main > /dev/null; wait_run reconcile.yml
echo "  Not in code issue lists it: $(gh issue list --repo "$REPO" --state open --label not-in-code --json title,body \
    --jq "map(select(.title == \"Not in code: $TENANT\")) | .[0].body // \"\"" | grep -c 'UIT EX - Hand made')"

echo "Stage 4: adding a tenant with scripts/new-tenant.sh"
G checkout -q main; G pull -q
# The script's questions in order: connection details, each secret then its
# plan copy (Return: the same), and Return once the values are set.
answers() {
    if [[ "$CONNECTION" == jamfpro ]]; then
        printf '%s\n' "https://$(kc $A jamfpro-fqdn)" basic "$(kc $A jamfpro-username)" "" "$(kc $A jamfpro-password)" "" ""
    else
        printf '%s\n' "$(kc $A base-url)" "$(kc $A environment-id)" "$(kc $A client-id)" "" "$(kc $A client-secret)" ""
        if [[ "$EXTRAS" == 1 ]]; then
            printf '%s\n' "$(kc $A protect-url)" "$(kc $A protect-client-id)" "" "$(kc $A protect-client-secret)" ""
            printf '%s\n' "$TEST_RUNNER_EXPORT_SECRET" ""
        fi
        printf '\n'
    fi
}
NEW_PR=$(cd "$WORK/clone" && answers | scripts/new-tenant.sh uit-second 2> "$WORK/new-tenant.log" | grep -o 'https://github.com/[^ ]*/pull/[0-9]*')
echo "  pull request: ${NEW_PR:-none} | Environments: $(gh api "repos/$REPO/environments" --jq '[.environments[].name | select(startswith("uit-second"))] | join(", ")')"
if [[ -n "$NEW_PR" ]]; then
    wait_run plan.yml
    echo "  plan comment: $(latest_comment "$NEW_PR")"
    gh pr close "$NEW_PR" --repo "$REPO" --delete-branch > /dev/null
fi
for e in uit-second uit-second-plan; do gh api -X DELETE "repos/$REPO/environments/$e" > /dev/null 2>&1; done

echo "Stage 4: a stuck lock, released with the Force unlock workflow"
PORT=$(( 40000 + RANDOM % 20000 )); PASS="$(uuidgen)"
mkdir -p "$WORK/locker"
TMPDIR="$WORK/locker" GIT_USERNAME=x-access-token GITHUB_TOKEN="$(gh auth token)" TF_BACKEND_GIT_HTTP_USERNAME=locker TF_BACKEND_GIT_HTTP_PASSWORD="$PASS" \
    Vendor/terraform-backend-git/terraform-backend-git --address=127.0.0.1:$PORT > "$WORK/locker.log" 2>&1 &
LOCKER=$!
sleep 2
U="http://127.0.0.1:$PORT/?type=git&repository=https://github.com/$REPO.git&ref=terraform-state&state=tenants/$TENANT/terraform.tfstate"
curl -s -o /dev/null -u locker:$PASS -X LOCK \
    --data '{"ID":"uitest-stuck-lock","Operation":"OperationTypeApply","Who":"runner@cancelled","Version":"1.15.0","Created":"2026-10-21T08:00:00Z","Path":"","Info":""}' "$U"
kill $LOCKER
echo "  lock branches before: $(gh api "repos/$REPO/branches" --jq '.[].name' | grep -c '^locks/')"
echo "  a run while the lock is stuck (expected to fail):"
gh workflow run drift.yml --repo "$REPO" --ref main > /dev/null; wait_run drift.yml
gh workflow run force-unlock.yml --repo "$REPO" --ref main -f tenant=$TENANT -f confirm=$TENANT > /dev/null; wait_run force-unlock.yml
echo "  lock branches after: $(gh api "repos/$REPO/branches" --jq '.[].name' | grep -c '^locks/')"

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

echo "Stage 4: handing the tenant over with scripts/hand-over.sh"
G checkout -q main; G pull -q
HO_PR=$(cd "$WORK/clone" && echo "$TENANT" | scripts/hand-over.sh "$TENANT" 2> "$WORK/hand-over.log" | grep -o 'https://github.com/[^ ]*/pull/[0-9]*')
if [[ -n "$HO_PR" ]]; then
    wait_run plan.yml
    gh pr merge "$HO_PR" --repo "$REPO" --merge --delete-branch > /dev/null
    wait_run apply.yml
fi
echo "  state archived: $(gh api "repos/$REPO/contents/handed-over?ref=terraform-state" --jq "[.[].name | select(startswith(\"$TENANT-\"))] | length" 2> /dev/null || echo 0)" \
     "| left under tenants/: $(gh api "repos/$REPO/contents/tenants/$TENANT/terraform.tfstate?ref=terraform-state" --jq .name 2> /dev/null || echo none)"

run test04RemoveTenantAndCatalog
set -e
cleanup
trap - EXIT INT TERM
