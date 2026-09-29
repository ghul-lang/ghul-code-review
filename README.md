# ghul-code-review

Reusable GitHub Actions workflow that runs the [Claude Code](https://claude.com/claude-code)
CLI on a pull request and posts the result as a single formal PR review — an
approval when the diff is clean, or a request-changes review with
line-anchored inline findings otherwise.

## What it does

Calls `claude -p --output-format stream-json`, captures the event stream for
the artifact and the scorecard, and kills the process if it stops producing
output. The review brief is supplied by the calling workflow.

The reviewer is always the Claude Code CLI; which model actually serves the
request is a matter of which **provider** it points at (see 'Providers'
below). Anthropic's own API, Alibaba's Qwen Token Plan, and OpenRouter all
speak Claude Code's native protocol, so the same CLI, tool policy and prompt
work unmodified against any of them — only the base URL, auth token and
default model differ.

The review runs against a wall-clock budget and a single reviewer. Its tool
policy is an explicit allowlist/denylist pair (`allowed-tools` /
`disallowed-tools`): bash is scoped to `gh pr diff` / `gh pr view` / `gh pr
review` / `gh api` / `date` / `git log` / `wc`, and subagent tools (`Agent`,
`Workflow`, `Task`) are denied outright. A review that fans out to subagents
multiplies its token cost and exhausts the job timeout before it posts
anything, which leaves the PR blocked on a review nobody can read.

## When the model is not run

Three gates run before the model is ever started, in this order. Each is a
whole run's cost avoided, and none of them leaves the PR without a review.

- **A human has approved.** See 'Human override' below.
- **A mechanical dependency-only bot PR.** From Renovate or Dependabot,
  touching version-pin files only, and changing nothing in them but version
  numbers and content hashes: every changed line has to be a changed line of
  the same shape, so an added dependency or an added build step goes to the
  full review. Approved directly. A caller turns this off with
  `dependency-fast-path: false`.
- **The reviewed content has not changed since the last review.** A rebase, a
  merge from the base branch, or a force-push that only rewrites history
  produces the same diff, and the last review already covers it — so that
  review's verdict is re-posted rather than re-derived.

The last of those is a fingerprint over the diff with hunk headers and blob
hashes normalised out, so a rebase that only shifts line numbers still
matches. The title and body are in it too, because they are reviewed as well:
a finding about the description is cleared by editing the description rather
than the diff, and over the diff alone that edit would leave the fingerprint
unchanged — the standing verdict would be re-posted and the finding could
never be cleared. The review carries it in an HTML comment at the end of its body,
which GitHub does not render, so it is invisible to readers and readable from
the reviews API.

Each of the three says so in the review body, so which one fired is visible
on the pull request without opening the run log: a full review opens
**Reviewed** - no findings, a dependency-only approval opens **Not
reviewed**, and a re-stated verdict opens **Not re-reviewed**.

**It re-states the standing verdict rather than staying silent.** A previous
approval is re-posted as an approval; a previous request-changes as a
body-only request-changes saying the findings still stand (the inline
findings are already on the PR, and re-posting them would duplicate every one
on each rebase). That costs one API call and no model time, and it means the
gate does not depend on how the calling repo treats older reviews: where
branch protection dismisses stale reviews, or requires the approval to be of
the latest push, a silent skip would leave the PR stuck on a review nobody
was going to run again.

Every uncertain direction fails open. A review whose body carries no marker —
one posted before this existed, or a run where the model dropped it — does not
match, and the review runs as normal.

## The time budget

The review is given a working budget (`post-findings-after-minutes`) and is
killed `hard-stop-grace-seconds` after it expires.

**The budget is pushed, not pulled.** A `PostToolUse` hook fires on every tool
call and returns the time left as a duration — `Time budget: 2m 31s remaining.`
— through `hookSpecificOutput.additionalContext`, the only hook channel that
reaches the model. The wording escalates on its own: under two minutes it says
to stop investigating and start writing up, under thirty seconds it says to
post now, and past zero it says the run is about to be killed.

Earlier versions instead told the review the wall-clock time it had to post by
and left it to check the clock. That does not work, and the failure is not that
the model forgot: a run that overran by five minutes had checked the clock and
said in its own output that it was over budget, and kept reading anyway.
Measuring elapsed time is work the model has to remember to do, and a deadline
it has to convert into a decision every time it looks. A duration it is handed
is neither.

The kill is what makes the budget real. The idle watchdog cannot do it — it
fires on stdout silence, and a model that streams thinking tokens is never
silent — so before the deadline stop existed, nothing at all reacted to the
clock between the budget expiring and the job timeout.

A deadline kill does not retry. A second attempt would spend the same budget
reading the same diff and reach the same place, and two full budgets do not fit
inside `job-timeout-minutes` — and a job killed at *that* timeout skips the
salvage step, which is the one thing that still gets the findings onto the PR.

## When a review is killed

The deadline stop, the idle watchdog, the job timeout, or a stalled provider
can kill a run before it posts. That used to lose the review entirely: the check failed with
no feedback, and the author had to push again — paying a full CI cycle — to
find out what it would have said.

The review is asked to write its findings to `review.json` as it reaches them
rather than only at the end, and a salvage step posts whatever is in that file
when a run dies. A salvaged review is always `REQUEST_CHANGES`, never an
approval — an approval that was never actually reached is worse than silence,
because auto-merge acts on it — and it says at the top that it did not cover
the whole diff. The job stays failed either way: the salvage is feedback for
the author, not a verdict for the merge gate.

## PR description checks

The description becomes the squash-merge commit message and the changelog
entry, so what it says ships permanently. The mechanical conventions — no
`## Summary` heading, no Claude Code footer or session URL, no
`Co-authored-by:` trailer in the body, no local test results, no internal
labels, no private references or local paths, no inert `#minor` marker, no
first line repeating the title, at least one `Enhancements:` / `Bugs fixed:` /
`Technical:` section, and those labels written as plain text rather than
marked up as headings or in bold — are checked by grep inside the review job,
before the model starts.

Claude Code cloud sessions append an advert to every pull request they open -
a `🤖 Generated with [Claude Code]` line and a `claude.ai/code/session_` link -
whatever the session is told. That is not reported: it is **removed from the
pull request** before any gate runs, the human-approval skip included, since
the body ships however the review is decided. Only whole lines that are
nothing but the advert go, with a `---` rule their removal leaves dangling at
the end. The edit is made with the workflow's own token, so it does not start
another run; if it fails, the body is left alone and the grep reports the
advert as before.

The shape of the description as a whole is not checked here. Enforcing it
after a run has started costs a CI cycle and a review cycle to say something
that was knowable before either began, so it belongs at the point the
description is written rather than in the review.

Findings are **seeded into `review.json`** rather than posted on their own, so
they ride out with whatever the model finds in the diff and the author fixes
both together. Posting them alone without running the model would cost the
same round it saves: the diff would still be unreviewed, and the code findings
would arrive a cycle later. The model is told the seeded findings are not its
to re-judge, not to spend a finding on anything they already cover, and not to
approve while they exist.

Because the model does the posting, nothing upstream can force what it posts —
so a following step checks the posted review actually requests changes, and
posts the findings itself if not. An approval over a bad description would
ship that description, immediately, with auto-merge armed.

This is why the checks are not a separate job: a red advisory check is seen by
nobody in an automated review flow, and making it a *required* status check
would need a branch-protection change and would hard-block a merge on an
eleven-grep heuristic. Riding in the review uses the approval gate that is
already there.

Set `require-description-section: false` for a repo that does not generate
release notes from the squash-merge message; the other checks apply either way.

## Providers

| `provider` | Endpoint | Auth secret |
|---|---|---|
| `anthropic` | Anthropic's own API | `claude-oauth-token` |
| `qwen` | Alibaba Qwen Token Plan (Anthropic-compatible) | `qwen-auth-token` |
| `openrouter` | OpenRouter (Anthropic-compatible) | `openrouter-auth-token` |
| `zai` | Z.AI GLM Coding Plan (Anthropic-compatible) | `zai-auth-token` |

Only the secret the resolved provider actually needs is read; the other three
can be absent or empty.

## Fleet-wide defaults (`fleet.json`)

Provider and tier are **fleet-wide by default, not per-repo**. Every run
fetches [`fleet.json`](./fleet.json) from this repo's own `main` branch — an
unauthenticated raw fetch, since this repo is public — for the live default
`provider` and `tier`, plus the tier→model mapping for each provider:

```json
{
  "provider": "anthropic",
  "tier": "medium",
  "models": {
    "anthropic": { "high": "claude-opus-5", "medium": "claude-sonnet-5", "low": "claude-haiku-4-5" },
    "qwen": { "high": "qwen3.8-max", "medium": "qwen3.7-max", "low": "qwen3.6-flash" },
    "openrouter": { "high": "z-ai/glm-5.3", "medium": "z-ai/glm-5.3-flash", "low": "z-ai/glm-5.3-flash" },
    "zai": { "high": "glm-5.3", "medium": "glm-5.3-flash", "low": "glm-5.3-flash" }
  }
}
```

**Editing this one file and pushing is the switch that moves every consumer
repo's next review run** — no per-repo commit, no per-repo variable. That's
the point: "switch everything over, I've run out of tokens on provider X" is
one edit here, not nine.

`tier` is a provider-independent quality/cost knob (`high` / `medium` / `low`)
rather than a literal model id, so the same tier concept survives a provider
switch — `tier: high` means "the best model this provider offers" whichever
provider is currently active, not a specific model name that stops making
sense once the provider changes.

Resolution order:
- `provider`: the `provider` input, else the calling repo's
  `CODE_REVIEW_PROVIDER` variable, else `fleet.json`'s `provider`, else
  `anthropic`.
- `tier`: the `tier` input, else `CODE_REVIEW_TIER`, else `fleet.json`'s
  `tier`, else `medium`.
- `model`: the `model` input if set (bypasses tier mapping entirely), else
  the calling repo's `CODE_REVIEW_MODEL` variable if set (same bypass), else
  `fleet.json`'s `models[provider][tier]`, else a small built-in fallback
  table baked into the workflow (used only if the fetch fails, or a tier
  isn't in `fleet.json`'s table yet).

The per-repo inputs and variables (`provider`/`tier`/`model` and their
`CODE_REVIEW_*` counterparts) exist to pin one repo away from the fleet
default: a different provider when a repo has reason to leave the shared
one, or one specific model while its pricing makes pinning worth it. They
are not the normal way to configure a repo; the normal case sets nothing and
follows `fleet.json`.

If the fetch fails (network hiccup, `fleet.json` briefly unparseable), the
run logs a warning and falls back to the workflow's own built-in
`anthropic`/`medium` default rather than failing every review across the
fleet over one bad fetch.

OpenRouter's `~anthropic/claude-*-latest` catalog entries route real Anthropic
models through OpenRouter's billing instead of Anthropic's, if that's ever
useful; any other OpenRouter catalog id (`z-ai/*`, `qwen/*`, `deepseek/*`, …)
works the same way, unofficially — OpenRouter only guarantees its
`anthropic/*` models over this protocol, but GLM, Qwen, DeepSeek, Kimi and
MiniMax models have worked in practice.

## Seeing what a review actually did

An approval is a few characters and says nothing about what was weighed to reach
it. So each run produces:

- **A scorecard in the job summary** — provider, model, duration, turns, tool
  calls and their names, subagent attempts, refused commands, cost, and
  whether a review was posted. Written per attempt as it finishes, so a run
  killed at the job timeout still leaves its numbers behind.
- **The full event stream as an artifact**, one file per attempt. The
  provider auth token in use (by its exact value) and token-shaped strings are
  redacted before upload, because artifacts are not covered by the secret
  masking that applies to the log.

A healthy run is tens of tool calls over a few minutes. Hundreds of tool calls,
any subagent attempt, or a run approaching the job timeout is the review
treating the PR as a programme of work rather than something to read.

## Usage

In a consumer repo, add a job that calls into this workflow:

```yaml
jobs:
  code_review:
    if: ${{ github.event_name == 'pull_request' && github.actor != 'dependabot[bot]' }}
    permissions:
      contents: read
      pull-requests: write
    uses: ghul-lang/ghul-code-review/.github/workflows/review.yml@v11
    with:
      prompt: |
        Review pull request #${{ github.event.pull_request.number }} on ${{ github.repository }}.

        Read other files only when surrounding context is needed.
        Group findings by severity (Bug / Concern / Nit).
    secrets:
      claude-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      qwen-auth-token: ${{ secrets.QWEN_AUTH_TOKEN }}
```

### Version tags

The current major tag floats. A non-breaking change merges to `main` and then
re-points it (`git tag -fa v11 -m "..." && git push -f origin v11`); consumer
repos pick the change up on their next run, with no rollout. A new major tag is
cut only for a breaking change - one whose inputs or contract force callers to
change - because that is the only change worth the coordinated bump of every
consumer.

Passing both secrets (when both are available) is what makes a fleet-wide
provider switch (edit `fleet.json`, push) free for this repo too — the
workflow only reads the one the resolved provider needs, so an unused secret
sitting there does nothing until `fleet.json` (or, rarely, a per-repo
override) asks for it.

The workflow owns the posting mechanics — it prepends runtime notes to the
prompt directing the model to approve when clean or post a request-changes
review with inline findings otherwise, so the caller's `prompt` only needs to
supply the review brief (what to flag), not how to post it.

It also owns the precision bar, which is fleet-wide rather than per-repo.
Every candidate finding is scored 0-100 against a fixed scale, and only those
at 80 or above are posted; the rest are dropped rather than softened into
asides. Alongside the scale is a list of things that are not findings however
true they are — a pre-existing issue, a real issue on a line the diff does not
touch, anything a compiler or test would catch, a nitpick a senior engineer
would not raise. Generating and then filtering turns out to be more reliable
than asking the model not to generate low-value findings in the first place,
because the filter is a separate judgement against an explicit bar.

The same section carries a short mandatory tail check — the PR description
against what the diff actually does, the VERSION file, and the repo's own
reference documentation. These are cheap, and they are the ones a review most
often leaves to a later round, which costs the author a whole CI cycle to
learn. Checking them is mandatory; reporting them is still subject to the 80
bar.

The `permissions:` block on the calling job is required: this workflow declares
`pull-requests: write` so it can post the review, and the caller must grant at
least that. Without it, GitHub fails the workflow at validation with
`The workflow is requesting 'pull-requests: write', but is only allowed 'pull-requests: none'`.

## What lives here vs. in the calling repo

The workflow prepends runtime notes to every prompt, covering everything that
does not vary by repo: what PR context is pre-fetched and where, how to post a
review, that the review runs in parallel with CI and should trust the diff,
what makes a finding worth raising, source-comment hygiene, PR-description
shape, and the versioning mechanism.

A calling repo's own brief should therefore carry only what is specific to it:
what the repo ships, who consumes it, the blast radius of a mistake, the risk
areas worth extra attention, and what counts as a breaking change there.

Restating any of the shared material in a repo brief is a defect rather than
redundancy. These notes are given *first* and the repo-specific brief second,
so the review reads the authoritative shared rules before anything the caller
supplies; a brief should carry only what is specific to its repo. A brief that
restates shared material is noise at best, and at worst contradicts the live
rules the review has already been given.

## Human override

Once a non-bot reviewer has approved a PR — at any point in its history, not
just its current state — every later run of this workflow skips the automated
review outright instead of re-running the reviewer on top of it. This holds even
across further pushes: nothing re-arms it for that PR.

The mechanism is skipping, not re-approving: the workflow simply doesn't post
a new review, so the bot's last review stays whatever it already was and can't
override the human reviewer's still-active approval in the aggregate review
decision. This relies on the calling repo's branch protection *not* dismissing
stale approvals on push — if it does, a human approval stops being active as
soon as the next commit lands, and this check will find it in `reviews.json`'s
history regardless but the PR will still need a fresh approval to merge.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `prompt` | (required) | The full review brief. |
| `provider` | `""` | `anthropic` / `qwen` / `openrouter` / `zai`. Empty (the normal case) resolves to `CODE_REVIEW_PROVIDER`, then `fleet.json`, then `anthropic`. See 'Fleet-wide defaults'. |
| `tier` | `""` | `high` / `medium` / `low`. Empty (the normal case) resolves to `CODE_REVIEW_TIER`, then `fleet.json`, then `medium`. |
| `model` | `""` | Explicit `--model` override, bypassing tier mapping entirely. Empty resolves to the calling repo's `CODE_REVIEW_MODEL`, then `tier`. |
| `allowed-tools` | `Bash(gh pr diff:*),Bash(gh pr view:*),Bash(gh pr review:*),Bash(gh api:*),Bash(date:*),Bash(git log:*),Bash(wc:*),Read,Write,Glob,Grep` | `--allowedTools` argument. |
| `disallowed-tools` | `Agent Workflow Task` | `--disallowedTools` argument. Denies subagent fan-out outright — it multiplies token cost and burns the wall-clock budget before anything posts. |
| `runner` | `ubicloud-standard-2` | GitHub Actions runner label the review job runs on. A small runner suffices — the job waits on the model rather than building. Defaults to a small Ubicloud runner; GitHub's own runners don't always reach the Qwen Token Plan or OpenRouter endpoints. |
| `idle-timeout-seconds` | `180` | Kill the reviewer after this many seconds of stdout silence; must exceed the model's time-to-first-token on a cold start. |
| `max-attempts` | `1` | Attempt cap. A retry re-reads the PR from a fresh context and competes for the same job budget, so the default is to fail the check and let the next push re-trigger the review. |
| `post-findings-after-minutes` | `4` | Working budget for the review: post by this point, whatever depth was reached. Pushed into the model's context as a remaining duration after every tool call — see 'The time budget'. |
| `hard-stop-grace-seconds` | `90` | Extra time after that budget before the run is killed outright. Whatever `review.json` holds at that moment is posted as a partial review. |
| `transcript-retention-days` | `14` | Retention for the uploaded transcript. |
| `claude-version` | `2.1.221` | Claude CLI version installed on the runner. |
| `job-timeout-minutes` | `8` | Outer cap on the whole job. A backstop for a wedged run, not the working budget — a run that reaches it is killed and posts nothing, because the salvage step never runs. |
| `gh-app-id` | `""` | GitHub App id. With `gh-app-private-key`, the review posts under that App's installation identity instead of `github-actions[bot]`. |
| `ghul-reference` | `false` | Fetch `GHUL.md` from `ghul-lang/ghul` main into the workspace root, for repos whose diffs contain ghūl source. |
| `style-reference` | `false` | Fetch `STYLE.md` from `ghul-lang/ghul-style` main into the workspace root, for repos carrying human-facing prose or example code. Needs `gh-app-id`, and `ghul-style` in `extra-repositories`. |
| `dependency-fast-path` | `true` | Approve a dependency bot's version-only change without running the model (see 'When the model is not run'). Turn off for a repo that judges its own bumps or wants every change read. |
| `maintainer-review` | `false` | Let the review brief name changes that need the maintainer: such a change gets a request-changes review saying so, never an approval, however routine it looks. Off, the prompt says nothing about it, so no other repo's review holds a PR that way. |
| `extra-repositories` | `""` | Additional repository names (same owner) the App token should reach, for prompts that read a file from a sibling repo. The calling repository is always included. |

## Secrets

| Secret | Required | Meaning |
|---|---|---|
| `claude-oauth-token` | no | OAuth token for Anthropic's own API. Required when the resolved provider is `anthropic`. |
| `qwen-auth-token` | no | API key for Alibaba's Qwen Token Plan endpoint. Required when the resolved provider is `qwen`. |
| `openrouter-auth-token` | no | API key for OpenRouter. Required when the resolved provider is `openrouter`. |
| `zai-auth-token` | no | API key for Z.AI's GLM Coding Plan endpoint. Required when the resolved provider is `zai`. |
| `gh-app-private-key` | no | PEM private key for `gh-app-id`. Required only when that is set. |

None are individually `required: true` because which one is needed depends on
`provider`; the workflow fails fast with a clear error if the resolved
provider's secret is empty, rather than letting the CLI fail confusingly
against no credentials.

## Migrating from v3

v4 replaces the OpenCode/Qwen driver with the Claude Code CLI, generalized to
run against any of three providers (see 'Providers'). The review posture,
posting mechanics, pre-fetched context, human-override skip and scorecard
shape are unchanged. Consumer changes:

- Bump the `uses:` ref from `@v3` to `@v4`.
- Replace the `opencode-api-key` secret with `qwen-auth-token` (same
  underlying key — Alibaba's Qwen Token Plan token) and add
  `claude-oauth-token` alongside it if the repo has a Claude OAuth token to
  offer. Passing both is what makes provider switching free afterwards.
- The `model` input is no longer opencode's `provider/model` form — it's a
  bare model id, and now an explicit override that bypasses the new `tier`
  mechanism entirely. Leave it unset (the normal case) and use `tier` (or
  nothing at all, deferring to `fleet.json`) instead.
- `provider` and `model`/`tier` are now fleet-wide by default via
  [`fleet.json`](./fleet.json) on this repo's `main`, not something each
  consumer sets. See 'Fleet-wide defaults' — nothing to change here unless a
  repo was pinning a specific `model` value, which now needs to move to
  `tier` or stay as an explicit `model` override.
- `opencode-version` is gone, replaced by `claude-version`.
- `allowed-tools` and `disallowed-tools` are back as inputs (the OpenCode
  driver's `OPENCODE_PERMISSION` config is gone; the Claude CLI use
  `--allowedTools` / `--disallowedTools` instead).
- The job's display name changed from `OpenCode` to `Code review` (a
  provider-neutral name, so it doesn't need to change again on the next
  provider swap). It isn't listed in any consumer repo's required status
  checks today, but double-check before relying on that.
- The scorecard reports cost again (it's meaningful once more now that a run
  can be against Anthropic's own paid API, not just a zero-priced endpoint).
