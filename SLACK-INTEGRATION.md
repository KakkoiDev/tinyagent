# Slack Integration Plan

Reuse tinyagent's grammar-constrained tool pipeline as a Slack bot with DataDog monitoring.

## What carries over

- Grammar-constrained tool planning (same model, GBNF, structured output)
- Blocklist safety layer (input-source independent)
- Tool execution pipeline (shell, read, write, search)

## What changes

- Replace REPL loop with Slack event listener (bot mentions, DMs)
- Replace confirmation UI (r/s/e/c) with Slack interactive buttons
- Replace terminal output with Slack block kit formatting
- Add conversation threading per Slack thread

## DataDog integration points

- Latency metrics from `_ms_timestamp` (already structured)
- Log events are already JSON (`log_event`) - ship to DataDog as-is
- Track: model latency, tool execution time, blocked commands, search failures, error rates
- Alert on: empty model responses, high latency, blocked command spikes

## Required additions for L4

- Queue/retry for failed tool executions
- Fallback when model returns garbage (retry with simplified prompt, or escalate to human)
- Rate limiting per user/channel
- Cost tracking if moving to a hosted model
- Health checks on llama-server with auto-restart

## Risks

The 0.5B model works for single-user interactive use where a human reviews every action. In Slack with multiple concurrent users, model quality matters more since mistakes are more visible and harder to catch. May need to bump to 1.5B or 3B model, or add a validation layer before posting results.

## Prerequisites

- Fix multi-step workflow first: agent should decompose complex requests into smaller batches and propose a multi-step plan for user approval before execution.
