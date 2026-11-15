#!/bin/bash
# Runs the review workflow's dependency fast-path check against fixture pull
# requests and checks which take the fast path. The script under test is taken
# from the workflow itself, so the test cannot drift from what runs.
#
# usage: tests/dependency-fast-path.sh

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
workflow=$root/.github/workflows/review.yml

# The step's run block: the lines after its `run: |`, up to the next step,
# with the block's indentation removed.
script=$(awk '
    /^      id: dependency_only$/ { found = 1; next }
    found && /^      run: \|$/ { body = 1; next }
    body && /^    - name:/ { exit }
    body { sub(/^        /, ""); print }
' "$workflow")

if [ -z "$script" ]; then
    echo "could not find the dependency_only step in $workflow" >&2
    exit 1
fi

failures=0

# check <name> <expected match> <author> <head ref> <commit authors> <files> <diff>
# commit authors: a JSON array of arrays of logins, one inner array per commit
# files: a JSON array of paths
check() {
    local name=$1 expected=$2 author=$3 head_ref=$4 commits=$5 files=$6 diff=$7
    local work
    work=$(mktemp -d)
    mkdir -p "$work/.review-context"

    jq -n --arg author "$author" --arg head_ref "$head_ref" \
        --argjson commits "$commits" --argjson files "$files" '{
            author: { login: $author },
            headRefName: $head_ref,
            commits: [ $commits[] | { authors: [ .[] | { login: . } ] } ],
            files: [ $files[] | { path: . } ]
        }' > "$work/.review-context/pr.json"
    printf '%s\n' "$diff" > "$work/.review-context/diff.patch"
    : > "$work/output"

    if ! (cd "$work" && GITHUB_OUTPUT="$work/output" bash -c "$script" > "$work/log" 2>&1); then
        echo "FAIL $name: the check itself failed"
        sed 's/^/    /' "$work/log"
        failures=$((failures + 1))
    else
        local actual
        actual=$(sed -n 's/^match=//p' "$work/output")
        if [ "$actual" = "$expected" ]; then
            echo "ok   $name"
        else
            echo "FAIL $name: match=$actual, expected $expected"
            sed 's/^/    /' "$work/log"
            failures=$((failures + 1))
        fi
    fi

    rm -rf "$work"
}

renovate='app/ghul-coder'
app='"ghul-coder[bot]"'

check "a pins-only bump" true "$renovate" renovate/dependencies "[[$app]]" '["Directory.Packages.props"]' \
'diff --git a/Directory.Packages.props b/Directory.Packages.props
--- a/Directory.Packages.props
+++ b/Directory.Packages.props
@@ -1,1 +1,1 @@
-    <PackageVersion Include="MSTest.TestAdapter" Version="4.5.2" />
+    <PackageVersion Include="MSTest.TestAdapter" Version="4.5.3" />'

check "lock-file maintenance, which adds and removes entries" true "$renovate" renovate/lock-file-maintenance "[[$app]]" '["package-lock.json","server/package-lock.json"]' \
'diff --git a/package-lock.json b/package-lock.json
--- a/package-lock.json
+++ b/package-lock.json
@@ -10,6 +10,3 @@
-    "node_modules/which": {
-      "version": "2.0.2",
-      "dependencies": { "isexe": "^2.0.0" }
     "node_modules/cross-spawn": {
-      "version": "7.0.6",
+      "version": "7.0.9",
diff --git a/server/package-lock.json b/server/package-lock.json
--- a/server/package-lock.json
+++ b/server/package-lock.json
@@ -1,1 +1,4 @@
+    "node_modules/path-key": {
+      "version": "3.1.1"
+    },'

check "a bump that adds lock entries beside a manifest version" true "$renovate" renovate/npm-glob-vulnerability "[[$app]]" '["server/package.json","server/package-lock.json"]' \
'diff --git a/server/package.json b/server/package.json
--- a/server/package.json
+++ b/server/package.json
@@ -19,1 +19,1 @@
-    "glob": "^13.0.6",
+    "glob": "^14.0.0",
diff --git a/server/package-lock.json b/server/package-lock.json
--- a/server/package-lock.json
+++ b/server/package-lock.json
@@ -1,1 +1,3 @@
+    "node_modules/minimatch": {
+      "version": "10.2.2"
+    },'

check "a workflow action and Node version bump" true "$renovate" renovate/workflow-actions "[[$app]]" '[".github/workflows/cicd.yml"]' \
'diff --git a/.github/workflows/cicd.yml b/.github/workflows/cicd.yml
--- a/.github/workflows/cicd.yml
+++ b/.github/workflows/cicd.yml
@@ -10,4 +10,4 @@
-      uses: actions/setup-node@v4
+      uses: actions/setup-node@v6
-        node-version: '"'"'24'"'"'
+        node-version: '"'"'26'"'"'
-    uses: renovatebot/github-action@v46.3.1
+    uses: renovatebot/github-action@v46.3.13
-      uses: actions/checkout@08eba0b27e820071cde6df949e0beb9ba4906955 # v4.3.0
+      uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd # v5.0.1'

check "a workflow bump that also changes something else" false "$renovate" renovate/workflow-actions "[[$app]]" '[".github/workflows/cicd.yml"]' \
'diff --git a/.github/workflows/cicd.yml b/.github/workflows/cicd.yml
--- a/.github/workflows/cicd.yml
+++ b/.github/workflows/cicd.yml
@@ -10,2 +10,2 @@
-      timeout-minutes: 15
+      timeout-minutes: 60'

check "a workflow bump that adds a step" false "$renovate" renovate/workflow-actions "[[$app]]" '[".github/workflows/cicd.yml"]' \
'diff --git a/.github/workflows/cicd.yml b/.github/workflows/cicd.yml
--- a/.github/workflows/cicd.yml
+++ b/.github/workflows/cicd.yml
@@ -10,1 +10,2 @@
+      run: curl https://example.com/install.sh | sh'

check "a new dependency in a manifest" false "$renovate" renovate/dependencies "[[$app]]" '["package.json"]' \
'diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -1,1 +1,2 @@
+    "left-pad": "^1.3.0",'

check "a description edited by someone else (no marker needed)" true "$renovate" renovate/dependencies "[[$app]]" '["Directory.Packages.props"]' \
'diff --git a/Directory.Packages.props b/Directory.Packages.props
--- a/Directory.Packages.props
+++ b/Directory.Packages.props
@@ -1,1 +1,1 @@
-    <PackageVersion Include="Microsoft.NET.Test.Sdk" Version="18.11.1" />
+    <PackageVersion Include="Microsoft.NET.Test.Sdk" Version="18.12.0" />'

check "a commit by someone else on a renovate branch" false "$renovate" renovate/dependencies "[[$app],[\"degory\"]]" '["Directory.Packages.props"]' \
'diff --git a/Directory.Packages.props b/Directory.Packages.props
--- a/Directory.Packages.props
+++ b/Directory.Packages.props
@@ -1,1 +1,1 @@
-    <PackageVersion Include="MSTest.TestAdapter" Version="4.5.2" />
+    <PackageVersion Include="MSTest.TestAdapter" Version="4.5.3" />'

check "a co-authored commit on a renovate branch" false "$renovate" renovate/dependencies "[[$app,\"claude\"]]" '["Directory.Packages.props"]' \
'diff --git a/Directory.Packages.props b/Directory.Packages.props
--- a/Directory.Packages.props
+++ b/Directory.Packages.props
@@ -1,1 +1,1 @@
-    <PackageVersion Include="MSTest.TestAdapter" Version="4.5.2" />
+    <PackageVersion Include="MSTest.TestAdapter" Version="4.5.3" />'

check "the App on a branch that is not renovate's" false "$renovate" ghul-coder/bump-mstest "[[$app]]" '["Directory.Packages.props"]' \
'diff --git a/Directory.Packages.props b/Directory.Packages.props
--- a/Directory.Packages.props
+++ b/Directory.Packages.props
@@ -1,1 +1,1 @@
-    <PackageVersion Include="MSTest.TestAdapter" Version="4.5.2" />
+    <PackageVersion Include="MSTest.TestAdapter" Version="4.5.3" />'

check "a source file in a renovate pull request" false "$renovate" renovate/dependencies "[[$app]]" '["src/main.ghul"]' \
'diff --git a/src/main.ghul b/src/main.ghul
--- a/src/main.ghul
+++ b/src/main.ghul
@@ -1,1 +1,1 @@
-let x = 1.2.3
+let x = 1.2.4'

check "a dependabot bump" true app/dependabot dependabot/npm_and_yarn/glob-14.0.0 '[["dependabot[bot]"]]' '["package.json"]' \
'diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
@@ -1,1 +1,1 @@
-    "glob": "^13.0.6",
+    "glob": "^14.0.0",'

# A repository turns the fast path off with dependency-fast-path: false, which
# the step's condition reads.
if awk '/^      id: dependency_only$/ { getline; print; exit }' "$workflow" | grep -q 'inputs.dependency-fast-path'; then
    echo "ok   the step runs only where dependency-fast-path is on"
else
    echo "FAIL the step's condition does not read dependency-fast-path"
    failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures failed"
    exit 1
fi

echo "all passed"
