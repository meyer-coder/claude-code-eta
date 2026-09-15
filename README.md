# Claude Code ETA

Know how much longer Claude Code will take and how much of your plan you have left, and jump back into your recent repos with one word.

## Install

Open the **Terminal** app on your Mac, paste this line, and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/install.sh | bash
```

This installs two things:

- **The ETA and usage battery.** Open Claude Code and send a prompt. The ETA appears in the status line under the input box. Sessions that are already open pick it up on their own; if nothing changes, restart Claude Code.
- **preview.** Open a new Terminal window and type `preview` to pick one of your 5 most recently used git repos. It has its own section, with its own install, at the bottom: [preview](#preview).

You need macOS, Claude Code, and `jq` (install it with `brew install jq`). To uninstall, see [Uninstall](#uninstall).

Prefer to read the code first:

```bash
git clone https://github.com/meyer-coder/claude-code-eta.git
cd claude-code-eta
./install.sh
```

The installer copies the ETA scripts to `~/.claude/hooks/eta/` and `preview` to `~/.config/preview/`. It backs up `~/.claude/settings.json` and `~/.zshrc`, adds its hooks and status line, and adds one line to `~/.zshrc` that loads `preview`. Your other hooks and settings stay as they are. If you already had a status line, it is saved and put back when you uninstall. Running the installer again updates to the latest version.

## What you get

This adds three things to the Claude Code status line, under the input box:

```
⏱ Fix login flow · ETA ~30m · done by 3:41 PM · 29:46 left (20m to 45m) · ~168k tokens · updated just now
  ↳ Agent: Independent review of auth code · ETA ~15m · done by 3:26 PM · 14:38 left · 18 tool calls
🔋 5h ███░░░░░░░ 26% (resets 6:10 PM)  Week ███░░░░░░░ 34%  Fable ███████░░░ 66%  (weekly resets Thu 4 AM)
```

- **Task ETA.** Every prompt gets an estimate of how long the task will take and how many tokens it will use. It counts down live, turns yellow when running long, and red when it is past its likely finish. When the task ends, it shows how long it really took and the tokens it used.
- **Background work ETAs.** Every background workflow, agent or command Claude launches gets its own countdown line. Workflows show how many of their agents have finished. A task is not marked done until its background work is.
- **Usage battery.** How much of your 5-hour limit, weekly limit and Fable weekly limit is used, and when they reset.

Estimates update themselves while work runs, and they learn from your finished tasks: if they keep running short, new ones are scaled up.

## Requirements

- macOS. The scripts use the macOS versions of `stat`, `date` and `md5`.
- Claude Code, signed in. The usage battery needs a Claude Pro or Max plan, because that is where the limits come from.
- `jq` (`brew install jq`). `perl` and `curl` come with macOS.

## What it costs

The estimates come from small calls to Claude through your own Claude Code login, so they count toward your usage:

| When | What runs |
| --- | --- |
| Each prompt you send | One Haiku call to estimate the task |
| Each background job Claude launches | One Haiku call to estimate the job |
| While a task or job runs | One Haiku update every 2 to 10 minutes |
| While you are working, if your plan includes Fable | One tiny Fable request (about 450 tokens) at most every 10 minutes, to read the Fable limit |

Nothing runs while Claude Code is idle.

## Privacy

Everything is stored locally in `~/.claude/eta/`. Estimates are made by Claude, through your own Claude Code login, and nothing is sent anywhere else. To make them, the scripts send:

- For a task: your prompt, a few lines of recent conversation, the project folder path, and the labels and durations of your recent tasks.
- For a background job: the command, agent prompt or workflow script Claude launched (trimmed to a few thousand characters).
- For updates while work runs: what Claude has done so far, how many tokens it used, and progress such as the last lines of a running command's output.

## How it works

Claude Code hooks and a status line command, all plain bash:

| Script | Runs on | Does |
| --- | --- | --- |
| `task-start.sh` | Each prompt (before Claude starts) | Records the new task |
| `estimate.sh` | Each prompt (in the background) | Asks Haiku for time, range, tokens and a short label, then corrects for past bias |
| `job-start.sh` | After Claude launches a workflow, background agent or background command | Records the job and estimates it |
| `job-done.sh` | When a subagent finishes | Marks background agents done right away |
| `stop.sh` | When Claude finishes a turn, or a turn fails | Marks the task done, waiting on background jobs, or failed |
| `account.sh` | Called by `stop.sh` | Counts the tokens the task used, including its subagents |
| `reestimate.sh` | Started by the status line | Updates a running estimate from live progress |
| `probe.sh` | Started while you are working | Reads the Fable weekly limit |
| `statusline.sh` | Every second | Draws the three lines |
| `lib.sh` | Everywhere | Shared helpers |

Tokens are counted as new input, cache writes and output. Cached context that gets re-read is not counted.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/uninstall.sh | bash
```

This removes the hooks, scripts and `preview`, and restores your previous status line. Your ETA history in `~/.claude/eta/` and your `preview` history are kept. To delete them too:

```bash
curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/uninstall.sh | bash -s -- --purge
```

## Limits

- The ETA lives in the status line. It cannot sit on the "Worked for" line, which is built into Claude Code.
- The Fable limit is read from data Claude Code does not officially document for this. A Claude Code update could change it, and the Fable bar would then show `…` until this project is updated.
- The first estimates are uncalibrated. They get better after a handful of finished tasks.
- An agent Claude runs in the foreground counts toward the main task instead of getting its own line.
- The share of your 5-hour limit a task used is approximate when several sessions run at once.

## Troubleshooting

- **The install command says "not found" (404):** GitHub can take a few minutes to serve a new version. Wait a minute and paste it again.
- **"jq was not found":** run `brew install jq`, then paste the install command again.
- **"command not found: preview":** open a new Terminal window, or run `source ~/.zshrc`.
- **Nothing shows up:** restart Claude Code, and check that `disableAllHooks` is not set in `~/.claude/settings.json`.
- **"ETA unavailable":** see `~/.claude/eta/estimate.log` for the reason.
- **Fable bar shows `…`:** it fills in within 10 minutes of working, and only if your plan includes Fable.

## License

MIT

## preview

A separate tool in this repo: type `preview` in Terminal to jump back into one of your 5 most recently used git repos, your projects. The main install above already includes it. To install only preview, paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/preview/install.sh | bash
```

Then open a new Terminal window and type `preview`.

What it looks like:

```
Projects:  ↑/↓ move · Enter open · Esc quit
  ❯ ~/projects/my-app  · main · 5m ago
    ~/projects/website  · redesign · 2h ago
    ~/code/api  · main · 3d ago
    N/A
    N/A
```

- Move with the arrow keys (or `j` and `k`), press Enter to open, and press Esc or `q` to cancel.
- Enter goes to that folder and starts Claude Code with a kickoff prompt: it reviews recent commits, uncommitted changes and notes, then suggests what to work on next.
- It lists only git repos, newest first. A repo counts as used when you `cd` into it (or any folder inside it) or when git records work there, so work done inside Claude Code counts too.
- It also finds repos in common project folders (`~/projects`, `~/code`, `~/dev`, `~/src`, `~/repos`, `~/Developer`, `~/GitHub`, `~/Documents/GitHub`) before you ever `cd` into them.

Change how it behaves by setting these in `~/.zshrc` before the line that loads `preview`:

| Setting | Default | Does |
| --- | --- | --- |
| `PREVIEW_COUNT` | `5` | How many projects to list |
| `PREVIEW_AUTO_CLAUDE` | `1` | Set to `0` to only change folder, without starting Claude Code |
| `PREVIEW_CLAUDE_PROMPT` | kickoff prompt | The prompt Claude Code starts with |
| `PREVIEW_GIT_ONLY` | `1` | Set to `0` to also list recent folders that are not git repos |
| `PREVIEW_ROOTS` | common project folders | Space-separated folders whose repos are listed even before you `cd` into them |

`preview` needs zsh, the default shell on macOS.

To remove only preview:

```bash
curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/preview/uninstall.sh | bash
```

Your recent-folder history is kept. Add `-s -- --purge` after `bash` to delete it too.
