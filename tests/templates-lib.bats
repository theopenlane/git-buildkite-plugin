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
