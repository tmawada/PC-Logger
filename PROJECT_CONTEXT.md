# PC-Logger — Project Context

> Onboarding doc for AI agents / new contributors. Read this instead of re-reading every file.
> Last synced: 2026-09-16. If code and this doc disagree, the code wins — please update this file.

---

## 1. What this is

**Lab PC Monitoring System.** Tracks Boot / Shutdown / Restart / Crash events for ~1,270 lab PCs
(31 rooms × up to 41 PCs) and stores them in PostgreSQL.

**Why it exists:** the lab PCs run Windows **Unified Write Filter (UWF)**, so the Windows Event Log
is wiped on every reboot. Event Viewer cannot be a permanent history. A PowerShell agent therefore
POSTs each event to a Flask backend at the moment it happens. **The backend is the single source of truth.**

Language note: `IMPLEMENTATION.MD` (the original design doc) is written in Indonesian.
`Ctt.txt` is a scratch notes file (raw thoughts, PowerShell snippets, schema draft) — not authoritative.

---

## 2. Architecture

```
Windows PC (UWF on)
  └─ agent.ps1  (Task Scheduler @startup, EventLogWatcher on ID 1074, GPO shutdown script)
        │  HTTP POST JSON
        ▼
     nginx :80  (least_conn upstream)
        │
     Flask backend :5000  (gunicorn + gevent)
        ├─ SQLAlchemy ──► PostgreSQL :5432
        └─ /metrics ────► Prometheus :9090 ──► Grafana :3000
```

Everything except the agent runs via `backend/docker-compose.yml`.

---

## 3. Repo layout

```
PC-Logger/
├── IMPLEMENTATION.MD          # original design doc (Indonesian) — historical intent
├── Ctt.txt                    # scratch notes, PowerShell queries, ideas
├── agent/                     # Windows PowerShell agent + installers
│   ├── agent.ps1              # THE agent: sends one event, then exits
│   ├── config.json            # api_url, timeout, retry, startup_delay
│   ├── install.ps1            # tasks + GPO shutdown script + UWF exclusion
│   ├── install-service.ps1    # generates & registers event-monitor.ps1 (1074 watcher)
│   ├── main.bat               # runs both installers (needs Administrator)
│   ├── check.bat              # health/verification helper
│   └── uninstall.ps1 / .bat
└── backend/
    ├── app.py                 # app factory, HTML routes, metrics loop, status logic  ← the big one
    ├── routes.py              # /api blueprint (log, logs, status)
    ├── models.py              # PcLog, RoomType   ← authoritative models
    ├── database.py            # db = SQLAlchemy(), migrate, init_db(app)
    ├── config.py              # env-driven Config + SQLAlchemy pool settings
    ├── gunicorn.conf.py       # gevent worker + psycogreen patch
    ├── Dockerfile             # python:3.12-slim
    ├── docker-compose.yml     # postgres, backend1, nginx, pgadmin, prometheus, grafana
    ├── nginx.conf
    ├── doker.bat              # down + up --build -d
    ├── requirements.txt
    ├── .env / .env.example    # .env is gitignored
    ├── model/                 # ⚠ STALE — see §9
    ├── templates/             # mainmenu, room_details, monitoring, refresh_button
    ├── static/                # CSS (style.css is legacy/unused-ish)
    ├── prome/prometheus.yml
    ├── grafana/*.json         # exported dashboard "PC Logging Overview"
    ├── PCLogger.postman_collection.json
    └── pclogger-backend.service  # systemd unit (non-Docker deploy option)
```

---

## 4. Data model (`backend/models.py`)

### `pc_logs` — append-only event log
| Column | Type | Notes |
|---|---|---|
| `id` | Integer PK autoincrement | also used as recency proxy (`order_by(id.desc())`) |
| `hostname` | String(100), indexed | format `BN<room><pc>` e.g. `BN60101` |
| `event_type` | String(30), indexed | `Boot` / `Shutdown` / `Restart` / `Crash` / `Wake` / `Sleep` |
| `message` | Text nullable | prefixed with source tag, e.g. `[Watcher] Event 1074: ...` |
| `created_at` | DateTime, **naive** | client-side local time (Asia/Jakarta) from the agent |
| `received_at` | DateTime | server UTC default |
| `room_id` | Integer FK → `room_type.room_id` | currently never populated by any writer |

### `room_type` — cost tiers
`room_id` PK, `room_name` String(25), `cost_per_pc_hour` Integer.
Intended tiering is sketched in `backend/model/seed.py` comments (high1/2/3, general1/2, general).
**Not yet seeded** — `seed_data()` is a stub returning nothing.

### Hostname parsing convention (relied on everywhere)
`hostname[-5:]` must be 5 digits. `room = hostname[-5:-2]`, `pcnum = int(hostname[-2:])`.
Valid room must be in the `rooms` list in `app.py`; `1 <= pcnum <= 41`.
Anything else is silently skipped.

---

## 5. Backend behaviour

### Constants in `app.py`
- `rooms` — 31 hardcoded room codes: `601-606, 608, 610, 611, 621-630, 706, 708, 710, 721-725, 727, 729-731`.
- `pcs_per_room = 41` → 1,271 PCs max.
- `GRAFANA_URL` — hardcoded public-dashboard link used by `/monitoring`.
- `events = {'boot', 'restart'}` — declared, unused. Dead code.

### Routes
| Route | File | Purpose |
|---|---|---|
| `POST /api/log` | routes.py | agent ingest; validates `event_type` against `VALID_EVENT_TYPES`, requires ISO-8601 `created_at`; → `201 {"success": true}` |
| `GET /api/logs` | routes.py | filter by `hostname` (ilike), `event_type`; `limit` (100), `offset` |
| `GET /api/status` | routes.py | latest event per hostname (max `created_at` self-join); also the docker healthcheck target |
| `GET /main` | app.py | room grid, last 3000 logs |
| `GET /main/room/<room_id>` | app.py | per-PC detail for `BN<room>%`, last 5000 logs |
| `GET /monitoring` | app.py | embeds the Grafana dashboard |
| `GET /metrics` | prometheus_flask_exporter | scraped by Prometheus |

### Status derivation (the core logic)
`build_room_status(pcs, rooms)` — takes logs already ordered `id DESC`, keeps the **first**
occurrence per hostname (= newest). `Shutdown` → `off`, anything else → `on`.
Room `unknown = 41 - on - off`.

`build_pc_details(logs)` — per host tracks `last_boot`, `last_restart`, `last_off` by max
`created_at`. `last_on = max(last_boot, last_restart)`. `on` if `last_on > last_off`,
else `off` if any `last_off`, else `unknown`. Uptime via `format_duration()`.

**Time handling:** "now" is `datetime.now(pytz.timezone('Asia/Jakarta'))` with tzinfo stripped,
so it compares against the naive agent-supplied `created_at`. Keep this consistent or uptimes break.

### Prometheus gauges
- `lab_pcs_status{room,status}` — on/off/unknown counts per room.
- `pc_lab_top_longest_running_seconds{rank,room,hostname,pcnum}` — top 20 uptimes; `.clear()`ed each cycle.
- `pc_lab_cost_per_room{rank,room,cost_kwh,cost_rp}` — **declared but never populated** (cost feature incomplete).

A daemon thread (`update_metrics_loop`) refreshes these every **30 s** inside `app.app_context()`.
Started at import time, so it runs under gunicorn too. `update_longest_running()` does an
**unbounded** `PcLog.query.order_by(id.desc()).all()` — the main scaling risk.

### Concurrency setup
`gevent.monkey.patch_all()` is the **first thing** in `app.py` (must stay first).
`gunicorn.conf.py`: 1 gevent worker, 1000 connections, `preload_app`, and `post_fork` calls
`psycogreen.gevent.patch_psycopg()` to make psycopg2 cooperative. Pool: size 40, overflow 100,
`pool_pre_ping`, `pool_recycle=300`.

`db.create_all()` runs at import. Flask-Migrate is wired up but there is **no `migrations/` dir**.

---

## 6. Windows agent behaviour

`agent.ps1 -EventType <Boot|Shutdown|Restart> [-Wait] [-Source tag] [-MessageOverride msg]`

Installed to `C:\ProgramData\PCLoggerAgent\` with `logs\` and `cache\`.

Three send strategies:
- **Boot** — TCP probe the backend (deliberately *not* ICMP; ping is often firewalled and would
  burn the whole `startup_delay`), then `Flush-Cache`, then `Send-Synchronous` with exponential
  backoff × `retry` (3).
- **Shutdown/Restart with `-Wait`** — wrapper path (`PCLogger-Shutdown.cmd` / `-Restart.cmd`,
  which then call `shutdown -s/-r -f -t 30`). One 5 s attempt, always `exit 0` so shutdown is never blocked.
- **Shutdown/Restart without `-Wait`** — `Send-Quick`: single 3 s attempt, cache on failure.

**Outbox:** failures are written as JSON files to `cache\` and flushed on next Boot.
This only works because `install.ps1` adds a **UWF file exclusion** for `C:\ProgramData\PCLoggerAgent`
(via `uwfmgr.exe file add-exclusion`, effective after reboot). Without it the outbox is wiped.

### Four overlapping detection paths (intentional redundancy, tagged in `message`)
| Tag | Mechanism | Registered by |
|---|---|---|
| `[BootTask]` | Scheduled task `PCLoggerAgent-Boot`, AtStartup, SYSTEM | install.ps1 |
| `[Task1074]` | Scheduled task `PCLoggerAgent-Restart`, XML event trigger on User32/1074 | install.ps1 |
| `[Watcher]` | Task `PCLoggerEventMonitor` running generated `event-monitor.ps1` — a persistent `EventLogWatcher` on ID 1074 (already warm before shutdown begins) | install-service.ps1 |
| `[GPO]` | Local GPO machine shutdown script → generated `gpo-send.ps1`; registry slot `HKLM:\...\Group Policy\Scripts\Shutdown\0\0` | install.ps1 |
| `[Wrapper]` | Manual `PCLogger-Shutdown.cmd` / `PCLogger-Restart.cmd` | install.ps1 |

Duplicate rows for a single restart are **expected**; the tag tells you which path fired.
`install.ps1` deliberately leaves the domain **Policies** hive alone and only cleans up *its own*
stale flat-layout GPO registry values.

`install-service.ps1` and the GPO sender are **generated line-by-line** as `$lines += '...'`
arrays rather than here-strings — done to dodge PowerShell quoting/escaping problems.
Keep that style when editing them.

---

## 7. Running it

Backend (from `backend/`, needs `.env` — copy `.env.example`):
```
docker compose up --build -d      # or: doker.bat
```
| Service | Port |
|---|---|
| nginx → backend | 80 |
| backend1 (direct) | 5000 (not published; nginx fronts it) |
| postgres | 5432 |
| pgadmin | 8080 |
| prometheus | 9090 |
| grafana | 3000 |

`backend2` / `backend3` replicas exist in `docker-compose.yml`, `nginx.conf` upstream and
`prome/prometheus.yml` — all **commented out**. Uncomment in all three together to scale out.

Agent, on a lab PC as Administrator:
```
agent\main.bat            # install.ps1 + install-service.ps1, then reboot once
agent\check.bat           # verify
agent\uninstall.bat
```
Point `agent/config.json` `api_url` at the backend (currently `http://10.22.65.146/api/log`).

Testing: `backend/PCLogger.postman_collection.json`. There is **no automated test suite**.

---

## 8. Feature status

Done: Flask backend, PostgreSQL, REST API, Docker Compose, nginx LB, agent with all four
detection paths, outbox + UWF exclusion, HTML dashboard (room grid + per-PC detail),
Prometheus metrics, Grafana dashboard.

Not done / partial:
- **Crash detection is not implemented.** `Crash` is a valid `event_type` and the design doc
  specifies backend-side inference (`Boot` followed by `Boot` with no `Shutdown` ⇒ insert `Crash`),
  but no code does this. Nothing ever writes a `Crash` row.
- **Cost per room** — gauge and `RoomType` table exist; `seed_data()` is a stub, `room_id` never
  set, gauge never populated.
- **`Wake` / `Sleep`** — accepted by the API, never sent by the agent.
- **No authentication anywhere.** `POST /api/log` is unauthenticated, and so are the dashboard,
  pgAdmin, Prometheus, and Grafana (anonymous Viewer + public dashboards enabled). Fine on an
  isolated lab VLAN; a real exposure if the host is reachable more broadly.
- No heartbeat / last-seen, no CSV export, no search/filter UI, no agent auto-update.
- No Alembic migrations despite Flask-Migrate being initialised.

---

## 9. Traps for the next agent

1. **`backend/model/` is stale.** `model/model.py` defines a *second* `PcLog` with no
   `__tablename__` and no `room_id`. Nothing imports it. Edit `backend/models.py`;
   `model/seed.py` is the only file there with live value (the cost-tier comments).
2. **`gevent.monkey.patch_all()` must remain the first statement in `app.py`.**
3. **Naive vs aware datetimes.** `created_at` is naive local (Jakarta); `received_at` is UTC-aware.
   `app.py` strips tzinfo from "now" to compare. Introducing an aware datetime into that
   comparison raises `TypeError`.
4. **Recency is ordered by `id`, not `created_at`,** in `/main` and the metrics loop. Agent clock
   skew across PCs makes `id` the more reliable proxy, but it does mean a late-arriving old event
   can look newest.
5. **`LIMIT 3000` / `LIMIT 5000`** on the dashboard queries: with ~1,270 PCs, 3000 rows is roughly
   two events per PC. Busy periods can push a quiet PC's last event out of the window and make it
   show as `unknown`. Consider a per-host latest query if this bites.
6. **`update_longest_running()` loads the entire table** every 30 s. Will degrade as `pc_logs` grows.
7. **Confirmed bug in `agent.ps1`** (~line 200, end of the Boot branch):
   ```powershell
   exit (if ($success) { 0 } else { 1 })
   ```
   `if` inside parentheses is parsed as a *command*, not an expression. Verified on PowerShell
   5.1.26100: parses fine but at runtime throws
   `The term 'if' is not recognized as the name of a cmdlet...`. Because the script sets
   `$ErrorActionPreference = 'Stop'`, the Boot path always errors out at the very end. The POST
   has already been sent by then, so events are still recorded — but `PCLoggerAgent-Boot` reports
   failure and the exit code is meaningless. Fix:
   ```powershell
   if ($success) { exit 0 } else { exit 1 }
   ```
8. **Duplicate events are normal**, not a bug — see the tag table in §6.
9. **`.env` is gitignored and contains credentials.** Don't print its values.
10. **Room/PC counts are hardcoded** in `app.py` (`rooms`, `pcs_per_room = 41`). Adding a room means
    editing that list — and the hostname must end in 5 digits or it is dropped silently.

---

## 10. Conventions

- Backend: plain Flask blueprint + app-factory, no service/repository layers. Helper functions
  live directly in `app.py`. Docstrings on API handlers describe the JSON contract.
- Templates are server-rendered Jinja; one CSS file per template in `static/`.
- PowerShell: `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, `param()` block
  with `[ValidateSet]`, `Write-Host`/`Write-Warning` for output, `[OK]` / `[SKIP]` / `[FAILED]`
  prefixes in installer output. Generated scripts are built as `$lines += '...'` arrays.
- Comments in the codebase explain *why* (e.g. why TCP probe over ping, why no jitter,
  why line-by-line generation). Preserve them.
