[![Build status](https://badge.buildkite.com/94e57088306f043a00125ea68929d2a132149eae01de98bd71.svg)](https://buildkite.com/theopenlane/git-buildkite-plugin)

# git

A Buildkite plugin for cross-repo automation with reusable primitives:

- optional artifact download into the source workspace
- source command execution (generation/build steps)
- cloning a target repo + branch handling + git identity/auth
- file/dir sync and generic YAML subtree merge (`merge-yaml`)
- commit/push and PR create/update via `gh`
- templated Slack notifications via webhook

## Examples

```yml
steps:
  - label: ":yaml: generate and sync config"
    command: task config:ci # generate local config artifacts first
    plugins:
      - theopenlane/git#v0.1.5:
          execute-phase: post-command # run after step command completes
          repository: git@github.com:theopenlane/openlane-infra.git # target repo to open PR against
          branch: "update-helm-config-${BUILDKITE_BUILD_NUMBER}" # explicit target branch
          preset: helm-sync # enables merge-yaml defaults + chart path defaults
          chart-name: openlane # default target-root becomes charts/openlane
          base-merge-target-path: .openlane.coreConfiguration # reused merge destination key
          base-merge-source-path: .openlane.coreConfiguration // .coreConfiguration # fallback source expression
          user:
            name: theopenlane-bender
            email: bender@theopenlane.io
          sync:
            - from: helm-values.yaml
              to: values.yaml # maps to charts/openlane/values.yaml via preset
            - from: helm-values.yaml
              to: values.yaml
              merge-target-suffix: .externalSecrets # appends to base merge target path
              required: false # skip if source subtree doesn't exist
              merge-delete-paths:
                - .externalSecrets # remove top-level copy after nesting under coreConfiguration
            - from: configmap-config-file.yaml
              to: templates/core-configmap-file.yaml
              type: file
            - from: external-secrets
              to: templates/external-secrets
              type: dir # directory sync mode
              delete: true # mirror source directory (remove stale dest files)
          target-run:
            - |
              # run target repo maintenance after sync
              task docs
              yq e '.openlane' values.yaml | sed -n '1,40p'
          commit-message: "chore: update Helm config from core build #{{BUILD_NUMBER}}" # templated commit message
          pr:
            enabled: true
            title: "🤖 Update Helm chart from core config (Build #{{BUILD_NUMBER}})"
            body-file: templates/github/helm-update-pr.md
            comment-on-source-pr: true
            source-comment: |
              ## 🔧 Configuration Changes Detected
              Automated infra PR: {{TARGET_PR_URL}}
          slack:
            enabled: true
            webhook-env: SLACK_WEBHOOK_URL
            template-file: templates/slack/helm-update-notification.json
```

```yml
steps:
  - label: ":graphql: sync generated files to go-client"
    command: task graphql:generate # generate artifacts in source repo
    plugins:
      - theopenlane/git#v0.1.5:
          repository: git@github.com:theopenlane/go-client.git # downstream repo
          branch-prefix: sync-go-client
          source-run:
            - task graphql:generate # optional re-run before copy
          sync:
            - from: internal/graphql/generated
              to: graphql
              type: dir
              delete: true # keep target graphql dir in exact sync
          target-run:
            - |
              # post-sync generation in target repo
              go generate ./...
              gofmt -w .
            - "git status --short | sed -n '1,80p'" # inline shell pipeline is supported
          commit-message: "chore: sync graphql artifacts from core #{{BUILD_NUMBER}}"
          pr:
            title: "Sync GraphQL artifacts from core (Build #{{BUILD_NUMBER}})"
```

```yml
steps:
  - label: ":book: sync schemas to docs repo and regenerate"
    command: task graphql:schema:export # export schema/assets from source repo
    plugins:
      - theopenlane/git#v0.1.5:
          repository: git@github.com:theopenlane/docs.git # docs repo target
          branch-prefix: sync-docs
          sync:
            - from: docs/graphql/schema.graphql
              to: content/reference/schema.graphql
              type: file
            - from: docs/graphql/examples
              to: content/reference/examples
              type: dir
              delete: true # remove docs examples no longer present in source
          target-run:
            - |
              # regenerate docs in target repo
              npm ci
              npm run docs:generate
          commit-message: "docs: refresh graphql schema and examples (#{{BUILD_NUMBER}})"
          pr:
            title: "Docs refresh from core GraphQL schema (Build #{{BUILD_NUMBER}})"
```

## Hook Behavior

- `environment`: sets plugin defaults
- `pre-command`: validates configuration and required dependencies
- `command`: runs workflow when `execute-phase: command`
- `post-command`: runs workflow when `execute-phase: post-command` (default)

Use `post-command` for generate-then-sync pipelines.

## Configuration

### enabled (optional, default `true`)
Enable/disable plugin execution.

### execute-phase (optional, default `post-command`)
One of `command` or `post-command`.

### skip-on-command-failure (optional, default `true`)
Only applies to `post-command`. Skips automation when step command failed.

### repository (required)
Target repository URL or slug.

### base-branch (optional, default `main`)
Base branch used when creating a new working branch.

### preset (optional, default `custom`)
`custom` or `helm-sync`.

`helm-sync` defaults:
- `sync.type` to `merge-yaml` when omitted
- `source-root` to `config`
- `target-root` to `charts/<chart-name>` when `chart-name` is set, otherwise `charts`

### chart-name (optional)
Used by `preset: helm-sync` to derive default `target-root`.

### source-root / target-root (optional)
Prefix applied to relative `sync.from` / `sync.to` values.

### base-merge-target-path (optional)
Default merge target key for `merge-yaml` entries.

### base-merge-source-path (optional)
Default merge source expression for `merge-yaml` entries.

### branch (optional)
Explicit branch name. If unset, branch is generated from `branch-prefix`/`branch-suffix`.

### branch-prefix / branch-suffix (optional)
Used to construct dynamic branch names.

### user.name / user.email (optional)
Git identity for commits.

### auth.mode (optional, default `ssh`)
`ssh` or `https-token`.

### auth.token-env (optional, default `GITHUB_TOKEN`)
Token env var used when `auth.mode: https-token`.

### auth.token-user (optional, default `x-access-token`)
Username part for HTTPS token auth.

### artifact-download (optional)
Download Buildkite artifacts into source workspace before sync.

- `pattern` (required)
- `destination` (optional, default `.`)
- `step` (optional)

### source-directory (optional)
Base directory for relative `sync.from` paths.

### run / source-run (optional)
Commands executed in source workspace.

### target-run (optional)
Commands executed in cloned target repository via `bash -lc`.
Pipes, redirects, and multiline commands are supported (use YAML block scalars).

### sync (optional)
List of sync operations.

- Common fields:
- `from` (optional for `merge-yaml` when `merge-source-env` is set)
- `to` (required unless same as `from`)
- `required` (optional, default `true`)

- `type: auto | file | dir | merge-yaml`

- For `dir`:
- `delete` (optional, default `false`)
- When `true`, destination contents are made to match source (stale files are removed).

- For `merge-yaml`:
- `merge-target-path` (required unless `base-merge-target-path` resolves it)
- `merge-target-suffix` (optional; appended to `base-merge-target-path`)
- `merge-source-path` (optional, default `.`)
- `merge-source-env` (optional)
- `merge-delete-paths` (optional list of YAML paths to delete after merge)

### add (optional)
Explicit pathspecs for `git add -A`. Defaults to all changes.

### commit-message (optional)
Commit message template.

### commit-signoff / commit-gpg-sign (optional)
Enable `--signoff` and/or `--gpg-sign` on commit.

### push-force-with-lease (optional, default `false`)
Push with `--force-with-lease`.

### fail-on-no-changes (optional, default `false`)
Fail build when no staged changes were detected.

### pr.* (optional)
PR settings (`enabled`, `repo`, `base`, `title`, `body`, `body-file`, `draft`, `update-existing`, `labels`, `reviewers`, `assignees`, source PR linking options).

### slack.* (optional)
Slack settings (`enabled`, `webhook-env`, `template-file`, `template-inline`, `notify-on-no-changes`, `fail-on-error`).

### template-vars / pr.vars / slack.vars (optional)
Custom template vars exposed as env-expanded placeholders.

## Templates

This plugin ships reusable templates copied from your existing automation flow:

- `templates/github/*.md`
- `templates/slack/*.json`

Default fallbacks:

- PR body: `templates/github/default-pr.md`
- Slack payload: `templates/slack/default-notification.json`

## Template Variables

Built-ins include:

- `{{BUILD_ID}}`, `{{BUILD_NUMBER}}`, `{{BUILD_URL}}`, `{{PIPELINE_NAME}}`, `{{PIPELINE_SLUG}}`, `{{BUILD_CREATOR}}`
- `{{SOURCE_REPO_URL}}`, `{{SOURCE_REPO}}`, `{{SOURCE_BRANCH}}`, `{{SOURCE_COMMIT}}`, `{{SOURCE_COMMIT_SHORT}}`, `{{SOURCE_PR_NUMBER}}`
- `{{TARGET_REPOSITORY}}`, `{{TARGET_REPO}}`, `{{TARGET_BASE_BRANCH}}`, `{{TARGET_BRANCH}}`, `{{TARGET_PR_URL}}`
- `{{CHANGED_FILES}}`, `{{CHANGE_SUMMARY}}`

## Developing

```bash
task ci
```

or

```bash
./scripts/test
```
