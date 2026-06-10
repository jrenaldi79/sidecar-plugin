# Git and the Cowork sandbox

How version control works for this repo, given where the code lives and what
the Cowork sandbox can (and can't) do.

## Why git runs on the host, not inside Cowork

The Cowork sandbox is an ephemeral Linux VM that **doesn't ship with git** —
and since each session gets a fresh VM, installing it mid-session doesn't
persist. On top of that, we've seen the host-mounted folder block `unlink`
operations, which breaks git's lock-file lifecycle even when git is present.

So the workflow splits in two:

- **Editing happens in Cowork.** File changes Claude makes in a chat
  (Read/Write/Edit tools) land directly on disk in your mounted folder —
  there's no sync step.
- **Version control happens on the host.** Run git from a regular terminal on
  your machine, or from a local Claude Code session (which runs on the host,
  not in the sandbox, and has full `git` + `gh`).

The mounted folder is the bridge: Cowork writes to it, host-side git
snapshots it.

## The remote

This repo lives at **https://github.com/jrenaldi79/sidecar-plugin** (private),
with `origin` already wired up. On a fresh machine:

```bash
cd ~/Documents/ClaudeCowork
gh repo clone jrenaldi79/sidecar-plugin
```

## Day-to-day

Edit files in Cowork chats as usual. When you're ready to snapshot, from a
host terminal:

```bash
cd ~/Documents/ClaudeCowork/sidecar-plugin
git status                    # see what changed
git diff                      # review
git add <files>
git commit -m "your message"
git push
```

## Reverting

```bash
git log --oneline             # find the commit you want
git checkout <sha> -- <file>  # restore a single file
git revert <sha>              # undo a commit (creates a new one)
git reset --hard <sha>        # rewind branch (destructive — careful)
```

## What's tracked vs. ignored

- `.gitignore` excludes `skills/sidecar/proxy/node_modules/` (build-time only,
  regenerable from `package.json` + `package-lock.json` via `build.sh`).
- Also ignored: `.DS_Store`, `*.plugin`, editor caches, and local Claude/Cowork
  session artifacts (`.claude/`, `.clearance-rendered-preview-*/`).
- Tracked: SKILL.md, all scripts, the plugin manifests, package.json/lock,
  README.

## Rebuilding the .plugin file

After making changes:

```bash
bash build.sh
# outputs: ../sidecar.plugin (alongside this repo, in ClaudeCowork/)
```

Then re-import that file into Cowork to install the updated version.
