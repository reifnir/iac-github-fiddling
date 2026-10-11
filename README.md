# github-fiddling

A collection of non-trivial GitHub Actions patterns. The jobs are echo stubs, so each workflow shows only its structure (fan-out, chaining, gating, hand-offs) and has no real infrastructure behind it.

| Workflow | Pattern | Trigger |
|---|---|---|
| [env-pipeline.yml](.github/workflows/env-pipeline.yml) | dev → test → prod, same jobs, per-environment variables | PR to `main`, push to `main`, manual |
| [fanout-matrix-job.yml](.github/workflows/fanout-matrix-job.yml) | One **job** per item in a collection, plus fan-in summary | manual |
| [fanout-child-pipeline.yml](.github/workflows/fanout-child-pipeline.yml) | One **child pipeline** per item, nested in one run | manual |
| [fanout-dispatch.yml](.github/workflows/fanout-dispatch.yml) | One **child pipeline** per item, each its own run | manual |

Workflows starting with `_` are reusable (`workflow_call`) building blocks. GitHub doesn't allow subfolders under `.github/workflows`, so the prefix is how they're grouped.

| Reusable workflow | Used by |
|---|---|
| [_env-stage.yml](.github/workflows/_env-stage.yml) | `env-pipeline` (plan + apply for one environment) |
| [_list-repos.yml](.github/workflows/_list-repos.yml) | all `fanout-*` (outputs the JSON collection) |
| [_repo-child.yml](.github/workflows/_repo-child.yml) | `fanout-child-pipeline` (via `workflow_call`) and `fanout-dispatch` (via `workflow_dispatch`) |

## 1. Environment pipeline

`env-pipeline` calls `_env-stage` three times in sequence (`dev` → `test` → `prod`). Each stage has a `plan` job and an `apply` job. The stages differ only in the `environment` input, which selects the [GitHub Environment](https://docs.github.com/actions/deployment/targeting-different-environments) and therefore its variables.

| Event | dev plan | dev apply | test plan | test apply | prod plan | prod apply |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Pull request to `main` | ✅ | ✅ | ✅ | skipped | ✅ | skipped |
| Push to `main` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Manual run on `main` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Manual run on another branch | ✅ | ✅ | ✅ | skipped | ✅ | skipped |

Details worth knowing:

- **Plan → apply handoff.** `plan` uploads `plan-<env>.txt` as an artifact and `apply` downloads it, the same way a saved Terraform plan would be passed along.
- **Variable precedence.** `APP_NAME` and `LOG_LEVEL=info` are repo-level variables. [config/environments/dev.env](config/environments/dev.env) overrides `LOG_LEVEL=debug`, so dev shows `debug` while test and prod inherit `info`.
- **Concurrency.** A newer push to the same PR cancels the older run. Runs on `main` queue instead, so a run is never cancelled partway through its applies.
- **Skipped apply doesn't block the chain.** A skipped job inside a called workflow still leaves the call successful, so `prod` (which `needs: test`) runs its plan on PRs.

## 2. One job per item

`fanout-matrix-job`: `discover` → `per-repo` (matrix) → `summarize`.

- `discover` lists the owner's public, non-archived repos as a JSON array (owner defaults to this repo's owner and can be overridden on dispatch).
- `per-repo` builds its matrix from that output with `fromJSON(...)` and runs one job per repo.
- Matrix legs can't each publish their own job outputs, so every leg uploads a small JSON artifact instead. `summarize` downloads them all (`pattern: repo-*`, `merge-multiple: true`) and writes a table to the run summary.

Limits handled: a matrix can hold at most 256 jobs (the list is truncated with a warning), and an empty matrix is an error (the job is skipped when the list is empty).

## 3. One child pipeline per item

The child is [_repo-child.yml](.github/workflows/_repo-child.yml), a three-job pipeline: `inspect` → `check` → `report`. Job outputs pass data down the chain. It declares both `workflow_call` and `workflow_dispatch` with the same inputs, so both parent styles reuse it:

- **3a `fanout-child-pipeline`** runs a matrix over the reusable workflow. Every repo's child graph appears **nested inside a single run**, and the parent's status reflects all children.
- **3b `fanout-dispatch`** calls `gh workflow run` once per repo. Each child is a **separate top-level run** named `child – <repo>`, the closest match to GitLab's `trigger:`. It needs `permissions: actions: write`. `workflow_dispatch` is one of the few events the built-in `GITHUB_TOKEN` is allowed to trigger. This parent is fire-and-forget (it doesn't wait for the children), and the child workflow must already exist on the default branch.

## Setup

GitLab is the source of truth and push-mirrors to GitHub, where the workflows run.

1. **GitHub repo:** create an empty repo on GitHub, for example `github.com/reifnir/iac-github-fiddling`.
2. **GitHub token for the mirror:** create a fine-grained PAT scoped to that repo with **Contents: Read and write** and **Workflows: Read and write**. GitHub rejects pushes that touch `.github/workflows/*` unless the token has the workflows permission.
3. **GitLab push mirror:** in GitLab, go to *Settings → Repository → Mirroring repositories* and add `https://github.com/<user>/<repo>.git`, direction *Push*, with your GitHub username and the PAT as the password.
4. **Environments and variables:** run `scripts/setup-github.sh <user>/<repo>` (needs `gh auth login`). It creates `dev`, `test` and `prod` and loads their variables from [config/environments/](config/environments/). It's safe to re-run.

### Working through the mirror

- Push a feature branch to GitLab. It shows up on GitHub, where you open the PR (`gh pr create --repo <user>/<repo>`) to exercise PR behavior.
- **Merge on GitLab, not on GitHub.** A merge made on GitHub diverges from the mirror and is overwritten on the next mirror push. Once the merge reaches GitLab `main` and is mirrored, it fires the full `main` pipeline. Close the GitHub PR afterwards.

### Running the fan-outs

```sh
gh workflow run fanout-matrix-job.yml     --repo <user>/<repo>  # optionally: -f owner=<someone-else>
gh workflow run fanout-child-pipeline.yml --repo <user>/<repo>
gh workflow run fanout-dispatch.yml       --repo <user>/<repo>
gh run list --workflow _repo-child.yml    --repo <user>/<repo>  # the dispatched children
```

## Backlog: other interesting GitHub Actions behaviors

Not implemented yet. Candidates for future workflows:

- **Approval gates:** environment protection rules (required reviewers, wait timers, deployment-branch policies). Because `plan` also binds to its environment (to read its variables), a reviewer gate on `prod` would also gate prod's *plan*. Splitting it into a `prod-plan` environment avoids that.
- **Serialized deploys:** a concurrency group per environment (`deploy-prod`) shared across workflows.
- **Change detection:** path filters and changed-file detection that build a dynamic matrix (monorepo: only plan the stacks that changed).
- **Workflow chaining:** `workflow_run` (start when another workflow completes), and `repository_dispatch` from external systems or other repos.
- **Waiting on dispatched children:** poll or `gh run watch` the runs started by `fanout-dispatch` and aggregate their results.
- **ChatOps:** `issue_comment` commands such as `/apply`, and label-triggered jobs.
- **Advanced matrices:** `include`/`exclude`, multi-dimensional matrices, `continue-on-error` "experimental" legs.
- **Action types:** composite actions vs reusable workflows vs JavaScript/Docker actions.
- **Scheduled workflows** (`schedule` cron), e.g. drift detection.
- **OIDC federation** to AWS/Azure/GCP (no stored cloud secrets), with role trust scoped per environment.
- **Merge queue** (`merge_group` event).
- **Service containers** (e.g. Postgres) for integration tests.
- **Caching** with `actions/cache`, and artifacts shared across runs.
- **Cleanup and notifications:** `if: always()` / `failure()` cleanup and notification jobs; `timeout-minutes`.
- **GitHub App tokens** (`actions/create-github-app-token`) for cross-repo writes and for triggering events `GITHUB_TOKEN` can't.
- **Security hardening:** least-privilege `permissions`, `pull_request_target` pitfalls, pinning actions by SHA.
- **Supply chain:** artifact attestations and SLSA provenance.
- **Release automation:** tags, release-please, generated changelogs.
- **Runners:** self-hosted runners, Actions Runner Controller (ARC), larger runners.
- **Org-level controls:** rulesets and required workflows, workflow templates.

