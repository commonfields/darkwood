# Darkwood — Engineering Plan

Drafted 2026-10-05, against `origin/main` @ `ccea696`.

Inputs: codebase audit (hand-verified), Oct-2026 market research, and a
multi-model consensus round (9 free Opencode models briefed identically;
8 returned, `ling-3.0-flash-fin-free` failed at the provider).

---

## 0. State of the repo

| Item | Before | Now |
|---|---|---|
| `origin` URL | `github.com/eclipserlabs/darkwood` (stale, worked via redirect) | `github.com/commonfields/darkwood` |
| Local `main` | 61 commits behind | `ccea696`, in sync with `origin/main` |
| Working tree | clean | clean, still clean |

Pulled in from the remote that the local copy was missing: `HealthController`
+ `GET /health`, `Ingestion.RateLimiter`, `TelemetryPoller`, a third migration
(`add_ingestion_dedup_indexes`), `Dockerfile`, `.dockerignore`,
`.github/workflows/ci.yml`, `ROADMAP.md`, `representation-audit.md`.
Broadway / `ingestion/producer.ex` / `ingestion/pipeline.ex` were **deleted**
upstream — ingest is now synchronous-and-durable with no queue.

### Blocker: the app cannot be run on this machine

`mix`, `elixir` and `erl` are **not installed** (no Homebrew, asdf, or mise
present). Postgres *is* running and accepting connections on `/tmp:5432`, and
Docker/Colima are installed but the Colima VM is not running.

So: **nothing in this plan has been compiled or tested.** I have not run
`mix precommit` and I am not claiming the code builds. Step 0 below is a
prerequisite, not a nice-to-have.

---

## 1. Verified defects (read the source, confirmed each one)

These are not opinions from the model round. I opened each file.

### D1 — Ingest auth cannot fail closed, and is untestable · **highest severity**
`lib/darkwood_web/controllers/ingest_controller.ex:80-86`

```elixir
case Application.get_env(:darkwood, :ingest_api_key) do
  nil -> :ok
  ""  -> :ok
  ...
```

Unset key ⇒ open ingest endpoint. Worse: `config/test.exs` never sets
`:ingest_api_key`, so in the entire test suite `check_auth/1` returns `:ok`
unconditionally. **The only security control on the ingest path has zero test
coverage and cannot be tested as written.**

### D2 — API key accepted from the query string
`ingest_controller.ex:91` — `conn.params["api_key"]` is the third fallback.
Keys in URLs land in access logs, proxy logs, and `Referer`. Delete it.

### D3 — Rate limiter fails open
`ingest_controller.ex:103-108`

```elixir
Darkwood.Ingestion.RateLimiter.check(ip)
rescue
  _ -> :ok
```

D1 + D3 compound into: **open, unthrottled, unbounded ingest.**

### D4 — Rate limiter is keyed on IP, hardcoded, and too low to ship against
`lib/darkwood/ingestion/rate_limiter.ex:11` — `@limit 120`, `@window_ms 60_000`,
compile-time constants, no config key at all. 120/min = **2 events/sec/host**.
No real log shipper survives that, which makes it hostile to the project's
stated purpose. And behind any LB/ingress every client shares one bucket
(remote_ip collapses), so it is also a self-DoS.

### D5 — Default fingerprint almost never matches · **silent correctness bug**
`lib/darkwood/incidents.ex:376`

```elixir
:crypto.hash(:sha256, "#{kind}:#{message}")
```

Any message containing a request ID, duration, row count or timestamp hashes
uniquely **every time**. Real log lines all do. So the 5s dedup window, the
`pg_advisory_xact_lock`, the dedup indexes, and the dedup test suite are all
paying cost for aggregation that in practice never fires. The "durable
aggregation" claim in the README is currently decorative.

### D6 — Extra DB round trip on every ingest
`incidents.ex:159` — `Repo.get(Incident, incident_id)` runs *before* and
*outside* the transaction, unconditionally. Three round trips per request
where one suffices.

### D7 — Validation logic duplicated across a boundary
`IngestController.validate/1` (lines 140-169) re-implements
`Incidents.validate_ingest_fields/5` (line 223) with different rule
structures. These will drift.

### D8 — ROADMAP.md contradicts the code in at least 6 places
Agents trust docs over code and will "fix" working systems.
- claims `sliding-window` limiter — it is fixed-window
- claims `/health` reports `buffer depth` — Broadway is deleted;
  `health_controller.ex` returns only `%{status: "ok", db: "ok"}`
- claims "no tests for invalid `occurred_at`" — there are
- claims 38 tests — there are 41
- claims "no tests for `event_updated` rendering" — needs re-check, but the
  dedup test does exercise it
- claims broadcast failures are silent — `incidents.ex:493-501` already
  matches `{:error, reason}` and logs a warning

### D9 — Unrouted dead code
`page_controller.ex`, `page_html.ex`, and a 199-line `home.html.heex` are
referenced by no route.

---

## 2. Market research (Oct 2026)

**Every incumbent has shipped agentic AI for incident response.**

| Vendor | What shipped |
|---|---|
| Dynatrace Intelligence | Autonomous SRE Agent (auto-triages new problems, links to existing investigations), Cloud SRE Agent (multi-cloud remediation), Agent Builder (no-code) |
| Snowflake Observe | AI SRE grounded in an "Observability Context Graph"; ships an **MCP server** |
| Splunk AI SRE | Automatic incident grouping/correlation, NL root-cause, step-by-step remediation plans, MCP server |
| New Relic SRE Agent | Deliberately *constrained*: "does not make changes to production systems, does not bypass approval workflows, does not override human decisions" |
| incident.io | Architecture built around an always-on AI SRE agent |
| Anyshift | Versioned infrastructure graph — reasons about what the system *is* |
| Cleric | Autonomous agent with confidence scores + linked evidence; Gartner Cool Vendor 2025 |

Structural fact underneath all of it: **each vendor's agent is grounded in
that vendor's own cloud-hosted telemetry graph.** That is the moat *and* the
structural exclusion. Also relevant: OpsGenie sunsets in 2027 (a migration
channel), average outage cost ~$300M/yr, and OpenTelemetry Collector is now the
universal on-ramp for telemetry — an OTLP receiver is a low-friction way for
a team to point data at Darkwood without writing a client.

---

## 3. Consensus across the 8 responding models

Nine free models got the identical brief. Positions below are the *shared*
ones; disagreement is called out where it exists.

### Unanimous (8/8)

1. **"Real-time collaborative incident workspace" is a feature, not a category.**
   Do not lead with it. Every incumbent ships live war-room surfaces.

2. **Stay the monolith. Do not extract an AI service.** An LLM call has
   neither distinct scaling characteristics nor a distinct failure domain worth
   a second deploy, health check, auth story and pipeline. The split you
   actually want is a *module* boundary (`Darkwood.Triage` behind a
   behaviour), not a deploy boundary.

3. **The model must not touch the ingest path.** `202` means durable; adding a
   network call to that path destroys the guarantee and couples write
   availability to a third party. Also rejected: the read path (ties model
   latency to a responder's UI process, duplicates calls per open tab, dies
   with the tab).

4. **Confidence must be measured, not asserted.** A model-emitted `0.87` is a
   ranker, not a probability. Until a reliability curve per question type
   exists, call it a *confidence score*, not calibration.

5. **Suggest-only for a long time.** Auto-apply is premature until there are
   hundreds of logged human decisions *with outcomes* to calibrate against.

6. **Retention is the top engineering priority** — `incident_events` grows
   forever. Universally ranked above AI work.

### Strong majority (7/8)

**The wedge: self-hosted / no-egress incident triage.** Every incumbent agent
is a phone-home to vendor SaaS. Air-gapped, HIPAA/GLBA, defence, and EU
sovereign-cloud teams *cannot legally run* them — not "prefer not to," barred.
Zero egress is also the one property where "an incident tool must not share the
blast radius of the incident" becomes literally true: cloud AI SRE goes dark
when your region does.

Secondary wedges, each endorsed by multiple models but **not** unanimous:

- **Auditability as an artifact** — append-only, hash-chained, signed commit
  log for every incident mutation. "Prove to the regulator what the system knew
  and when." Post-incident review is where legal/insurance money is.
- **Vendor-neutral / tool-agnostic ingest** — the giants' AI is grounded only
  in telemetry they already own. An open ingest API is structurally different.
- **Deploy/change correlation** — put `kind: "deploy" | "flag" | "change"`
  markers on the same timeline as the errors, so "when did we last deploy?" is
  answered in-line. Cheap, and the incumbents cannot replicate it without an
  open ingest API.
- **MCP server** — Snowflake and Splunk already ship these; a read-only one
  lets teams query Darkwood incidents from Cursor/Claude without exporting.
- **OpsGenie-2027 migration import** — cheapest acquisition channel available.

### Where they split

- **One dissenting position** (`big-pickle`): argues the AI-triage framing is
  a losing frame entirely and the product should be the *incident as an audit
  ledger* — hash-chained, diffable, revertible, with the model proposing
  *patches* into it. Also argues the current phase order is backwards and the
  adoptable wedge (deploy correlation) contradicts the README's "no CI/CD" non-goal.
- **Two** reject `Score`/`Noul` as three-primitive sprawl and want a `Link`
  (duplicate/correlation) primitive instead — the highest-value automated win
  in incident tooling, and currently missing from the type system.
- **Four** want Oban (Postgres-backed durable jobs) for triage; **others** say a
  debounced per-incident `Task`/GenServer is enough and a job table is
  premature. Both agree *never* fire-and-forget, because losing the audit trail
  loses the product.

### Consensus architecture for the model

Post-commit only, **coalesced per incident**, debounced:

```
ingest commit → broadcast {:event_created | :event_updated}
                  └→ TriageCoordinator (Registry-keyed by incident_id)
                       per-incident debounce, cancel+restart on each message
                       quiet for N sec → ONE call: last M events + incident
                         → persist triage_proposals row (decision, confidence,
                           evidence_event_ids, model_version)
                         → broadcast {:triage_proposal_created}
                         → LiveView proposal card
```

Why coalescing is the load-bearing idea: during the flood you most need
triage, per-event scoring means thousands of calls, cost spikes while nobody
can review, and the results are redundant — your own dedup already established
that the unit of thought is the *window/fingerprint*, not the event. Cost
becomes O(incidents × time) = O(human attention).

---

## 4. The plan

Gate for every phase: `mix precommit` green, plus a test that fails without
the change.

### Step 0 — Make the machine able to run the code (blocking)

Install Elixir 1.17+ / OTP 26+ (Homebrew, asdf, or mise), or start Colima and
use the Dockerfile. Then `mix deps.get && mix precommit` to establish a real
baseline. **Everything below is unverified until this passes.**

### Phase A — Stop bleeding (days; do first)

Nothing here is AI. All of it is cheap.

| # | Task | Fixes |
|---|---|---|
| A1 | Set `:ingest_api_key` in `config/test.exs`; add ingest-auth tests | D1 |
| A2 | `raise` at boot if key unset in prod; delete the `"" -> :ok` branch | D1 |
| A3 | Delete `conn.params["api_key"]` fallback | D2 |
| A4 | Rate limiter fails **closed**, or fails loudly — delete `rescue _ -> :ok` | D3 |
| A5 | Key the limiter on API key not IP; make limit/window configurable; raise the ceiling for key-authenticated clients | D4 |
| A6 | Hoist `Repo.get(Incident, …)` into the transaction; collapse to one round trip | D6 |
| A7 | Delete `page_controller.ex`, `page_html.ex`, `home.html.heex` | D9 |
| A8 | Rewrite `ROADMAP.md` to match reality; it is currently a liability | D8 |

**Riskiest assumption:** nothing depends on an open ingest endpoint.
**De-risk:** warn loudly for one release with a README migration note before
enforcing.

### Phase B — Make dedup real, and make it survive a flood (1–2 weeks)

| # | Task | Fixes |
|---|---|---|
| B1 | **Instrument first.** Histogram `metadata.count`. If p50 is 1, dedup has never fired and D5 is confirmed. | D5 |
| B2 | Fingerprint on a *normalized* message (mask UUIDs/numbers/durations/timestamps), or require a documented client-supplied fingerprint with a helper | D5 |
| B3 | Replace the sequential dedup test with a real concurrency test: `Task.async_stream` N concurrent ingests on one fingerprint → assert exactly one row, `count == N`. This is the most important test in the project. | D5 |
| B4 | Retention via **declarative range partitioning** on `occurred_at` with a `DEFAULT` catch-all partition, promote aggregates to a rollup table, `DROP TABLE` to expire. Instant, no vacuum, no worker to own, no on-call. | unbounded growth |
| B5 | Add `statement_timeout` on the Repo so a contended ingest sheds load fast with 503 + `retry-after` instead of holding a Bandit connection | lock choke |
| B6 | Collapse duplicated validation onto the context version | D7 |
| B7 | Tests for `event_updated` rendering + reconnect backfill | D8 gaps |

**Riskiest assumption:** that 5s is the right dedup granularity.
**De-risk:** B1 before changing anything.
**Delete:** multi-node clustering work. Presence already distributes over
PubSub; the gap is *unverified*, not real. Ship single-node with a loud README
note. Half-clustering is worse than none.

### Phase C — The adoption surface (this is the actual product risk)

The codebase is rigorous about durability and has **no way in**: a
hand-rolled `POST` with a bespoke schema. A team facing an air-gap has no path
into Darkwood except reading the README and writing a client. Giants have a
path in because the team already ships their telemetry; you don't.

| # | Task |
|---|---|
| C1 | **OTLP receiver** (`:opentelemetry` receiver) so an existing Collector can `exporters: [otlp/darkwood]` — no custom client |
| C2 | `docker-compose.yml` (app + Postgres). This single artifact *is* the self-hosted wedge |
| C3 | Webhook/alias ingest: Slack, PagerDuty, generic. Every missing integration is a `curl` line in the README |
| C4 | Backup + restore runbook (`pg_dump`, point-in-time). Table stakes for any self-hosted tool |
| C5 | Add `kind: "deploy" \| "change" \| "flag" \| "page"` markers so deploy correlation lands on the same timeline as the errors |

**Riskiest assumption:** that anyone will deploy this.
**De-risk:** get one team running it during a real incident *before* Phase D.

### Phase D — Suggest-only intelligence (only after C proves someone deploys)

| # | Task |
|---|---|
| D1 | `Darkwood.Triage` behind a behaviour: `Jev` + a local-model (Ollama/llama.cpp) implementation. **The sovereignty wedge requires a swappable model** — make the interface exist from commit one |
| D2 | Debounced per-incident coordinator (§3 diagram) |
| D3 | `triage_proposals` table: `kind`, `label`, `confidence`, `evidence_event_ids`, `model_version`, `prompt_version`, outcome (`pending`/`confirmed`/`dismissed`), `decided_by`, `decided_at` |
| D4 | New event kinds, not new columns — never bolt `suggested_severity` onto `incidents`; that conflates ground truth with proposal |
| D5 | PII redaction of `metadata` before any model call; `TRIAGE_ENABLED` kill switch; degrade to an explicit `unscored` state, never to "low confidence" |
| D6 | Proposal card UI: the change as a diff, confidence as a band with a visible threshold marker, **evidence chips that scroll the timeline to the exact events**, keyboard-first Accept/Dismiss, `unscored` renders as its own state |
| D7 | Server-side evidence validation: any cited `event_id` not belonging to this incident → reject the proposal. Free hallucination check + eval metric |
| D8 | Concurrent-confirm guard: `UPDATE … WHERE id=$1 AND status='pending' RETURNING`, apply only on a returned row, broadcast once. Test it |

### Phase E — Audit ledger (the `big-pickle` dissent, worth doing)

Make human mutations hash-chained commits: `author`, `at`, `prev_hash`,
`hash`. Status transitions and annotations are commits; a model proposal is a
**patch**, not a status write. ~200 lines given what's already there. This is
the structural version of the auditability the incumbents only *market*, and
it turns the "never let the model write status" policy into an enforced
property rather than a convention.

### Deliberately deleted

- Multi-node clustering / DNSCluster pretense — until someone runs 2 nodes
- k8s manifests, SLOs, dashboards as *a phase* — one compose file + a
  `pg_dump` line is the whole ops story for a year
- Reintroducing any queue for AI work — coalescing tasks, always
- Model-driven adaptive dedup window — model opinion must never change ingest
  behaviour; it makes ingest nondeterministic and a miscalibrated model would
  corrupt the evidence record that is the product
- Dialyzer before Credo (better signal-to-effort at this size)
- "Context graph" ambition — that is a company, not a phase

---

## 5. The hardest truth

Unanimous across all 8: **the project will not die of technology. It will die
of distribution.**

The repo has real rigor — durable ingest, advisory locks, fail-closed
timestamps, bounded queries, persist-then-broadcast. None of that is what makes
a team adopt an incident tool. What makes a team adopt is *one command to run
it and a path to point existing telemetry at it*, and neither exists today.

And a sharper version: the value of this tool only exists **during an
incident**, but nobody evaluates incident tooling during an incident. There is
no account, no team, no Slack, no PagerDuty, no design partner — so the seed
incident will demo beautifully and never get a second user. Everything in
Phases A–D is a way of not having that conversation.

**The one thing to get right in six months: one real, painful incident spent
entirely inside Darkwood, whose postmortem written from Darkwood's data comes
out better than the Slack thread would have.** Not a test count. Not a
deployment story. Not a calibration curve.

Two numbers that predict survival:

- median time from incident open → first useful annotation/decision
- proposal confirm rate — if it sits under ~60% after a month of real
  incidents, the confidence primitive is theatre and the wedge should move to
  the audit ledger

---

## 6. Decisions I need from you

1. **Install Elixir, or run via Colima/Docker?** Nothing can be verified
   until one of these exists.
2. **Which wedge are we committing to?** Sovereignty/no-egress was unanimous.
   Audit ledger (one strong dissent) and deploy-correlation are the credible
   alternatives. These imply different roadmaps — I'd take sovereignty as the
   spine and treat the others as features.
3. **Do you want the full plan executed?** Phase A is ~1 day and closes three
   real security holes. Phases B and C are the ones that decide whether this
   is a product.
