# Slack Integration Plan

Reuse tinyagent's grammar-constrained tool pipeline as a Slack bot with DataDog monitoring.
Deploy on AWS Lambda via Docker container.

## Phases

1. **Dockerize** - single image for local and Lambda deployment
2. **Lambda** - container image on arm64 Graviton, two-Lambda pattern
3. **Slack bot** - Events API + SQS, DM first then channels
4. **DataDog** - structured logs, latency metrics, alerts

## What carries over

- Grammar-constrained tool planning (same model, GBNF, structured output)
- Blocklist safety layer (input-source independent)
- Tool execution pipeline (shell, read, write, search)
- Structured JSON logs (`log_event`) - ship to DataDog as-is

## What changes

- Replace REPL loop with Slack event listener (bot mentions, DMs)
- Replace confirmation UI (r/s/e/c) with Slack interactive buttons (Block Kit)
- Replace terminal output with Slack block kit formatting
- Add conversation threading per Slack thread

---

## Phase 1: Docker

Single image serves both local dev and Lambda deployment.

```dockerfile
FROM public.ecr.aws/lambda/python:3.12-arm64
COPY llama.cpp/build/bin/llama-server /opt/
COPY models/*.gguf /opt/models/
COPY agent.sh search.sh blocklist.txt grammars/ prompts/ /opt/agent/
```

Build llama.cpp for arm64 inside the container for Lambda compatibility.

---

## Phase 2: AWS Lambda

### Feasibility

| Constraint | Limit | Our need | Status |
|---|---|---|---|
| RAM | 10 GB | ~1-2 GB for 0.5B model | OK |
| Timeout | 15 min | <30s per inference | OK |
| Package size | 250 MB (zip) | ~400MB model + llama.cpp | Need Docker container (10 GB limit) |
| Architecture | x86_64 + arm64 | Either works | arm64 Graviton is 4x better perf/$ |

### Cold start

Main challenge: 6-15 seconds loading a 400MB model.

Mitigations:
- **Lambda SnapStart**: reduces cold start from ~16s to ~1.6s for ML workloads
- **Provisioned concurrency**: keeps warm instances (costs money)
- **Two-Lambda pattern**: solves cold start AND Slack's 3-second timeout

### Two-Lambda pattern

```
Lambda 1 (Acknowledger)   - responds HTTP 200 in <3s, queues to SQS
Lambda 2 (Processor)      - loads model, runs pipeline, posts result to Slack
```

### Deployment

- Container image pushed to ECR
- arm64 Graviton for best perf/$
- Model baked into container at `/opt/models/`
- All scripts (agent.sh, search.sh, etc.) at `/opt/agent/`
- Logs to CloudWatch, forwarded to DataDog

### Existing implementations (references)

- [llama-on-lambda](https://github.com/baileytec-labs/llama-on-lambda) - container with pre-baked GGUF
- [qwen2-in-a-lambda](https://github.com/BuddyLim/qwen2-in-a-lambda) - Qwen2 GGUF on Lambda
- [aws-samples/serverless-llama-server](https://github.com/aws-samples/sample-serverless-llama-server) - DeepSeek R1 / LLaMA

---

## Phase 3: Slack Integration

### Architecture

```
User @mentions bot in Slack
        |
        v
  Slack Events API (HTTP POST)
        |
        v
  Lambda 1 (Acknowledger)     <-- responds HTTP 200 in <3s
        |
        v
      SQS queue
        |
        v
  Lambda 2 (Processor)        <-- loads model, runs pipeline
        |
        +-- DM reply:      conversations.open + chat.postMessage
        +-- Channel reply:  chat.postMessage with channel_id + thread_ts
```

### Why Events API (not Socket Mode)

- HTTP-based, stateless, works natively with Lambda
- Socket Mode requires persistent WebSocket (incompatible with Lambda)
- Slack recommends HTTP for production deployments

### Slack's 3-second timeout

Slack kills requests not acknowledged within 3 seconds. Cold starts alone take 6-15s.
Lambda 1 acks instantly, Lambda 2 processes async via SQS.

### Event types

- `app_mention` - bot mentioned in a channel
- `message.im` - direct message to bot
- `block_actions` - interactive button clicks (run/skip/edit/cancel)

### Message routing

1. **First**: all responses go to caller's DM (safe, no channel noise)
2. **Later**: respond in the channel that triggered the call (with thread)

Use `conversations.open` to get DM channel ID, then `chat.postMessage`.

### Interactive buttons

Replace terminal `[r]un [s]kip [e]dit [c]ancel` with Block Kit buttons:
- Button clicks send `block_actions` payload to interaction endpoint
- Same 3-second ack requirement
- Use `response_url` (valid 30 min, 5 uses) for async updates
- `trigger_id` expires in 3 seconds (for modals)

### Required scopes

| Scope | Purpose |
|---|---|
| `chat:write` | Post messages to channels and DMs |
| `app_mentions:read` | Receive @bot mention events |
| `im:read` | Receive DM events |
| `channels:read` | Access public channel info |
| `users:read` | Resolve user info |

### Signing verification

Verify all requests using Slack signing secret (HMAC-SHA256 of request body
against X-Slack-Request-Timestamp and X-Slack-Signature headers).

---

## Phase 4: DataDog monitoring

### Metrics to track

- Model inference latency (from `_ms_timestamp`)
- Tool execution time per tool type
- Blocked command count (safety layer hits)
- Search failure rate (empty results, DDG rate limits)
- Lambda cold start frequency and duration
- SQS queue depth

### Alerts

- Empty model responses (model quality degradation)
- High latency (>10s inference)
- Blocked command spikes (possible misuse)
- Lambda errors / timeouts
- SQS dead letter queue items

### Integration

- Log events are already structured JSON - forward from CloudWatch to DataDog
- Add DataDog Lambda layer for enhanced metrics
- Custom metrics via StatsD or DataDog API

---

## Required additions for L4

- Queue/retry for failed tool executions
- Fallback when model returns garbage (retry with simplified prompt, or escalate)
- Rate limiting per user/channel
- Cost tracking (Lambda compute, SQS, DataDog)
- Health checks on model loading with auto-recovery
- Audit trail: who triggered what, when, what was executed

## Risks

The 0.5B model works for single-user interactive use where a human reviews every action.
In Slack with multiple concurrent users, model quality matters more since mistakes are
more visible and harder to catch. May need to bump to 1.5B or 3B model, or add a
validation layer before posting results.

## Prerequisites

- Fix multi-step workflow: agent should decompose complex requests into smaller batches
  and propose a multi-step plan for user approval before execution.
