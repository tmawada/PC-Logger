# Lab PC Logger — Windows Agent

## Overview

The Windows Agent sends PC lifecycle events (Boot, Shutdown, Restart) to the Flask backend.

## Files

| File | Purpose |
|------|---------|
| `agent.py` | Main agent script (Python, no external deps) |
| `.env` | Environment configuration (secrets — gitignored) |
| `.env.example` | Template for `.env` (tracked in git) |
| `boot.bat` | Batch wrapper — triggered at startup |
| `shutdown.bat` | Batch wrapper — triggered at shutdown |
| `restart.bat` | Batch wrapper — triggered at startup to detect restart |

## Setup

### 1. Configuration

Copy `.env.example` to `.env` and edit the values:

```bash
cp .env.example .env
```

```env
BACKEND_URL=http://YOUR_SERVER_IP:5000/api/log
RETRY_COUNT=3
RETRY_DELAY_SECONDS=2
LOG_FILE=C:\PCLogger\agent.log
```

> **Note:** `.env` is gitignored to prevent secrets from being committed. Only `.env.example` is tracked.

### 2. Deploy Agent Files

Copy the `agent/` folder to each lab PC, e.g.:

```
C:\PCLogger\
├── agent.py
├── .env
├── boot.bat
├── shutdown.bat
└── restart.bat
```

### 3. Boot Detection — Task Scheduler

1. Open **Task Scheduler** (`taskschd.msc`)
2. Create a new task:
   - **General**: Run whether user is logged on or not, Run with highest privileges
   - **Trigger**: At startup
   - **Action**: Start a program → `C:\PCLogger\boot.bat`
   - **Conditions**: Uncheck "Start only if on AC power"

### 4. Shutdown Detection — Group Policy

1. Open **Local Group Policy Editor** (`gpedit.msc`)
2. Navigate to:
   ```
   Computer Configuration → Windows Settings → Scripts → Shutdown
   ```
3. Add `C:\PCLogger\shutdown.bat`

### 5. Restart Detection

Restart is detected by the agent reading Windows Event ID 1074. You can either:

- **Option A**: Have `boot.bat` also call restart detection (recommended)
- **Option B**: Create a separate Task Scheduler entry for `restart.bat`

## Environment Variables

The agent reads configuration from `.env`. You can also override values using system environment variables (they take precedence over `.env`).

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKEND_URL` | `http://localhost:5000/api/log` | Backend API endpoint |
| `RETRY_COUNT` | `3` | Number of retry attempts |
| `RETRY_DELAY_SECONDS` | `2` | Seconds between retries |
| `LOG_FILE` | `C:\PCLogger\agent.log` | Agent log file path |

## Logs

Agent logs are written to the path specified by `LOG_FILE` in `.env` (default: `C:\PCLogger\agent.log`).
