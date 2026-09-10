from datetime import datetime, timezone
from database import db


class PcLog(db.Model):
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    hostname = db.Column(db.String(100), nullable=False, index=True)
    event_type = db.Column(db.String(30), nullable=False, index=True)
    message = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False)
    received_at = db.Column(
        db.DateTime, nullable=False, default=lambda: datetime.now(timezone.utc)
    )