# Setting up git for this repo

The Cowork bash sandbox can't fully drive git because the Mac-mounted folder
blocks `unlink` operations, which git needs for lock-file lifecycle. So git
must be initialized and operated from your **Mac terminal**, not from inside
a Cowork chat.

## One-time setup

```bash
cd ~/Documents/ClaudeCowork/sidecar-plugin
rm -rf .git              # clear the broken Cowork-side init if present
git init -b main
git add -A
git commit -m "Initial commit: Sidecar plugin v0.1.0"
```

## Day-to-day

You can edit files inside Cowork chats (Read/Write/Edit tools) — those changes
land on disk. When you're ready to snapshot:

```bash
cd ~/Documents/ClaudeCowork/sidecar-plugin
git status                    # see what changed
git diff                      # review
git add <files>
git commit -m "your message"
```

## Reverting

```bash
git log --oneline             # find the commit you want
git checkout <sha> -- <file>  # restore a single file
git revert <sha>              # undo a commit (creates a new one)
git reset --hard <sha>        # rewind branch (destructive — careful)
```

## Pushing to GitHub

```bash
gh repo create sidecar-plugin --private --source=. --remote=origin --push
# or:
git remote add origin git@github.com:<user>/sidecar-plugin.git
git push -u origin main
```

## What's tracked vs. ignored

- `.gitignore` excludes `skills/sidecar/proxy/node_modules/` (vendored deps,
  regenerable from `package.json` + `package-lock.json` via `build.sh`).
- Also ignored: `.DS_Store`, `*.plugin`, editor caches.
- Tracked: SKILL.md, all scripts, plugin.json, package.json/lock, README.

## Rebuilding the .plugin file

After making changes:

```bash
bash build.sh
# outputs: ../sidecar.plugin (alongside this repo, in ClaudeCowork/)
```

Then re-import that file into Cowork to install the updated version.
