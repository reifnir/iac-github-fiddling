#!/usr/bin/env bash
# Creates the dev/test/prod GitHub Environments and loads their variables.
# Safe to re-run: environments are upserted and variables overwritten.
set -euo pipefail

repo="${1:?usage: $0 <owner/repo>}"
root="$(cd "$(dirname "$0")/.." && pwd)"

# Repo-level variables, visible to every job. Environment-level variables
# with the same name take precedence (see LOG_LEVEL in dev.env).
gh variable set APP_NAME --repo "$repo" --body "github-fiddling"
gh variable set LOG_LEVEL --repo "$repo" --body "info"

for env in dev test prod; do
  echo "==> $env"
  gh api --method PUT "repos/$repo/environments/$env" --silent
  gh variable set --repo "$repo" --env "$env" --env-file "$root/config/environments/$env.env"
done
