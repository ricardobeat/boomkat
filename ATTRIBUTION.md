# Agent Attribution and Usage

Snapshot taken 2026-09-25. The 2026-07-08 snapshot is kept unchanged in
[ATTRIBUTION-2026-07-08.md](ATTRIBUTION-2026-07-08.md).

The repository lived at `~/cousas/duktape-c3` until the rename on
2026-08-18, so every source below is filtered on both `cousas/duktape-c3` and
`cousas/boomkat` (including `.worktrees/*`).

## Summary

| Harness | Commits | Human prompts | >10 words | Sessions | Data window | Reported cost |
|---|---:|---:|---:|---:|---|---:|
| Claude Code | 1,670 | 2,395 | 1,045 | 241 | 2026-05-23 → 09-25 | — |
| Crush | 901 | 1,964 | 1,000 | 1,753 (607 top-level) | 2026-05-23 → 09-21 | $607.46 |
| opencode | 338 | 763 | 307 | 704 (97 top-level) | 2026-06-09 → 09-15 | $362.89 |
| opencode or pi | 38 | — | — | — | — | — |
| Codex | 21 | 76 | 35 | 16 (6 top-level) | 2026-09-19 → 09-25 | — |
| pi | 2 | 36 | 11 | 35 | 2026-05-23 → 08-02 | $0.77 |
| Shelley (exe.dev) | 6 | — | — | — | — | — |
| Unattributed | 75 | — | — | — | — | — |
| **Total** | **3,051** | **5,234** | **2,398** | | | |

Reported cost is whatever the harness recorded. Flat-rate plans
(`xiaomi-token-plan-ams`, `minimax-coding-plan`, `kimi-coding`, the free
tiers) record $0, so real spend is higher. Claude Code and Codex record no
cost.

## Sources

| Harness | Source | Notes |
|---|---|---|
| git | `git log --branches --tags --remotes --no-merges` | `refs/stash` and `refs/original` excluded |
| Crush | `.crush/crush.db` | opened with `immutable=1`; no other Crush DB on the machine has repo sessions |
| Claude Code | `~/.claude/history.jsonl`, `~/.claude/projects/*boomkat*/**/*.jsonl` | history keeps every prompt; transcripts are deleted after 30 days |
| opencode | `~/.local/share/opencode/opencode.db` | project `571ddff2…` (worktree `~/cousas/duktape-c3`) |
| Codex | `~/.codex/sessions/**/*.jsonl`, `~/.codex/state_5.sqlite` | rollouts whose `session_meta.cwd` is in the repo |
| pi | `~/.pi/agent/sessions/--Users-rtomasi-cousas-duktape-c3--/` | |
| Gemini CLI | `~/.gemini` | no repo sessions |

## Commits

3,536 non-merge commits sit on branches, tags and remotes. Rebases and
cherry-picks copied many of them: 485 are copies of another commit with the
same author, author date and subject. After collapsing those, **3,051**
distinct commits remain, and every count in this file uses that number.

Each commit is attributed by the first rule that applies:

1. **Harness log (751 commits).** Every harness logs the output of the
   `git commit` it ran (`[branch 1a2b3c4] subject`). 954 such lines were
   extracted; 773 resolve to a commit whose subject matches, and 181 point
   at commits no longer on any ref (amended, rebased or on deleted branches).
2. **Trailer (1,819).** `Assisted-by:` wins over `Co-Authored-By:`; a bare
   `💘 Generated with Crush` counts as Crush. Co-author lines that name only a
   model (`Mimo v2.5 Pro`, `Deepseek v4 Flash`, `deepseek-v4-pro`, `Kimi K3`)
   count as **opencode or pi**. `GPT Astra 6` counts as Codex.
3. **Time (406).** The commit's author timestamp is matched against each
   harness's activity: the harness that was the only one active in the
   previous 3 minutes (for Claude Code before 08-26, a prompt in the previous
   45 minutes), or else the harness with the most recent activity within 2
   hours. On the 751 log-verified commits this rule picks the right harness
   734 times (98%).
4. **Unattributed (75).** Nothing active within 2 hours.

| Harness | Log | Trailer | Time | Total |
|---|---:|---:|---:|---:|
| Claude Code | 45 | 1,412 | 213 | 1,670 |
| Crush | 438 | 362 | 101 | 901 |
| opencode | 250 | — | 88 | 338 |
| opencode or pi | — | 38 | — | 38 |
| Codex | 17 | 1 | 3 | 21 |
| pi | 1 | — | 1 | 2 |
| Shelley | — | 6 | — | 6 |
| Unattributed | | | | 75 |

### Models by commit

Log and trailer commits only; time-attributed commits have no model.

| Harness | Model | Commits |
|---|---|---:|
| Claude Code | Claude Opus 5 | 649 |
| | Claude Opus 4.8 | 331 |
| | Claude Fable 5 | 301 |
| | Claude Sonnet 5 | 71 |
| | Claude Opus 4.7 | 45 |
| | Claude Sonnet 4.6 | 44 |
| | Claude Haiku 4.5 | 13 |
| | Claude Opus 4.6 | 2 |
| | Claude Opus 5.5 | 1 |
| Crush | MiniMax-M3 | 239 |
| | deepseek-v4-flash (incl. `-free`, `-0731`) | 165 |
| | mimo-v2.5 | 98 |
| | mimo-v2.5-pro (incl. `-ultraspeed`) | 93 |
| | deepseek-v4-pro | 72 |
| | deepseek-v4.1-flash / flashx | 55 |
| | kimi-k2.7-code, k3-256k | 27 |
| | glm-5.2, glm-5.3 (incl. `coding-`, `-flash`, `-flashx`) | 24 |
| | x-preview-f-free | 7 |
| | mimo-v2.6-flash | 5 |
| | muse-spark-1.3-contributor | 3 |
| | gpt-5.5-free | 1 |
| | not recorded | 11 |
| opencode | MiniMax-M3 | 64 |
| | mimo-v2.5-pro (incl. `-ultraspeed`) | 51 |
| | deepseek-v4-pro | 49 |
| | mimo-v2.5 | 34 |
| | mimo-v2-pro | 33 |
| | deepseek-v4-flash (incl. `-free`) | 10 |
| | muse-spark-1.3-contributor | 9 |
| opencode or pi | Mimo v2.5 Pro | 17 |
| | Deepseek v4 Flash | 12 |
| | Kimi K3 / K3-256K | 5 |
| | deepseek-v4-pro | 4 |
| Codex | gpt-6-astra | 15 |
| | gpt-6-sol | 3 |
| pi | deepseek-v4-flash | 1 |

### Trailer accuracy

Of the 751 log-verified commits, 325 have no trailer at all: 245 opencode,
60 Crush, 17 Codex, 2 Claude Code, 1 pi. opencode and Codex never add one,
so trailer-only counts miss them entirely.

Trailers written by the model are sometimes wrong:

| Commits | Trailer says | Log says |
|---:|---|---|
| 6 | `Crush:meta/muse-spark-1.3-contributor` | Claude Code, claude-opus-5 |
| 4 | `Claude Opus 4.6` | Crush, MiniMax-M3 |
| 3 | `Claude Sonnet 4.6` | opencode, deepseek-v4-pro |
| 2 | `Crush:kimi-k2.7-code` | opencode, mimo-v2-pro |
| 1 | `Claude Opus 5` | Crush, deepseek-v4-flash |
| 3 | `Crush:claude-sonnet-4-20250514` | Crush, mimo-v2.5 |
| 3 | `Crush:claude-opus-4-6` | Crush, mimo-v2.5 |
| 2 | `Crush:claude-sonnet-4-6` | Crush, mimo-v2.5 |
| 1 | `Crush:codestral-2506` | Crush, mimo-v2.5 |
| 1 | `Crush:openrouter/anthropic/claude-sonnet-4` | Crush, mimo-v2.5 |
| 2 | `Crush:MiniMax-M3` | Crush, k3-256k |
| 2 | `Crush:MiniMax-M3` | Crush, glm-5.2 |
| 2 | `Crush:new-skill` | Crush, deepseek-v4-flash-free |
| 4 | other single-model mismatches | Crush |
| 1 | malformed `Co-authored-by:` line | Crush, deepseek-v4-flash |

The Claude trailers on the 1,412 trailer-only Claude Code commits could not
be checked: Claude Code transcripts before 2026-08-26 are gone (see
[Data loss](#data-loss)).

## Human prompts

A human prompt is a user message in a top-level session. Sub-agent sessions,
compaction and synthetic parts, injected `AGENTS.md` /
`<environment_context>` blocks, shell escapes and slash commands (585 in
Claude Code) are excluded. Words are counted on whitespace.

| Harness | Prompts | >10 words |
|---|---:|---:|
| Claude Code | 2,395 | 1,045 |
| Crush | 1,964 | 1,000 |
| opencode | 763 | 307 |
| Codex | 76 | 35 |
| pi | 36 | 11 |
| **Total** | **5,234** | **2,398** |

| Month | Claude Code | Crush | opencode | Codex | pi | Total | >10 words |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2026-05 | 85 | 569 | — | — | 23 | 677 | 423 |
| 2026-06 | 292 | 628 | 452 | — | 12 | 1,384 | 639 |
| 2026-07 | 1,049 | 304 | 137 | — | — | 1,490 | 621 |
| 2026-08 | 659 | 392 | 75 | — | 1 | 1,127 | 487 |
| 2026-09 | 310 | 71 | 99 | 76 | — | 556 | 228 |

Short replies dominate the repeats: `continue` (Crush 72, opencode 24),
`go on` (30, 11), `yes`. Crush also has templated prompts pasted many times,
such as `@PRD.md @progress.md 1. Find the highest-priority …` (105 times
across the four most common variants).

## Usage

### Crush

Crush stores `prompt_tokens` and `completion_tokens` per session as the last
turn's values, not running totals (a 7,458-message session shows 298
completion tokens), and messages carry no usage. Token totals are not
recoverable. `cost` does accumulate.

| Month | Sessions | Top-level | Messages | Cost |
|---|---:|---:|---:|---:|
| 2026-05 | 837 | 276 | 65,010 | $25.56 |
| 2026-06 | 682 | 235 | 71,191 | $277.71 |
| 2026-07 | 122 | 45 | 25,034 | $224.90 |
| 2026-08 | 104 | 44 | 23,913 | $34.62 |
| 2026-09 | 8 | 7 | 2,817 | $44.67 |

Assistant messages by model:

| Model | Messages | Sessions | Providers |
|---|---:|---:|---|
| deepseek-v4-flash (incl. `-free`, `-0731`) | 22,110 | 371 | opencode-go, opencode-zen, aihubmix, openai-compat |
| MiniMax-M3 | 21,460 | 160 | minimax, opencode-go |
| mimo-v2.5 | 16,738 | 721 | xiaomi, xiaomi-api, xiaomi-token-plan-ams, openai-compat, aihubmix |
| mimo-v2.5-pro (incl. `-ultraspeed`) | 10,100 | 368 | xiaomi, xiaomi-api, xiaomi-token-plan-ams, openai-compat, aihubmix |
| deepseek-v4-pro | 8,394 | 139 | opencode-go, aihubmix, openrouter, openai-compat |
| kimi (k2.7-code, k3, k3-256k) | 1,615 | 44 | opencode-go, openrouter, kimi, kimi-coding, aihubmix |
| glm-5.2, glm-5.3, coding-glm-5.3 | 777 | 4 | aihubmix, opencode-go |
| local models (lmstudio) | 458 | 40 | lmstudio |
| stealth/ox-alpha | 401 | 8 | openrouter, opencode-go |
| MiniMax-M2.7 (incl. `-highspeed`) | 207 | 10 | minimax, anthropic |
| other | 414 | | gemini, gpt-5.5-free, mistral, qwen3.7-max, muse-spark, … |

### Claude Code

`history.jsonl` has 2,980 prompt entries in 241 sessions from 2026-05-23 to
2026-09-25. Transcripts, and with them token usage, survive only from
2026-08-26 (33 sessions). Usage is taken from the last transcript line for
each API message id, since streaming writes several lines per message.

| Model | Messages | Sessions | Output | Cache read | Cache write | Input |
|---|---:|---:|---:|---:|---:|---:|
| claude-opus-5 | 10,589 | 30 | 3,817,288 | 1,708,151,272 | 14,521,938 | 20,736 |
| claude-sonnet-5 | 2,438 | 7 | 452,640 | 470,585,990 | 2,962,422 | 4,876 |
| claude-haiku-4-5 | 112 | 1 | 10,901 | 4,579,296 | 101,636 | 586 |
| claude-opus-5-5 | 50 | 2 | 45,900 | 3,725,097 | 117,833 | 100 |

### opencode

704 sessions (97 top-level) from 2026-06-09 to 2026-09-14; 57,609 assistant
messages; 254.9M input, 14.3M output, 6.50B cache-read tokens.

| Month | Sessions | Assistant messages | Cost |
|---|---:|---:|---:|
| 2026-06 | 399 | 21,670 | $150.19 |
| 2026-07 | 188 | 19,252 | $125.15 |
| 2026-08 | 37 | 3,965 | $12.83 |
| 2026-09 | 62 | 12,722 | $74.72 |

| Provider / model | Messages | Sessions | Input | Output | Cache read | Cost |
|---|---:|---:|---:|---:|---:|---:|
| minimax/MiniMax-M3 | 18,160 | 162 | 33,770,762 | 4,744,178 | 2,204,707,632 | $210.37 |
| xiaomi-token-plan-ams/mimo-v2.5 | 7,608 | 115 | 28,108,662 | 1,626,602 | 803,594,944 | plan |
| xiaomi/mimo-v2.5 | 6,994 | 176 | 29,011,145 | 1,765,154 | 601,627,712 | $77.02 |
| minimax-coding-plan/MiniMax-M3 | 6,606 | 30 | 21,506,425 | 1,671,216 | 981,305,883 | plan |
| opencode-go/deepseek-v4-pro | 3,760 | 39 | 5,665,051 | 915,782 | 387,933,824 | $21.47 |
| openrouter/meta/muse-spark-1.3-contributor | 3,354 | 5 | 18,023,128 | 611,709 | 660,148,407 | $3.40 |
| xiaomi/mimo-v2.5-pro | 1,904 | 33 | 8,302,735 | 754,899 | 159,460,864 | $30.00 |
| opencode-go/deepseek-v4-flash | 1,573 | 21 | 1,994,223 | 405,625 | 142,804,480 | $0.91 |
| xiaomi/mimo-v2.5-pro-ultraspeed | 1,268 | 54 | 6,467,031 | 170,027 | 61,873,408 | $11.22 |
| xiaomi-token-plan-ams/mimo-v2.5-pro | 1,022 | 27 | 6,233,973 | 360,507 | 72,182,272 | plan |
| opencode/deepseek-v4-flash-free | 972 | 16 | 3,539,237 | 240,153 | 74,673,792 | free |
| xiaomi-token-plan-ams/mimo-v2-pro | 929 | 1 | 5,872,966 | 194,117 | 80,541,760 | plan |
| opencode-go/minimax-m3 | 809 | 8 | 1,180,171 | 243,898 | 81,020,270 | $1.84 |
| aihubmix/coding-glm-5.3 | 796 | 5 | 20,311,148 | 169,904 | 70,161,536 | $0 |
| opencode/north-mini-code-free | 601 | 6 | 48,923,991 | 46,503 | 0 | free |
| opencode-go/muse-spark-1.3-contributor | 541 | 1 | 2,574,252 | 110,529 | 80,769,386 | $0.47 |
| lmstudio/qwen3.6-35b-a3b | 293 | 4 | 11,445,505 | 75,356 | 0 | local |
| other (9 models) | 419 | | 1,985,170 | 178,834 | 33,530,656 | $6.19 |

### Codex

16 rollouts: 6 top-level CLI threads, 6 spawned sub-agents and 4
`codex-auto-review` guardian threads. Tokens are summed from per-response
`token_usage_record` entries; input includes cached input.

| Model | Rollouts | Input | Cached input | Output | Reasoning |
|---|---:|---:|---:|---:|---:|
| gpt-6-astra | 6 | 106,778,508 | 103,960,704 | 381,658 | 136,930 |
| gpt-5.6-sol | 3 | 37,220,475 | 36,494,976 | 135,949 | 31,101 |
| gpt-6-sol | 1 | 26,765,715 | 26,415,360 | 51,876 | 21,121 |
| gpt-5.6-luna | 2 | 3,319,058 | 3,101,440 | 29,333 | 8,435 |
| codex-auto-review | 4 | 896,138 | 681,984 | 2,298 | 1,148 |

### pi

35 sessions from 2026-05-23 to 2026-08-02.

| Provider / model | Messages | Sessions | Input | Output | Cache read | Cost |
|---|---:|---:|---:|---:|---:|---:|
| openrouter/deepseek/deepseek-v4-flash | 173 | 5 | 5,515,446 | 145,044 | 3,043,200 | $0.63 |
| opencode-go/deepseek-v4-flash | 151 | 22 | 355,632 | 115,135 | 16,670,208 | $0.13 |
| minimax/MiniMax-M3 | 6 | 4 | 41,360 | 768 | 35,239 | $0.00 |
| other (3 models) | 4 | 4 | 11,301 | 61 | 1,024 | $0.00 |

## Data loss

- **Claude Code transcripts** are deleted 30 days after last use
  (`cleanupPeriodDays` is unset). Everything before 2026-08-26 is gone,
  including all `duktape-c3` sessions, and more expires every day. Only the
  prompt text in `history.jsonl` survives. Setting `cleanupPeriodDays` in
  `~/.claude/settings.json` stops further loss.
- **Crush tokens** were never stored as totals (see [Crush](#crush)).
- **181 logged commits** are no longer on any ref.

## Corrections to the 2026-07-08 snapshot

- "The 304 untagged commits predate the attribution hook." Many do not:
  opencode (from 2026-06-09) and Codex never write trailers, and Crush
  omitted them on 60 logged commits.
- The snapshot counted all refs including `refs/stash`, and counted rebased
  copies separately, which inflates every bucket.
- Buckets such as `Crush:claude-opus-4-6` and `Crush:codestral-2506` came from
  wrong trailers; the logs show mimo-v2.5 (see
  [Trailer accuracy](#trailer-accuracy)).
