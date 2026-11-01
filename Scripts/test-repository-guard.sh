# Sourced by run-team-ui-tests.sh and run-export-ui-tests.sh, which replace
# every branch of the repository they're given. Refuses anything but a
# private throwaway test repository: its name must contain "test",
# "sandbox", "throwaway" or "scratch" as a word (jamf-deployer-export-test),
# or CONFIRM_TEST_REPOSITORY must repeat <owner/repository> exactly.
#
#   require_test_repository <owner/repository>
require_test_repository() {
    local repo="$1" name="${1#*/}" private
    if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        echo "Refused: $repo isn’t an owner/repository name" >&2; return 1
    fi
    private="$(gh api "repos/$repo" --jq .private 2> /dev/null)"
    if [[ "$private" != true ]]; then
        echo "Refused: $repo isn’t a private repository you can read (gh api says: ${private:-nothing})" >&2; return 1
    fi
    if [[ "${(L)name}" =~ (^|[-_.])(test|tests|sandbox|throwaway|scratch)([-_.]|$) ]]; then
        return 0
    fi
    if [[ "${CONFIRM_TEST_REPOSITORY:-}" == "$repo" ]]; then
        return 0
    fi
    echo "Refused: $repo doesn’t look like a throwaway test repository; every branch in it is replaced." >&2
    echo "If it is one, run again with CONFIRM_TEST_REPOSITORY=$repo" >&2
    return 1
}
