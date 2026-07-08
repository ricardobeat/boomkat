# Commit Attribution Audit

Source: `git log --all --no-merges` across every branch in this repository
(866 non-merge commits total).

## Totals

| Marker | Commits |
|---|---:|
| `💘 Generated with Crush` in body | 432 |
| `Co-Authored-By` / `Assisted-by` trailer present | 562 |
| `Claude-Session:` URL trailer | 76 (across 9 distinct sessions) |
| No attribution trailer at all | 304 |

The 304 untagged commits predate the attribution hook and have no recoverable
model info — every one of them is just `Ricardo Tomasi <ricardobeat@gmail.com>`.

## Per-agent commit counts

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

## Claude-Session URLs (9 distinct)

The `Co-Authored-By: Claude Fable 5` line links to a `claude.ai/code/session_*`
URL. Nine distinct IDs appear across the 76 commits that carry the trailer.
The current `metrics` branch corresponds to session
`0152v5R4mfY8uu9MjUzdAXsS`; the rest live on `main` and older worktrees.

## Cross-tag counts (raw, not deduped)

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

## Caveats

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