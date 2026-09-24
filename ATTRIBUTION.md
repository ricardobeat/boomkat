# Commit Attribution & Agent Usage Audit

Latest snapshot: **2026-09-25**. Earlier snapshots are kept verbatim at the
bottom of this file; do not edit them, append a new snapshot instead.

Sources:
- `git log --all --no-merges` across every branch (3,546 non-merge commits).
- Crush: `.crush/crush.db` (opened read-only), sessions 2026-05 → 2026-09.
- Claude Code: `~/.claude/projects/*boomkat*/**/*.jsonl` (79 transcripts).
- opencode: `~/.local/share/opencode/opencode.db`, sessions whose directory contains `boomkat`.
- Codex: `~/.codex/sessions/**/*.jsonl` mentioning `boomkat`.
- Gemini CLI and pi were checked; neither has boomkat sessions.

## Git totals (2026-09-25)

| Marker | Commits |
|---|---:|
| Non-merge commits, all branches | 3,546 |
| `💘 Generated with Crush` in body | 796 |
| `Co-Authored-By` / `Assisted-by` trailer present | 2,645 |
| `claude.ai/code/session_*` URL | 1,671 (61 distinct sessions) |
| No attribution trailer | 901 |

## Per-agent commit counts (2026-09-25)

Deduped, one bucket per commit; `Assisted-by:` wins over `Co-Authored-By:`
(same rule as the 2026-07-08 snapshot).

| Commits | Agent | Raw tag(s) |
|---:|---|---|
| 768 | **Claude Opus 5** | `Claude Opus 5` |
| 486 | **Claude Opus 4.8** | `Claude Opus 4.8` |
| 372 | **Claude Fable 5** | `Claude Fable 5` |
| 273 | **Crush + deepseek-*** | `deepseek-v4-flash` (88), `deepseek-v4-pro` (71), `deepseek-v4-flash-free` (36), `deepseek-v4.1-flashx` (28), `deepseek-v4.1-flash` (26), `deepseek-v4-flash-0731` (17), `deepseek/deepseek-v4-flash-0731` (5), `deepseek/deepseek-v4.1-flash` (1), `deepseek/deepseek-v4-pro` (1) |
| 201 | **Crush + MiniMax-M3** | `MiniMax-M3` (186), `minimax/minimax-m3:free` (13), `minimax-m3` (2) |
| 196 | **Crush + mimo-*** | `mimo-v2.5-pro` (96), `mimo-v2.5` (88), `mimo-v2.5-pro-ultraspeed` (7), `mimo-v2.6-flash` (5) |
| 75 | **Claude Sonnet 5** | |
| 51 | **Claude Sonnet 4.6** | |
| 45 | **Claude Opus 4.7** | |
| 42 | **Crush + kimi-*** | `kimi-k2.7-code` (33), `k3-256k` (8), `moonshotai/kimi-k2.7-code` (1) |
| 18 | **Crush + muse-spark** | `meta/muse-spark-1.3-contributor` |
| 17 | **Mimo v2.5 Pro** (co-author, no harness tag) | |
| 16 | **Crush + GLM-5.3** | `coding-glm-5.3` (11), `glm-5.3-flashx` (2), `glm-5.3-flash` (3) |
| 13 | **Crush (model not decoded)** | bare `Crush` (11), `Crush:new-skill` (2) |
| 13 | **Claude Haiku 4.5** | |
| 12 | **Deepseek v4 Flash** (`Assisted-by`, no harness tag) | |
| 9 | **Kimi K3** (co-author, no harness tag) | `Kimi K3` (6), `Kimi K3-256K` (3) |
| 8 | **deepseek-v4-pro** (co-author, no harness tag) | |
| 7 | **Crush + x-preview-f-free** | |
| 6 | **Claude Opus 4.6** | |
| 6 | **Crush + claude-sonnet-*** | `claude-sonnet-4-20250514` (3), `claude-sonnet-4-6` (2), `openrouter/anthropic/claude-sonnet-4` (1) |
| 6 | **Shelley (exe.dev)** | |
| 3 | **Crush + claude-opus-4-6** | |
| 1 | **Crush + codestral-2506** | |
| 1 | (malformed trailer) | a commit-body line starting with `Co-authored-by` |
| 901 | **(no trailer)** | pre-hook, or committed outside an agent |

Roll-up: Claude (Code) 1,816 · Crush 776 · other/untagged-harness 53 · none 901.

No Codex or opencode commits carry an identifying trailer, so their work is
invisible in git. The untagged `Mimo`/`Kimi`/`deepseek` co-author lines are
most likely opencode (see below), but that is not provable from git.

## Harness usage (2026-09-25)

### Crush — `.crush/crush.db`

1,753 sessions (607 top-level, rest sub-agents), 187,965 messages,
60.5M prompt / 2.6M completion tokens, **$607.46** reported cost
(many providers are flat-rate plans that report $0, so real spend differs).

| Month | Sessions | Prompt tok | Completion tok | Cost |
|---|---:|---:|---:|---:|
| 2026-05 | 837 | 38,351,518 | 1,303,637 | $25.56 |
| 2026-06 | 682 | 11,720,574 | 1,018,487 | $277.71 |
| 2026-07 | 122 | 1,847,557 | 135,156 | $224.90 |
| 2026-08 | 104 | 7,860,871 | 146,619 | $34.62 |
| 2026-09 | 8 | 766,897 | 12,248 | $44.67 |

Assistant messages by model (top 20; providers merged):

| Model | Assistant msgs | Sessions | Providers |
|---|---:|---:|---|
| MiniMax-M3 / minimax-m3 | 21,460 | 160 | minimax, opencode-go |
| deepseek-v4-flash (+free, -0731) | 22,110 | 371 | opencode-go, opencode-zen, aihubmix, openai-compat |
| mimo-v2.5 | 16,738 | 721 | xiaomi, xiaomi-api, xiaomi-token-plan-ams, openai-compat, aihubmix |
| mimo-v2.5-pro (+ultraspeed) | 10,100 | 368 | xiaomi, xiaomi-api, xiaomi-token-plan-ams, openai-compat, aihubmix |
| deepseek-v4-pro | 8,394 | 139 | opencode-go, aihubmix, openrouter, openai-compat |
| kimi (k2.7-code, k3, k3-256k) | 1,614 | 44 | opencode-go, openrouter, kimi, kimi-coding, aihubmix |
| coding-glm-5.3 / glm-5.x | 777 | 4 | aihubmix, opencode-go |
| lmstudio (local qwen/gemma/etc.) | 459 | 40 | lmstudio |
| stealth/ox-alpha | 401 | 8 | openrouter, opencode-go |
| MiniMax-M2.7 (+highspeed) | 207 | 10 | minimax, anthropic |
| other (≤150 msgs each) | ~620 | — | gemini, gpt-5.5-free, mistral, qwen3.7-max, muse-spark, … |

Timestamp caveat: `sessions.created_at` mixes milliseconds and seconds
(the update trigger writes seconds); monthly buckets normalise both.

### Claude Code — `~/.claude/projects/*boomkat*`

Transcripts span 2026-08-19 → 2026-09-24 (main checkout + worktrees
`metrics`, `modern-bench`, `sloppy-mode`, `speed`, `speed2`, `temporal`).
Deduped by API message id.

| Model | Assistant msgs | Sessions | Output tok | Cache-read tok | Cache-write tok |
|---|---:|---:|---:|---:|---:|
| claude-opus-5 | 11,822 | 31 | 4,234,806 | 1,990,146,872 | 17,103,171 |
| claude-sonnet-5 | 2,443 | 8 | 353,154 | 470,676,421 | 3,322,976 |
| claude-haiku-4-5 | 112 | 1 | 4,008 | 4,579,296 | 101,636 |
| claude-opus-5-5 | 12 | 2 | 3,831 | 476,382 | 45,436 |

Earlier Claude work (Fable 5, Opus 4.x, Sonnet 4.6) was done in
claude.ai/code cloud sessions, which leave no local transcripts; git
session URLs are the only record of those.

### opencode — `opencode.db`

90 boomkat sessions, 2026-08-19 → 2026-09-14.

| Provider | Model | Assistant msgs | Sessions | Input tok | Output tok | Cache-read tok | Cost |
|---|---|---:|---:|---:|---:|---:|---:|
| minimax-coding-plan | MiniMax-M3 | 4,805 | 11 | 17,233,375 | 1,118,712 | 798,056,990 | $0 (plan) |
| minimax | MiniMax-M3 | 3,927 | 35 | 9,802,092 | 741,202 | 649,584,076 | $70.85 |
| openrouter | meta/muse-spark-1.3-contributor | 3,354 | 5 | 18,023,128 | 611,709 | 660,148,407 | $3.40 |
| xiaomi-token-plan-ams | mimo-v2.5 | 1,182 | 21 | 1,564,448 | 499,375 | 197,577,152 | $0 (plan) |
| opencode-go | muse-spark-1.3-contributor | 541 | 1 | 2,574,252 | 110,529 | 80,769,386 | $0.47 |
| xiaomi-token-plan-ams | mimo-v2.5-pro | 278 | 13 | 2,181,781 | 173,777 | 25,840,512 | $0 (plan) |
| opencode-go | deepseek-v4-pro | 164 | 3 | 354,352 | 31,840 | 17,837,696 | $0.43 |
| opencode-go | deepseek-v4-flash | 1 | 1 | 0 | 0 | 0 | $0 |

### Codex — `~/.codex/sessions`

25 rollouts mentioning boomkat, 2026-09-07 → 2026-09-24. Token counts are
the last `total_token_usage` of each rollout, summed.

| Model | Rollouts | Input tok | Cached input tok | Output tok |
|---|---:|---:|---:|---:|
| gpt-6-astra | 10 | 323,066,127 | 316,193,664 | 1,050,565 |
| codex-auto-review | 6 | 20,883,359 | 18,186,752 | 12,750 |
| gpt-5.6-sol | 4 | 64,449,052 | 63,318,400 | 192,757 |
| gpt-5.6-luna | 3 | 24,171,967 | 23,463,424 | 136,812 |
| gpt-5.6-terra | 1 | 72,762,296 | 70,441,984 | 210,993 |
| gpt-6-sol | 1 | 23,795,250 | 23,532,416 | 35,328 |

---

## Historical snapshot — 2026-07-08 (preserved; headings demoted one level)

Source: `git log --all --no-merges` across every branch in this repository
(866 non-merge commits total).

### Totals

| Marker | Commits |
|---|---:|
| `💘 Generated with Crush` in body | 432 |
| `Co-Authored-By` / `Assisted-by` trailer present | 562 |
| `Claude-Session:` URL trailer | 76 (across 9 distinct sessions) |
| No attribution trailer at all | 304 |

The 304 untagged commits predate the attribution hook and have no recoverable
model info — every one of them is just `Ricardo Tomasi <ricardobeat@gmail.com>`.

### Per-agent commit counts

Counts below are deduped: each commit is attributed to exactly one bucket.
When a commit carries both `Assisted-by: Crush:<model>` and
`Co-Authored-By: Claude ...`, the `Assisted-by` bucket wins (Crush is treated
as the author, Claude as the co-author).

| Commits | Agent | Raw tag(s) |
|---:|---|---|
| 148 | **Crush + mimo-*** | `mimo-v2.5` (71), `mimo-v2.5-pro` (72), `mimo-v2.5-pro-ultraspeed` (7) |
| 137 | **Crush + deepseek-*** | `deepseek-v4-pro` (62), `deepseek-v4-flash` (40), `deepseek-v4-flash-free` (34), `deepseek/deepseek-v4-pro` (1) |
| 86 | **Crush + MiniMax-M3** | `Crush:MiniMax-M3` (84), `Crush:minimax-m3` (2) |
| 44 | **Claude Fable 5** | `Claude Fable 5 <noreply@anthropic.com>` (no `Assisted-by` trailer) |
| 37 | **Claude Sonnet 4.6** | `Claude Sonnet 4.6 <noreply@anthropic.com>` |
| 29 | **Crush + kimi-*** | `kimi-k2.7-code` (28), `moonshotai/kimi-k2.7-code` (1) |
| 26 | **Claude Sonnet 5** | `Claude Sonnet 5 <noreply@anthropic.com>` |
| 13 | **Crush (model not decoded)** | bare `Crush` (7), `Crush:new-skill` (2), misc. (4) |
| 10 | **Claude Haiku 4.5** | `Claude Haiku 4.5 <noreply@anthropic.com>` |
| 7 | **Claude Opus 4.8** | `Claude Opus 4.8 <noreply@anthropic.com>` |
| 6 | **Claude Opus 4.6** | `Claude Opus 4.6 <noreply@anthropic.com>` |
| 6 | **Crush + claude-sonnet-*** | `claude-sonnet-4-20250514` (3), `claude-sonnet-4-6` (2), `openrouter/anthropic/claude-sonnet-4` (1) |
| 6 | **Shelley (exe.dev)** | `Shelley <shelley@exe.dev>` — only non-Claude, non-Crush agent |
| 3 | **Crush + claude-opus-*** | `claude-opus-4-6` (3) |
| 1 | **Crush + codestral-2506** | Mistral |
| 304 | **(no trailer)** | pre-hook, model unknown |

### Claude-Session URLs (9 distinct)

The `Co-Authored-By: Claude Fable 5` line links to a `claude.ai/code/session_*`
URL. Nine distinct IDs appear across the 76 commits that carry the trailer.
The current `metrics` branch corresponds to session
`0152v5R4mfY8uu9MjUzdAXsS`; the rest live on `main` and older worktrees.

### Cross-tag counts (raw, not deduped)

Because many commits carry **both** `Assisted-by: Crush:<model>` and
`Co-Authored-By: Claude Fable 5`, the raw agent-line totals exceed the
deduped bucket counts:

| Lines | Agent line (verbatim) |
|---:|---|
| 84 | `Crush:MiniMax-M3` |
| 72 | `Crush:mimo-v2.5-pro` |
| 71 | `Crush:mimo-v2.5` |
| 62 | `Crush:deepseek-v4-pro` |
| 44 | `Claude Fable 5 <noreply@anthropic.com>` |
| 40 | `Crush:deepseek-v4-flash` |
| 37 | `Claude Sonnet 4.6 <noreply@anthropic.com>` |
| 34 | `Crush:deepseek-v4-flash-free` |
| 28 | `Crush:kimi-k2.7-code` |
| 26 | `Claude Sonnet 5 <noreply@anthropic.com>` |
| 10 | `Claude Haiku 4.5 <noreply@anthropic.com>` |
| 7 | `Claude Opus 4.8 <noreply@anthropic.com>` |
| 7 | `Crush` (bare) |
| 7 | `Crush:mimo-v2.5-pro-ultraspeed` |
| 6 | `Claude Opus 4.6 <noreply@anthropic.com>` |
| 6 | `Shelley <shelley@exe.dev>` |
| 3 | `Crush:claude-sonnet-4-20250514` |
| 3 | `Crush:claude-opus-4-6` |
| 2 | `Crush:new-skill` |
| 2 | `Crush <crush@anthropic.local>` |
| 2 | `Crush:minimax-m3` |
| 2 | `Crush:claude-sonnet-4-6` |
| 1 each | `Crush <noreply@crush.dev>`, `Crush <noreply@crush.sh>`, `Crush <crush@charm.land>`, `Crush <crush@anthropic.com>`, `Crush:moonshotai/kimi-k2.7-code`, `Crush:codestral-2506`, `Crush:openrouter/anthropic/claude-sonnet-4`, `Crush:deepseek/deepseek-v4-pro` |

### Caveats

- **Bucket priority**: `Assisted-by:` wins over `Co-Authored-By:`. A commit
  written by Crush with Claude as a co-author is counted under Crush.
- **OpenRouter routing**: many `mimo-*`, `deepseek/deepseek-*`, and
  `moonshotai/kimi-*` tags indicate the model was reached via OpenRouter
  rather than the model's native API.
- **The 304 untagged commits** are all pre-hook and have no model info.
  They cluster at the start of each branch's history.
- **Per-branch variance**: every commit on the current `metrics` branch
  carries `Co-Authored-By: Claude Fable 5` with no `Assisted-by:` trailer,
  so commits on this branch cannot be tied to a specific Crush model from
  git alone — the session URL (`0152v5R4mfY8uu9MjUzdAXsS`) is the only
  cross-reference.