# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

Resolve `<origin-repo>` from `git remote get-url origin` before using `gh`.
Always pass `--repo <origin-repo>` explicitly: a clone with both `origin` and
`upstream` can otherwise make `gh` select the read-only upstream repository.

- **Create an issue**: `gh issue create --repo <origin-repo> --title "..." --body "..."`.
- **Read an issue**: `gh issue view <number> --repo <origin-repo> --comments`, including labels and relevant comments.
- **List issues**: `gh issue list --repo <origin-repo> --state open --json number,title,body,labels,comments` with suitable label and state filters.
- **Comment on an issue**: `gh issue comment <number> --repo <origin-repo> --body "..."`.
- **Apply or remove labels**: `gh issue edit <number> --repo <origin-repo> --add-label "..."` or `--remove-label "..."`.
- **Close an issue**: `gh issue close <number> --repo <origin-repo> --comment "..."`.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub shares one number space across issues and pull requests. Resolve an
ambiguous `#<number>` with `gh pr view <number> --repo <origin-repo>` and fall
back to `gh issue view <number> --repo <origin-repo>`.

## Publishing

When a skill says to publish to the issue tracker, create a GitHub issue. When it says to fetch the relevant ticket, read the issue and its comments before acting.

## Wayfinding operations

- A wayfinder map is one issue labelled `wayfinder:map`.
- Child tickets use GitHub sub-issues when available and `wayfinder:<type>` labels.
- Represent blocking edges with GitHub issue dependencies when available; otherwise use a `Blocked by: #<number>` line.
- Claim a ticket by assigning it to the current GitHub user.
- Resolve a ticket with a cited answer comment, then close it and update the parent map.
