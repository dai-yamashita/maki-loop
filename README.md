# maki-loop

A simple maki plugin that adds a `/loop [Instructions]` command. This command will run until the described goal / task is complete.

## Install

Requires maki 0.7.1+ with `maki.pack` support, Git, and the interactive TUI in build mode. Older maki versions skip the plugin with a startup warning.

1. Add this to your **global** `~/.config/maki/init.lua` (create it if needed):

   ```lua
   maki.pack.add({
     {
       src = "https://github.com/dai-yamashita/maki-loop",
       version = "v0.7.1-agent.1",
     },
   })
   ```

   Pin the tag rather than `main`: a lockfile entry wins over `version`, and a branch ref is only re-fetched when its commit is not already on disk, so `main` can silently go stale.

   Package installation is global and maki reads the config directory at `~/.config/maki/`; don't put this in a project's `.maki/init.lua`. Maki 0.7.1 no longer reads the legacy `~/.maki/` layout (it moves it into place on first start), so edit `~/.config/maki/init.lua`.

2. Start maki and accept the package installation and permission prompts. The plugin requests `fs_read` and `fs_write` to save and restore per-project loop state, `agent` and `session_write` to open the next session and send its prompt, and `session_read` so `TurnStart` arrives without its content being redacted. It does not request network, process, environment, chat input, or session-settings access.
3. Use `/loop` in a build-mode session.

> **Fork distribution.** `dai-yamashita/maki-loop` is the maintained distribution. Upstream closed [PR #1](https://github.com/MatthewScholefield/maki-loop/pull/1) unmerged, so upstream's own pin stays on maki 0.6-era APIs and breaks on 0.7.x. This fork carries 0.7.x support — the `agent`, `session_read`, and `session_write` permissions, a focused `maki.session.new` call, and the handoff-flag fix — and targets maki 0.7.1.
>
> **Updating from `v0.7.0-agent.1`/`.2`:** changing the pin alone does nothing, because `pack-lock.json` records a commit and that wins over `version`. Edit the `version`, then run `/packupdate maki-loop` and accept the review; that restarts maki on the new revision, so no `/reload` is needed. Permissions are unchanged, so nothing new is approved. If you installed from the upstream URL, the source change re-runs the install prompt and asks for all permissions again.

No copying files, extra `require`, or changes to your config's `plugin.toml` are needed. Maki loads `plugin/loop.lua` automatically, keeps the checkout in its managed data directory, and pins the installed commit in your global config's `pack-lock.json`.

If you previously installed by copying `lua/loop.lua`, remove the old `require("loop")` and copied file before installing the package to avoid duplicate registrations. Remove any permissions you added solely for that old installation, keeping grants needed by other plugins.

## Update and uninstall

To fetch and review an update:

```text
/packupdate maki-loop
```

Accept the proposed revision. Maki restarts and rebuilds its plugins on the new revision, so no `/reload` is needed. Updates are explicit; normal startup uses the locked commit. A revision that changes the manifest also asks you to approve the new permission set. You can share `pack-lock.json` to reproduce the same revisions on another machine, but permission approval is local to each machine.

To uninstall, remove the source from `maki.pack.add`, run `/reload`, then run:

```text
/packdel maki-loop
```

Accept the removal prompt. Close any other maki processes still using the package if removal is refused.

## Usage

```text
/loop Finish the tasks in TASKS.md. Record progress there and verify each change.
```

`/loop` always starts a new objective, replacing any previous loop and revoking its pending continuation. The first iteration uses your current session when it is idle in build mode with no queued work or previous loop state. Otherwise it opens a fresh build-mode session immediately, leaving existing work and queued input untouched. After each normally finished turn, the plugin opens a fresh session with the same model settings and repeats the original objective. No previous transcript or summary is passed along, so it's meant for you to keep your ongoing task state / progress within some markdown file you reference in your prompt. A blank session cannot be stored in the background (maki refuses to persist a session with no messages), so the fresh tab opens focused instead.

The agent calls `loop_complete` when the whole objective is done.

- `/loop-status` — show progress and reported cost.
- `/loop-stop` — stop continuation without cancelling current work.
- `/loop-resume` — resume a stopped or interrupted loop in a fresh session. During an active turn, arm continuation for when that turn finishes normally without cancelling it.

Errors, cancellation, or conflicting user work interrupt continuation. Restarting or reloading requires an explicit resume.

Warning: **There is currently no iteration or spending limit**; use carefully.

## Tests

```sh
luajit tests/run.lua
```

Tests run on every push and pull request via GitHub Actions.
