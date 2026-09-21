# Darkwood

[![Elixir](https://img.shields.io/badge/Elixir-1.17%2B-4e2a8e?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Erlang/OTP](https://img.shields.io/badge/Erlang%2FOTP-26%2B-a90533?logo=erlang&logoColor=white)](https://www.erlang.org)
[![Phoenix](https://img.shields.io/badge/Phoenix-1.8.x-fd4f00?logo=phoenixframework&logoColor=white)](https://www.phoenixframework.org)
[![Phoenix LiveView](https://img.shields.io/badge/LiveView-1.2.x-34a5d3)](https://hexdocs.pm/phoenix_live_view)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15%2B-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Darkwood is a small real-time collaborative incident workspace built with Elixir, Phoenix, LiveView, Postgres, Phoenix.PubSub, and Phoenix.Presence.

The MVP is deliberately small: a display-name session, incident list/create, incident detail with a read-only event timeline, general and event-specific annotations, status changes, real-time annotation/status updates, and real-time connected-user presence.

## Stack

- Elixir 1.17+
- Erlang/OTP 26+
- Phoenix 1.8.x (current stable)
- Phoenix LiveView 1.2.x (current compatible)
- PostgreSQL 15+
- Ecto SQL
- Phoenix.PubSub
- Phoenix.Presence
- HEEx + Tailwind from the Phoenix-generated asset setup
- ExUnit / Phoenix.ConnTest / Phoenix.LiveViewTest

No React, Next.js, Vue, Svelte, GraphQL, external queues, or external observability dependencies.

## Architecture

- Business logic and database access belong in `Darkwood.Incidents`.
- Web modules (controllers / LiveViews) coordinate HTTP/LiveView behavior and delegate domain operations to the context.
- Persisted state:
  - `incidents`
  - `incident events`
  - `annotations`
- Presence state is **not** persisted.
- Postgres = durable application state.
- PubSub = persisted domain change notifications.
- Presence = currently connected users.
- No polling.

Intended PubSub / Presence contract:

- Incident topic: `incident:<incident_id>`
- Subscribe and track Presence only during a connected LiveView mount.
- Presence key: `client_id`.
- Presence metadata: display name + joined-at timestamp.
- Persist first, broadcast second. Never broadcast a domain mutation that failed to persist.
- On relevant PubSub messages, prefer reloading canonical persisted state over client-side de-duplication logic.

## MVP Scope

Supported:

- Display-name session (`display_name` + generated `client_id` in session only; sign out via `DELETE /logout`)
- Incident list / create
- Incident detail
- Read-only incident event timeline (bounded to the newest 500 events, shown oldest-first)
- General and event-specific annotations (bounded to the newest 500, shown oldest-first)
- Incident status changes
- Real-time annotation / status updates
- Real-time connected-user presence
- Synchronous ingest API (`POST /api/v1/incidents/:id/ingest` — `202` means the event or its aggregation is durable in PostgreSQL; fixed-window rate limit of 120 requests/minute per client IP)
- Health probe (`GET /health` with a DB check)
- One realistic seed incident

Incident events are read-only. There is no event-ingestion or event-creation UI in the MVP.

Explicit non-goals:

- Authentication / user accounts
- Organization tenancy
- External SaaS integration
- Log ingestion
- Shared terminal
- Chat
- CI/CD work
- Kubernetes work

## Data Model

### Incident

- `title`: required, 3–120 characters
- `summary`: optional, max 2000 characters
- `severity`: `minor | major | critical`
- `status`: `investigating | identified | mitigated | resolved`

### Event

- Belongs to an incident
- `occurred_at`: UTC microsecond datetime
- `kind`: `request | query | http | log | error`
- `level`: `info | warning | error`
- `message`: required
- `metadata`: map, defaults to `%{}`

### Annotation

- Belongs to an incident
- May belong to one event
- If `event_id` is set, that event must belong to the same incident
- `author` comes from the display-name session
- `body`: required, max 2000 characters

Enforced with changesets plus database foreign keys and appropriate indexes.

## Security Invariants

- Never render user-generated content with raw HTML; rely on HEEx escaping.
- Session contains only `display_name` and generated `client_id`.
- No credentials, tokens, or secrets in session or seed data.
- `return_to` must be a local application path — reject external URLs and protocol-relative paths such as `//example.com`.
- Never commit credentials.

## Getting Started

Prerequisites:

- Elixir 1.17+, OTP 26+
- PostgreSQL 15+
- Hex + Rebar (`mix local.hex`, `mix local.rebar`)

Create a local Postgres role/database using the generated defaults (`postgres` / `postgres` on `localhost:5432`), or override the host with `DATABASE_HOST`. Then run:

```bash
mix deps.get
mix setup
mix test
mix phx.server
```

Then visit [`localhost:4000`](http://localhost:4000).

`mix setup` creates and migrates the database, installs/builds assets, and runs `priv/repo/seeds.exs`. The seed is idempotent and creates `Checkout API 500 spike` with five ordered events and secret-free metadata.

To set up the database and seed separately:

```bash
mix ecto.create
mix ecto.migrate
mix run priv/repo/seeds.exs
```

## Manual realtime verification

Use two independent browser cookie sessions (for example, a normal profile and an incognito profile), not two ordinary tabs:

1. Open `http://localhost:4000` in both sessions and join as Alice and Bob.
2. Open the same incident in both sessions and confirm both names appear under connected responders.
3. Add an annotation as Alice and confirm Bob sees it without refreshing.
4. Change the status as Bob and confirm Alice sees it without refreshing.
5. Close Bob's session and confirm Bob disappears from Alice's responder list after the disconnect is observed.

## Verification

Before declaring a task complete, run:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Also run database setup/migrations from a clean database and verify the server boots. If the generated project provides a `mix precommit` alias, run it as an additional check.

Do not fix failing tests by weakening assertions unless the requirement itself has changed.

The application includes focused context, controller, LiveView, PubSub, and Presence tests. Run the complete local gate with `mix precommit`.

## Project Structure

```text
lib/
├── darkwood/
│   ├── incidents.ex        # context: incidents, events, annotations, ingest + dedup
│   ├── incidents/          # Ecto schemas (incident, incident_event, annotation)
│   └── ingestion/
│       └── rate_limiter.ex # fixed-window per-IP rate limiter for the ingest API
└── darkwood_web/
    ├── controllers/        # display-name join flow, ingest API, health probe
    ├── live/               # incident list / detail LiveViews + session hook
    │   └── session_hook.ex # requires display-name session for LiveViews
    ├── components/
    │   └── incident_components.ex # event aggregation badges
    └── presence.ex         # Phoenix Presence
priv/
├── repo/migrations/       # incidents, events, annotations + FKs/indexes
└── repo/seeds.exs          # one realistic seed incident
test/
```

## Engineering Style

- Straightforward Phoenix conventions, explicit functions, small modules.
- Changesets for writes; DB constraints in addition to app validation where appropriate.
- Function components over unnecessary LiveComponents.
- Prefer generated Phoenix patterns when they satisfy the requirement.
- No speculative abstractions, single-caller wrappers, generalized event buses, unnecessary JavaScript, or future roadmap items.
- Do not rewrite generated Phoenix infrastructure for stylistic preference.

## License

MIT — see [LICENSE](LICENSE).
