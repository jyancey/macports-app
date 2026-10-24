# Issue tracker: Gitea (local forge)

Issues and specs for this repo live as issues on the local Gitea server at `http://localhost:3000`, repo `john/macports-app` (the `origin` remote). Use the [`tea`](https://gitea.com/gitea/tea) CLI for all operations. The `github` remote is a mirror only, so don't file issues there.

Always pass `--login john --repo john/macports-app` (shortened to `$T` below). Inside the clone, `tea` doesn't reliably match a login to the repo. If `tea` reports "invalid username, password or token" from an agent's shell, run the command in the user's own terminal, where it authenticates.

## Conventions

- **Create an issue**: `tea issues create $T --title "..." --description-file -` with a heredoc for multi-line bodies. Add `--labels a,b` to label at creation.
- **Read an issue**: `tea issues $T <number> --comments`. For machine-readable output, use `tea api $T '/repos/{owner}/{repo}/issues/<number>'` and `.../issues/<number>/comments`.
- **List issues**: `tea issues ls $T --state open --labels <label> --fields index,title,labels,assignees,body --output json`.
- **Comment on an issue**: `tea comment $T <number> "..."`
- **Apply / remove labels**: `tea issues edit $T <number> --add-labels "..."` / `--remove-labels "..."`
- **Close**: `tea issues close` takes no comment, so post the explanation first with `tea comment`, then `tea issues close $T <number>`.
- **Raw API** (anything `tea` lacks): `tea api $T [-X METHOD] [-f key=value | -d @file] '/repos/{owner}/{repo}/...'`.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues: `tea pulls $T <number>` to read, `tea issues ls $T --kind pulls` to list, and `tea comment` / `tea issues edit --add-labels` / `tea pulls close` to act. Gitea shares one number space across issues and PRs, as GitHub does.

## When a skill says "publish to the issue tracker"

Create a Gitea issue as in **Create an issue** above.

## When a skill says "fetch the relevant ticket"

Read it as in **Read an issue** above.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: an issue with `Part of #<map>` at the top of its body, listed in a task list in the map body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: Gitea's native issue dependencies: `tea api $T -X POST '/repos/{owner}/{repo}/issues/<child>/dependencies' -f owner=john -f repo=macports-app -F index=<blocker>`. Read them with `GET .../issues/<child>/dependencies`. If dependencies are disabled on the server, put a `Blocked by: #<n>, #<n>` line at the top of the child body instead. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children, drop any with an open blocker or an assignee; first in map order wins.
- **Claim**: `tea issues edit $T <n> --add-assignees john`, the session's first write.
- **Resolve**: `tea comment $T <n> "<answer>"`, then `tea issues close $T <n>`, then append a context pointer (gist + link) to the map's Decisions-so-far.
