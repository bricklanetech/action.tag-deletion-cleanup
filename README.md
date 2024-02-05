# GitOps - Branch Cleanup Github Action

A Github action that resets all branches back to the latest tag defined against the branch.

This useful for GitOps workflows where the tag names are used declaratively to descibe the state of any environment, with the latest Tag reflecting the 'current' state of an environment.

This action is typically triggered upon Tag deletion... ie a rollback. Following which, the targetted branch is also rolled back to a specific state.

Typically, you want this behavior on environment-based branches (ie branches that are used for workflow purposes), but not to development branches. Selecting excluded branch patterns is available and by default, any `feature/` or `hotfix/` branch is excluded cleanup.

**Note: this action alters history! Resetting a branch back to a previous tag will the commit history for any commits made between the lastest tag and HEAD of the branch.**

## How to Use

1. Create a new action to trigger on a delete action
2. Within `jobs.<job_id>.steps` of the action workflow, add a `uses` statement similar to the following (see below for use of the `with` statement).
   ```yml
   - uses: bricklanetech/action.tag-deletion-cleanup@v1
     with:
       github_token: ${{ secrets.BOT_TOKEN }}
   ```

## Using the `with` statement

See https://github.com/bricklanetech/action.tag-deletion-cleanup/blob/master/action.yml for details of the allowed/required input parameters and their usage.

Note that due to the need to bypass branch protections (to allow a force push),

change for commit
