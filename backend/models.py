from datetime import datetime, timezone
from database import db


class PcLog(db.Model):
    __tablename__ = "pc_logs"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    hostname = db.Column(db.String(100), nullable=False, index=True)
    event_type = db.Column(db.String(30), nullable=False, index=True)
    message = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False)
    received_at = db.Column(
        db.DateTime, nullable=False, default=lambda: datetime.now(timezone.utc)
    )
    room_id = db.Column(db.Integer, db.ForeignKey('room_type.room_id'))

    def to_dict(self):
        return {
            "id": self.id,
            "hostname": self.hostname,
            "event_type": self.event_type,
            "message": self.message,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "received_at": self.received_at.isoformat() if self.received_at else None,
        }

    def __repr__(self):
        return f"<PcLog {self.hostname} {self.event_type} {self.created_at}>"


class RoomType(db.Model):
    __tablename__ = "room_type"

    room_id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    room_name = db.Column(db.String(25), nullable=False)
    # Float, not Integer: a single PC draws a fraction of a kWh per hour
    # (e.g. ~0.03-0.07), so Integer would truncate every rate to 0.
    kwh_per_pc_hour = db.Column(db.Float, nullable=False)
    cost_per_pc_hour = db.Column(db.Float, nullable=False)


