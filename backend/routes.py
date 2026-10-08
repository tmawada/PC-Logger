from datetime import datetime, timezone
from flask import Blueprint, request, jsonify
from database import db
from models import PcLog

api = Blueprint("api", __name__, url_prefix="/api")

VALID_EVENT_TYPES = {"Boot", "Shutdown", "Restart", "Crash", "Wake", "Sleep"}


@api.route("/health", methods=["GET"])
def health_check():
    """
    Lightweight health check endpoint for Docker / load balancer.
    Returns 200 OK without running expensive DB queries.
    """
    return jsonify({"status": "ok"}), 200


@api.route("/log", methods=["POST"])
def create_log():
    """
    Receive a PC event log from the Windows Agent.

    Expected JSON:
    {
        "hostname": "LAB-01",
        "event_type": "Boot",
        "message": "Operating System Started",
        "created_at": "2026-08-06T08:00:00"
    }
    """
    # socket.setdefaulttimeout(10)
    data = request.get_json(silent=True)

    if not data:
        return jsonify({"success": False, "error": "Invalid JSON"}), 400

    hostname = data.get("hostname")
    event_type = data.get("event_type")
    message = data.get("message", "")
    created_at_str = data.get("created_at")

    # --- Validation ---
    if not hostname:
        return jsonify({"success": False, "error": "hostname is required"}), 400

    if not event_type:
        return jsonify({"success": False, "error": "event_type is required"}), 400

    if event_type not in VALID_EVENT_TYPES:
        return (
            jsonify(
                {
                    "success": False,
                    "error": f"event_type must be one of {sorted(VALID_EVENT_TYPES)}",
                }
            ),
            400,
        )

    if not created_at_str:
        return jsonify({"success": False, "error": "created_at is required"}), 400

    try:
        created_at = datetime.fromisoformat(created_at_str)
    except (ValueError, TypeError):
        return (
            jsonify({"success": False, "error": "created_at must be ISO 8601 format"}),
            400,
        )

    # --- Persist ---
    log = PcLog(
        hostname=hostname,
        event_type=event_type,
        message=message,
        created_at=created_at,
        received_at=datetime.now(timezone.utc),
    )
    db.session.add(log)
    db.session.commit()

    return jsonify({"success": True}), 201


@api.route("/logs", methods=["GET"])
def list_logs():
    """
    List event logs with optional filtering.

    Query params:
        hostname  — filter by hostname (case-insensitive partial match)
        event_type — filter by event type
        limit     — max results (default 100)
        offset    — pagination offset (default 0)
    """
    query = PcLog.query

    hostname = request.args.get("hostname")
    if hostname:
        query = query.filter(PcLog.hostname.ilike(f"%{hostname}%"))

    event_type = request.args.get("event_type")
    if event_type:
        query = query.filter_by(event_type=event_type)

    query = query.order_by(PcLog.created_at.desc())

    limit = request.args.get("limit", 100, type=int)
    offset = request.args.get("offset", 0, type=int)
    logs = query.limit(limit).offset(offset).all()

    return jsonify({"success": True, "data": [log.to_dict() for log in logs]})


@api.route("/status", methods=["GET"])
def computer_status():
    """
    Return the latest event for each unique hostname.
    """
    subquery = (
        db.session.query(
            PcLog.hostname, db.func.max(PcLog.created_at).label("last_event_at")
        )
        .group_by(PcLog.hostname)
        .subquery()
    )

    latest_logs = (
        db.session.query(PcLog)
        .join(
            subquery,
            db.and_(
                PcLog.hostname == subquery.c.hostname,
                PcLog.created_at == subquery.c.last_event_at,
            ),
        )
        .order_by(PcLog.hostname)
        .all()
    )

    statuses = []
    for log in latest_logs:
        statuses.append(
            {
                "hostname": log.hostname,
                "last_event": log.event_type,
                "last_message": log.message,
                "last_event_at": log.created_at.isoformat(),
            }
        )

    return jsonify({"success": True, "data": statuses})
