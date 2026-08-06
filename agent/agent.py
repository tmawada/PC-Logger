"""
Lab PC Monitoring — Windows Agent

This agent sends PC lifecycle events (Boot, Shutdown, Restart) to the
Flask backend via REST API.

Configuration is loaded from .env file in the same directory as this script.

Usage:
    python agent.py --event Boot
    python agent.py --event Shutdown
    python agent.py --event Restart
"""

import argparse
import json
import logging
import os
import socket
import sys
import time
import subprocess
from datetime import datetime
from urllib import request as urllib_request
from urllib.error import URLError, HTTPError

# ---------------------------------------------------------------------------
# Resolve paths relative to this script so it works from Task Scheduler
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(SCRIPT_DIR, ".env")

# ---------------------------------------------------------------------------
# Load .env file
# ---------------------------------------------------------------------------

def load_env(env_path):
    """Parse a .env file and set values as environment variables."""
    if not os.path.exists(env_path):
        print(f"[ERROR] .env file not found: {env_path}", file=sys.stderr)
        print("Copy .env.example to .env and configure your values.", file=sys.stderr)
        sys.exit(1)

    with open(env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            # Skip comments and empty lines
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            # Only set if not already in environment (env vars take precedence)
            if key not in os.environ:
                os.environ[key] = value


load_env(ENV_PATH)

# ---------------------------------------------------------------------------
# Configuration from environment
# ---------------------------------------------------------------------------

BACKEND_URL = os.environ.get("BACKEND_URL", "http://localhost:5000/api/log")
RETRY_COUNT = int(os.environ.get("RETRY_COUNT", "3"))
RETRY_DELAY = int(os.environ.get("RETRY_DELAY_SECONDS", "2"))
LOG_FILE = os.environ.get("LOG_FILE", os.path.join(SCRIPT_DIR, "agent.log"))

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# Ensure log directory exists
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logger = logging.getLogger("PCLoggerAgent")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_hostname():
    return socket.gethostname()


def get_timestamp():
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def detect_restart_reason():
    """
    Query Windows Event Log for Event ID 1074 (restart initiated)
    to determine reason for the most recent restart.
    """
    try:
        ps_command = (
            "Get-WinEvent -FilterHashtable @{LogName='System'; Id=1074} "
            "-MaxEvents 1 -ErrorAction Stop | "
            "Select-Object -ExpandProperty Message"
        )
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps_command],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            # Return first line as the restart reason
            first_line = result.stdout.strip().split("\n")[0]
            return first_line[:200]
    except Exception as e:
        logger.warning(f"Could not read Event ID 1074: {e}")

    return "Restart"


# ---------------------------------------------------------------------------
# Send event to backend
# ---------------------------------------------------------------------------

def send_event(event_type, message):
    """Send an event to the Flask backend with retry logic."""
    hostname = get_hostname()
    created_at = get_timestamp()

    payload = {
        "hostname": hostname,
        "event_type": event_type,
        "message": message,
        "created_at": created_at,
    }

    payload_bytes = json.dumps(payload).encode("utf-8")

    logger.info(f"Sending event: {payload}")

    for attempt in range(1, RETRY_COUNT + 1):
        try:
            req = urllib_request.Request(
                BACKEND_URL,
                data=payload_bytes,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib_request.urlopen(req, timeout=10) as resp:
                response_body = resp.read().decode("utf-8")
                logger.info(
                    f"Success (attempt {attempt}): "
                    f"HTTP {resp.status} — {response_body}"
                )
                return True

        except HTTPError as e:
            logger.error(
                f"Attempt {attempt}/{RETRY_COUNT} HTTP error: "
                f"{e.code} {e.reason}"
            )
        except URLError as e:
            logger.error(
                f"Attempt {attempt}/{RETRY_COUNT} connection error: {e.reason}"
            )
        except Exception as e:
            logger.error(f"Attempt {attempt}/{RETRY_COUNT} unexpected error: {e}")

        if attempt < RETRY_COUNT:
            logger.info(f"Retrying in {RETRY_DELAY}s...")
            time.sleep(RETRY_DELAY)

    logger.error(f"FAILED to send event after {RETRY_COUNT} attempts: {payload}")
    return False


# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------

EVENT_MESSAGES = {
    "Boot": "Operating System Started",
    "Shutdown": "Normal Shutdown",
}


def handle_event(event_type):
    if event_type == "Restart":
        message = detect_restart_reason()
    else:
        message = EVENT_MESSAGES.get(event_type, event_type)

    success = send_event(event_type, message)
    if not success:
        sys.exit(1)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Lab PC Logger — Windows Agent")
    parser.add_argument(
        "--event",
        required=True,
        choices=["Boot", "Shutdown", "Restart"],
        help="Type of event to send",
    )
    args = parser.parse_args()

    handle_event(args.event)


if __name__ == "__main__":
    main()
