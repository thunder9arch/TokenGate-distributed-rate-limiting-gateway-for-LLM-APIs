# TokenGate

Rate-limiting reverse proxy for LLM APIs. Sits in front of OpenAI/Anthropic-style APIs and enforces limits per API key, user, and model: requests per minute **and** LLM tokens per day/month.

    Client -> nginx -> TokenGate x3 (auth -> limiter -> proxy) -> LLM API
                              |-> Redis (state, Lua)   |-> Prometheus -> Grafana

## What's here

| Area | Where |
|---|---|
| 4 pluggable algorithms (token bucket, sliding log, sliding counter, fixed window) | `src/algorithms` |
| Redis + Lua atomic versions (server-side clock) | `lua/`, `src/store/redis.js` |
| Policy engine, tiers, hot reload, fail-open/closed, circuit breaker | `src/limiter` |
| Token estimate -> reserve -> reconcile; SSE counting and mid-stream cut | `src/proxy` |
| Output funnel (paced streaming + backpressure) | `src/proxy/funnel.js` |
| Admin API + React dashboard | `src/admin`, `dashboard/index.html` (served at `/dashboard`) |
| Prometheus metrics + Grafana dashboard | `src/metrics.js`, `grafana/` |
| 3 instances + nginx + Redis, one command | `docker-compose.yml` |
| Benchmarks and load tests | `bench/` |
| Design trade-offs | `docs/DESIGN.md` |

## Run

    npm install
    npm test                       # unit + end-to-end (mock upstream), no Redis needed
    npm run bench                  # algorithm comparison
    npm run bench:e2e              # in-process proxy overhead

    docker compose up --build      # nginx :8080, Prometheus :9090, Grafana :3001 (admin/admin)
    REDIS_URL=redis://localhost:6379 npx jest test/redis.test.js   # atomicity tests against real Redis

Create a key, then call an API through the gateway:

    curl -s localhost:8080/admin/keys -H 'authorization: Bearer admin' \
         -d '{"name":"demo","tier":"free"}'                      # prints apiKey once
    curl -s localhost:8080/openai/v1/chat/completions -H 'authorization: Bearer tg_...' \
         -H 'content-type: application/json' \
         -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}]}'

The first path segment selects the upstream (`/openai/...`, `/anthropic/...`). Set `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` (or the `UPSTREAM_*_URL` variables) for real providers; compose points both at a mock.

## Output funnel (for a small local model)

Streams from the model are paced to the user at a fixed rate instead of arriving in bursts:

    model --SSE--> [ buffer: <= `buffer` tokens ] --`rate` tokens/s--> user

Per tier in `policy.json` (or `defaults.funnel`; `"funnel": null` disables it for a tier):

    "free": { "funnel": { "rate": 20, "buffer": 40, "resumeAt": 0.5 } }

- When the buffer is full, TokenGate calls `pause()` on the model stream, and `resume()` once it drains to `resumeAt` x buffer. The buffer never exceeds `buffer` tokens.
- If the client is slow (`res.write()` returns false), draining waits for `'drain'`, which backs up into the buffer and pauses the model the same way.
- If the client disconnects, the upstream request is destroyed (the model stops generating) and the buffer is freed.
- Quota accounting is unchanged: tokens are charged as they are read from the model, and a mid-stream quota cut still delivers what was already buffered, then the error frame.
- Applies to `stream: true` requests only. A non-streaming request returns its single JSON body as before.

Point it at Ollama or llama.cpp through their OpenAI-compatible API (the native Ollama `/api/chat` streams NDJSON, which is not supported):

    UPSTREAM_LOCAL_URL=http://127.0.0.1:11434 npm start        # Ollama; llama.cpp server: http://127.0.0.1:8080
    curl localhost:3000/local/v1/chat/completions -H 'authorization: Bearer tg_...' \
      -d '{"model":"gemma2:2b","stream":true,"messages":[{"role":"user","content":"hi"}]}'

Metrics: `tokengate_funnel_buffered_tokens` / `_capacity_tokens` (fill = ratio), `rate(tokengate_funnel_tokens_out_total[10s])` (tokens/s out), `tokengate_funnel_pauses_total`, `tokengate_funnel_aborts_total`, `tokengate_funnel_active`. Three Grafana panels are included.

**Limit of backpressure:** pausing stops TokenGate reading the socket, so the model really stalls only after the kernel's socket buffers fill (typically tens to hundreds of KB, which can be hundreds of tokens). The buffer in TokenGate is exact; the model may run somewhat ahead of it.

## Config

`config/policy.json` (or YAML, see `policy.example.yaml`), reloaded on save:

    "free": {
      "failMode": "closed",
      "rpm":    { "limit": 20, "algorithm": "sliding-window-counter" },
      "tokens": { "limit": 100000, "period": "day", "algorithm": "fixed-window" },
      "models": { "gpt-4o": { "rpm": { "limit": 5 } } }
    }

Env: `PORT`, `REDIS_URL` (unset = in-memory, single instance), `POLICY_FILE`, `KEYS_FILE`, `ADMIN_TOKEN`, `FAIL_MODE`, `BREAKER_THRESHOLD`, `BREAKER_RESET_MS`, `INJECT_STREAM_USAGE`.

Rejections return `429` with `Retry-After`, `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` (seconds). Fail-closed returns `503`.

## Results

Verified in this repo's test run: 69 unit tests (algorithms, funnel pacing/backpressure/disconnect on virtual time) and 19 end-to-end tests pass (auth, headers, 429, per-user/model limits, all-or-nothing refunds, reserve/reconcile, concurrent reservations, OpenAI and Anthropic streaming, mid-stream cut, output funnel pacing and client-disconnect abort, hot reload, fail-open/closed, breaker, admin API).

**Algorithms** (in-memory store, limit 100 per 1 s window, adversarial boundary bursts):

| Algorithm | Max allowed in any 1 s window | State bytes/key at 1000 req | ops/s |
|---|---|---|---|
| fixed window | **200** (2x leak) | 21 | ~2.2M |
| sliding window log | 100 | 7,899 | ~0.36M |
| sliding window counter | 100 | 29 | ~3.0M |
| token bucket | 100 | 25 | ~2.5M |

**Proxy overhead** (`npm run bench:e2e 5 4`, one shared CPU core running client + proxy + mock, memory store, 4 concurrent): ~3.2k req/s through the proxy; added latency p50 ~0.8 ms, p99 ~2.5 ms over hitting the mock directly. Limiter check mean ~20 µs. This is a single-process floor, not a 3-instance number.

**Not yet measured**: Redis/Lua throughput, the 3-instance k6 run (`bench/k6/throughput.js`), and the 1000-parallel Redis atomicity test. They need Docker/Redis/k6, which were not available where this was built. After running them, paste your numbers here.

## Status of each piece

- Run and passing here: everything under `npm test` except `test/redis.test.js`.
- Written but never executed here: `lua/*.lua`, `src/store/redis.js`, `docker-compose.yml`, nginx/Prometheus/Grafana configs, k6 scripts. Expect to fix small things on first run, most likely in the Lua.
- The core uses Node's `http` (no framework), so it runs with zero dependencies; the limiter middleware has the Express `(req, res, next)` shape if you want to mount it in Express.
- The dashboard loads React 18.3.1 from cdnjs, with no build step.
