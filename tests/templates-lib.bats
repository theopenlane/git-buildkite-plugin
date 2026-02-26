#!/usr/bin/env bats

@test "load_template converts escaped newline sequences in substitutions" {
  template_file="$BATS_TEST_TMPDIR/template.md"
  cat > "$template_file" <<'TPL'
## Changes
{{CHANGE_SUMMARY}}
TPL

  source hooks/lib/templates.sh
  rendered=$(load_template "$template_file" "CHANGE_SUMMARY=\\n- first\\n- second")

  [[ "$rendered" == *$'\n- first\n- second'* ]]
  [[ "$rendered" != *"\\n- first\\n- second"* ]]
}

@test "render_template_file injects common build variables" {
  template_file="$BATS_TEST_TMPDIR/template.md"
  cat > "$template_file" <<'TPL'
Build: {{BUILD_NUMBER}}
Repo: {{SOURCE_REPO}}
PR: {{TARGET_PR_URL}}
TPL

  export BUILDKITE_BUILD_NUMBER=42
  export BUILDKITE_REPO="git@github.com:theopenlane/core.git"
  export TARGET_PR_URL="https://github.com/theopenlane/openlane-infra/pull/123"

  source hooks/lib/common.sh
  source hooks/lib/templates.sh

  rendered=$(render_template_file "$template_file" "pr")

  [[ "$rendered" == *"Build: 42"* ]]
  [[ "$rendered" == *"Repo: theopenlane/core"* ]]
  [[ "$rendered" == *"PR: https://github.com/theopenlane/openlane-infra/pull/123"* ]]
}

@test "SOURCE_LINK is a PR link when build is from a pull request" {
  template_file="$BATS_TEST_TMPDIR/template.md"
  cat > "$template_file" <<'TPL'
Source: {{SOURCE_LINK}}
PR_URL: {{SOURCE_PR_URL}}
TPL

  export BUILDKITE_REPO="git@github.com:theopenlane/core.git"
  export BUILDKITE_PULL_REQUEST="42"
  export BUILDKITE_COMMIT="abc123def456"

  source hooks/lib/common.sh
  source hooks/lib/templates.sh

  rendered=$(render_template_file "$template_file" "pr")

  [[ "$rendered" == *"[PR #42](https://github.com/theopenlane/core/pull/42)"* ]]
  [[ "$rendered" == *"PR_URL: https://github.com/theopenlane/core/pull/42"* ]]
}

@test "SOURCE_LINK is a commit link when build is from main" {
  template_file="$BATS_TEST_TMPDIR/template.md"
  cat > "$template_file" <<'TPL'
Source: {{SOURCE_LINK}}
Commit_URL: {{SOURCE_COMMIT_URL}}
Commit_Full: {{SOURCE_COMMIT_FULL}}
TPL

  export BUILDKITE_REPO="git@github.com:theopenlane/core.git"
  export BUILDKITE_PULL_REQUEST="false"
  export BUILDKITE_COMMIT="abc123def456abcd"

  source hooks/lib/common.sh
  source hooks/lib/templates.sh

  rendered=$(render_template_file "$template_file" "pr")

  [[ "$rendered" == *"[abc123de](https://github.com/theopenlane/core/commit/abc123def456abcd)"* ]]
  [[ "$rendered" == *"Commit_URL: https://github.com/theopenlane/core/commit/abc123def456abcd"* ]]
  [[ "$rendered" == *"Commit_Full: abc123def456abcd"* ]]
}

@test "SOURCE_LINK is empty when repo and commit are unset" {
  template_file="$BATS_TEST_TMPDIR/template.md"
  cat > "$template_file" <<'TPL'
Source: {{SOURCE_LINK}}
TPL

  unset BUILDKITE_REPO
  unset BUILDKITE_PULL_REQUEST
  unset BUILDKITE_COMMIT

  source hooks/lib/common.sh
  source hooks/lib/templates.sh

  rendered=$(render_template_file "$template_file" "pr")

  [[ "$rendered" == *"Source: "* ]]
  [[ "$rendered" != *"github.com"* ]]
}

@test "BUILD_URL is injected as a link variable" {
  template_file="$BATS_TEST_TMPDIR/template.md"
  cat > "$template_file" <<'TPL'
Build: [Build #{{BUILD_NUMBER}}]({{BUILD_URL}})
TPL

  export BUILDKITE_BUILD_NUMBER=77
  export BUILDKITE_BUILD_URL="https://buildkite.com/theopenlane/core/builds/77"

  source hooks/lib/common.sh
  source hooks/lib/templates.sh

  rendered=$(render_template_file "$template_file" "pr")

  [[ "$rendered" == *"[Build #77](https://buildkite.com/theopenlane/core/builds/77)"* ]]
}
