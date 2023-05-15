#!/bin/bash -l

# check whether a string ($1) is in array ($2) using a grep pattern-matching search
# eg $2="foo/* hello/* test", $1=foo/bar (success), $1=hello/world (success), $1=test123 (fail)
is_in_pattern_list() {
    find=$1
    shift
    list=("$@")

    for pattern in "${list[@]}"; do
        if echo "$find" | grep -qe "$pattern"; then
           return 0
        fi
    done

    return 1
}

generate_required_status_checks() {
    local original=$1
    local result=
    if [ "$(echo -E $original | jq '.required_status_checks == null')" == "true" ]; then
        result='null'
    else
        result=$(jq -n \
        --argjson required_status_checks_strict "$(echo -E $original | jq '.required_status_checks.strict // false')" \
        --argjson required_status_checks_contexts "[$(echo -E $original | jq '.required_status_checks.contexts[]?' -c | tr '\n' ',' | sed 's/,$//')]" \
        '{
            "strict": $required_status_checks_strict,
            "contexts": $required_status_checks_contexts
        }')
    fi

    echo $result
}

generate_required_pull_request_reviews() {
    local original=$1
    local result=
    if [ "$(echo -E $original | jq '.required_pull_request_reviews == null')" == "true" ]; then
        result='null'
    else
        result=$(jq -n \
        --argjson required_pull_request_reviews_dismissal_restrictions_users "[$(echo -E $original | jq '.required_pull_request_reviews.dismissal_restrictions.users[]?.login' -c | tr '\n' ',' | sed 's/,$//')]" \
        --argjson required_pull_request_reviews_dismissal_restrictions_teams "[$(echo -E $original | jq '.required_pull_request_reviews.dismissal_restrictions.teams[]?.login' -c | tr '\n' ',' | sed 's/,$//')]" \
        --argjson required_pull_request_reviews_dismiss_stale_reviews "$(echo -E $original | jq '.required_pull_request_reviews.dismiss_stale_reviews // false')" \
        --argjson required_pull_request_reviews_require_code_owner_reviews "$(echo -E $original | jq '.required_pull_request_reviews.require_code_owner_reviews // false')" \
        --argjson required_pull_request_reviews_required_approving_review_count "$(echo -E $original | jq '.required_pull_request_reviews.required_approving_review_count // 1')" \
        '{
            "dismissal_restrictions": {
                "users": $required_pull_request_reviews_dismissal_restrictions_users,
                "teams": $required_pull_request_reviews_dismissal_restrictions_teams
            },
            "dismiss_stale_reviews": $required_pull_request_reviews_dismiss_stale_reviews,
            "require_code_owner_reviews": $required_pull_request_reviews_require_code_owner_reviews,
            "required_approving_review_count": $required_pull_request_reviews_required_approving_review_count
        }')
    fi

    echo $result
}

generate_restrictions() {
    local original=$1
    local result=
    if [ "$(echo -E $original | jq '.restrictions == null')" == "true" ]; then
        result='null'
    else
        result=$(jq -n \
        --argjson restrictions_users "[$(echo -E $original | jq '.restrictions.users[]?.login' -c | tr '\n' ',' | sed 's/,$//')]" \
        --argjson restrictions_teams "[$(echo -E $original | jq '.restrictions.teams[]?.slug' -c | tr '\n' ',' | sed 's/,$//')]" \
        --argjson restrictions_apps "[$(echo -E $original | jq '.restrictions.apps[]?.slug' -c | tr '\n' ',' | sed 's/,$//')]" \
        '{
            "users": $restrictions_users,
            "teams": $restrictions_teams,
            "apps": $restrictions_apps
        }')
    fi

    echo $result
}

generate_branch_protection() {
    local original=$1

    local result=$(jq -n \
    --argjson required_status_checks "$(generate_required_status_checks $original)" \
    --argjson enforce_admins_enabled "$(echo -E $original | jq '.enforce_admins.enabled // false')" \
    --argjson required_pull_request_reviews "$(generate_required_pull_request_reviews $original)" \
    --argjson restrictions "$(generate_restrictions $original)" \
    '{
        "required_status_checks": $required_status_checks,
        "enforce_admins": $enforce_admins_enabled,
        "required_pull_request_reviews": $required_pull_request_reviews,
        "restrictions": $restrictions
    }')

    if [ "$?" -ne 0 ]; then
        echo "Error when attempting to generate branch protection"
        exit 2
    fi

    echo $result
}

if [ -z "${GITHUB_EVENT_PATH}" ] || [ ! -f "${GITHUB_EVENT_PATH}" ]; then
    echo "No file containing event data found. Cannot continue"
    exit 2
fi

if [ -z "${INPUT_GITHUB_TOKEN}" ]; then
    echo "No Github token provided. Cannot continue"
    exit 2
fi

GITHUB_TOKEN=${INPUT_GITHUB_TOKEN}
export GITHUB_TOKEN

ORIGIN=${INPUT_REMOTE_NAME}
JSON=$(cat ${GITHUB_EVENT_PATH} | jq)
REF=$(echo -E ${JSON} | jq -r '.ref')
REF_TYPE=$(echo -e ${JSON} | jq -r '.ref_type')
IGNORED_BRANCHES=(${INPUT_IGNORE_BRANCHES})
CLEANED=''

if [ ! "${REF_TYPE}" == "tag" ]; then
    echo "Not a tag, skipping"
    exit 0
fi

git config --global user.email "actions@github.com"
git config --global user.name "${GITHUB_ACTOR}"

remote_repo="https://${GITHUB_ACTOR}:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

# itterate through all branches in origin
# intent is to ensure the branch the tag was on has been reset back to the latest tag (ie code had been reverted)
# since the delete trigger doesnt inform us of the exact branch the tag was on, we need to apply to all branches
for branch in $(git for-each-ref --format="%(refname:short)" | grep "${ORIGIN}/"); do
    local_branch=${branch/$ORIGIN\//}

    # skip ignored branches
    if is_in_pattern_list $local_branch "${IGNORED_BRANCHES[@]}"; then
        continue;
    fi

    head_commit=$(git rev-list -n 1 ${branch})

    latest_tag=$(git describe --abbrev=0 --tags --first-parent ${branch} 2> /dev/null)
    # ignore branches with no existing tags (ignores feature branches and initial commits)
    if [ "$?" -ne "0" ]; then
        continue;
    fi

    latest_tag_commit=$(git rev-list -n 1 ${latest_tag} 2> /dev/null)
    # if the commit ids are identical, then latest tag is at head; no action to take
    if [ "${latest_tag_commit}" = "${head_commit}" ]; then
        continue;
    fi

    # # github actions prevents itself from modifying actions, so if there have been changes to any actions
    # # between the tags, we need to preserve the current version, and not revert!
    # echo "${branch} : copy .github to temp location"
    # cp -a .github /tmp/

    echo "${branch} : git checkout ${local_branch}"
    git checkout ${local_branch}

    echo "${branch} : create backup of HEAD commit"
    mkdir -p ${HOME}/${INPUT_BACKUP_DIR}/${local_branch}
    cp -a . ${HOME}/${INPUT_BACKUP_DIR}/${local_branch}

    # to revert the branch back to the last tag, we need to reset the branch and force push

    echo "${branch} : git reset --hard ${latest_tag}"
    git reset --hard ${latest_tag}

    current_protection=$(hub api repos/${GITHUB_REPOSITORY}/branches/${local_branch}/protection)
    current_protection_status=$?

    if [ "$current_protection_status" -eq "0" ]; then
        echo "${branch} : Remove branch protection"
        hub api -X DELETE repos/${GITHUB_REPOSITORY}/branches/${local_branch}/protection
    fi

    echo "${branch} : git push --force ${remote_repo} ${local_branch}"
    git push --force ${remote_repo} ${local_branch}

    if [ "$current_protection_status" -eq "0" ]; then
        echo "${branch} : Re-enable branch protection"
        echo $(generate_branch_protection ${current_protection}) | \
            hub api -X PUT repos/${GITHUB_REPOSITORY}/branches/${local_branch}/protection --input -
    fi

    CLEANED+="${local_branch},"
done
echo ""
# return list of cleaned up branches
echo "cleaned=$(echo $CLEANED | sed -e 's/,*$//')" >> $GITHUB_OUTPUT
