# Claude Code ETA

Know how much longer Claude Code will take, and how much of your plan you have left.

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

## Install

Paste this into your terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/install.sh | bash
```

Then open Claude Code and send a prompt. Sessions that are already open pick it up on their own. If the status line does not change, restart Claude Code.

Prefer to read the code first:

```bash
git clone https://github.com/meyer-coder/claude-code-eta.git
cd claude-code-eta
./install.sh
```

The installer copies the scripts to `~/.claude/hooks/eta/`, backs up `~/.claude/settings.json`, and adds its hooks and status line. Your other hooks and settings stay as they are. If you already had a status line, it is saved and put back when you uninstall. Running the installer again updates to the latest version.

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

Everything is stored locally in `~/.claude/eta/`. To make an estimate, the scripts send your prompt, a few lines of recent conversation, and short progress notes (such as the last lines of a running command's output) to Claude, through your own Claude Code login. Nothing is sent anywhere else.

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

This removes the hooks and scripts and restores your previous status line. Your ETA history in `~/.claude/eta/` is kept. To delete it too:

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

- **Nothing shows up:** restart Claude Code, and check that `disableAllHooks` is not set in `~/.claude/settings.json`.
- **"ETA unavailable":** see `~/.claude/eta/estimate.log` for the reason.
- **Fable bar shows `…`:** it fills in within 10 minutes of working, and only if your plan includes Fable.

## License

MIT
