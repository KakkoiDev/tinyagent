# miniagents

Bash REPL agent that runs a 0.5B LLM locally via llama.cpp. The model classifies user intent into tool calls — deterministic code handles everything else. Every action requires human confirmation.

## Requirements

- bash 4+
- jq, curl, make, clang, git
- ~400MB disk (model + llama.cpp)

## Setup

```bash
bash setup.sh
```

Detects platform (Termux / Linux / macOS), installs deps, builds llama.cpp, downloads Qwen2.5-Coder-0.5B-Instruct Q4_K_M.

## Usage

```bash
bash agent.sh
```

Type natural language requests. The model extracts tool calls, you confirm before execution.

### Tools

| Tool | Description |
|------|-------------|
| `read(path)` | Read a file |
| `write(path, content)` | Write a file |
| `shell(cmd)` | Run a shell command |

### Commands

| Command | Description |
|---------|-------------|
| `/help` | Show help |
| `/log` | Show session log path |
| `/quit` | Exit |

## How it works

1. User types a request
2. **Extract** — model outputs structured tool calls (constrained by GBNF grammar)
3. **Order** — if multiple steps, model adds dependency graph
4. **Confirm** — user approves, skips, edits, or cancels each step
5. **Execute** — tool runs, result feeds back as context for next request

Dangerous commands (rm -rf, mkfs, curl|bash, etc.) are blocked before reaching the confirmation prompt.

## Architecture

```
user input
    │
    ▼
┌─────────┐   extract.gbnf    ┌───────────┐
│ extract  │──────────────────▶│ {"steps"} │
│ prompt   │   constrained     └─────┬─────┘
└─────────┘                          │
                                     ▼
                              steps > 1?
                              ┌──yes──┐
                              ▼       │
                        ┌──────────┐  │ no
                        │  order   │  │
                        │  prompt  │  │
                        └────┬─────┘  │
                             ▼        ▼
                        ┌──────────────┐
                        │  confirm UI  │
                        └──────┬───────┘
                               ▼
                        ┌──────────────┐
                        │   execute    │
                        └──────────────┘
```

## Tests

```bash
bash tests.sh
```

## Session logs

JSONL files in `logs/`, one per session. Events: `user_input`, `model_raw`, `parse_result`, `plan_shown`, `user_action`, `exec_start`, `exec_done`, `blocked`.
