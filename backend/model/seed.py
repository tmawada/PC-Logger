"""
Seeds RoomType rows and provides the room -> electricity-rate mapping used by
app.py (live per-hour cost) and the Prometheus gauges.

Source data: cost.xlsx (repo root). Sheet1 columns:
    room | pcs | active_kw | ops_kwh_day | cost_day_rp | cost_year_rp

active_kw is the room's total measured draw with all PCs on. Per-PC draw
(kwh_per_pc_hour) is active_kw / pcs, since 1 kW sustained for 1 hour = 1 kWh.
ops_kwh_day = active_kw * 10 confirms the sheet assumes a 10 PC-hour/day
baseline; cost_year_rp / cost_day_rp = 264 confirms 264 operating days/year.
Those two assumptions are only used to produce the reference day/year
columns below - the live dashboard/gauge cost is computed from actual
on-count * cost_per_pc_hour, independent of any assumed schedule.

Effective tariff back solved from cost_day_rp / ops_kwh_day is ~955 Rp/kWh
across every row (the tiny per-row drift is rounding in the source sheet).
"""

TARIFF_RP_PER_KWH = 955

# room_code -> active_kw for the whole room (all PCs on), from cost.xlsx.
# pcs is the PC count used to derive per-PC kW; it can differ slightly from
# the global pcs_per_room (41) used elsewhere in app.py (e.g. 727/604/608
# were measured with 42, 610 with 37, 724 with 12, 711 with 15, 606 with 1).
_ROOM_MEASUREMENTS = {
    "710": {"pcs": 41, "active_kw": 3.04},
    "708": {"pcs": 41, "active_kw": 2.77},
    "706": {"pcs": 41, "active_kw": 2.56},
    "625": {"pcs": 41, "active_kw": 2.25},
    "629": {"pcs": 41, "active_kw": 2.25},
    "627": {"pcs": 41, "active_kw": 2.25},
    "623": {"pcs": 41, "active_kw": 2.25},
    "621": {"pcs": 41, "active_kw": 2.25},
    "727": {"pcs": 42, "active_kw": 1.24},
    "729": {"pcs": 41, "active_kw": 1.21},
    "721": {"pcs": 41, "active_kw": 1.21},
    "723": {"pcs": 41, "active_kw": 1.21},
    "725": {"pcs": 41, "active_kw": 1.21},
    "604": {"pcs": 42, "active_kw": 1.07},
    "608": {"pcs": 42, "active_kw": 1.07},
    "602": {"pcs": 41, "active_kw": 1.05},
    "601": {"pcs": 41, "active_kw": 1.05},
    "730": {"pcs": 41, "active_kw": 1.05},
    "628": {"pcs": 41, "active_kw": 1.05},
    "626": {"pcs": 41, "active_kw": 1.05},
    "603": {"pcs": 41, "active_kw": 1.05},
    "605": {"pcs": 41, "active_kw": 1.05},
    "622": {"pcs": 41, "active_kw": 1.05},
    "624": {"pcs": 41, "active_kw": 1.05},
    "731": {"pcs": 41, "active_kw": 1.05},
    "631": {"pcs": 41, "active_kw": 1.05},
    "630": {"pcs": 41, "active_kw": 1.05},
    "722": {"pcs": 41, "active_kw": 0.72},
    "610": {"pcs": 37, "active_kw": 0.65},
    "724": {"pcs": 12, "active_kw": 0.31},
    "711": {"pcs": 15, "active_kw": 0.30},
    "606": {"pcs": 1, "active_kw": 0.05},
}

# Rooms tracked by the dashboard (app.py `rooms`) that were not present in
# cost.xlsx. Fall back to the "general" tier average so every room still
# gets a cost figure instead of silently showing nothing.
_FALLBACK_KWH_PER_PC_HOUR = 1.05 / 41


def _build_room_rates():
    rates = {}
    for room, m in _ROOM_MEASUREMENTS.items():
        kwh_per_pc_hour = m["active_kw"] / m["pcs"]
        rates[room] = {
            "kwh_per_pc_hour": round(kwh_per_pc_hour, 5),
            "cost_per_pc_hour": round(kwh_per_pc_hour * TARIFF_RP_PER_KWH, 2),
        }
    return rates


# room_code -> {"kwh_per_pc_hour": float, "cost_per_pc_hour": float (Rp)}
# Used directly by app.py for the live "cost per hour" shown on
# room_details.html and pushed into pc_lab_cost_per_room.
ROOM_RATES = _build_room_rates()


def get_room_rate(room_id):
    """Rate dict for a room code, falling back to the general-tier average
    for rooms missing from cost.xlsx (e.g. newly added rooms)."""
    return ROOM_RATES.get(room_id, {
        "kwh_per_pc_hour": round(_FALLBACK_KWH_PER_PC_HOUR, 5),
        "cost_per_pc_hour": round(_FALLBACK_KWH_PER_PC_HOUR * TARIFF_RP_PER_KWH, 2),
    })


# Distinct rate tiers, named per the tiering notes below. RoomType stores
# one row per tier (not per physical room) so Grafana/SQL can join PcLog ->
# RoomType once room_id is populated, without duplicating a row per room.
#
# 710 -> high 1
# 708 -> high 2
# 706 -> high 3
# 621, 623, 625, 627, 629 -> general 1 (highest general tier)
# 721, 723, 725, 727, 729 -> general 2
# 601, 602, 603, 604, 605, 608, 622, 624, 626, 628, 630, 631, 730, 731 -> general
# 610, 722 -> general (lower)
# 711, 724 -> general (lowest)
# 606 -> general (minimal / near-idle)
_ROOM_TYPE_TIERS = [
    ("High 1", ["710"]),
    ("High 2", ["708"]),
    ("High 3", ["706"]),
    ("General 1", ["621", "623", "625", "627", "629"]),
    ("General 2", ["721", "723", "725", "727", "729"]),
    ("General", ["601", "602", "603", "604", "605", "608", "622", "624", "626", "628", "630", "631", "730", "731"]),
    ("General Low", ["610", "722"]),
    ("General Minimal", ["711", "724"]),
    ("General Idle", ["606"]),
]


def seed_data():
    """
    Seed RoomType with one row per rate tier derived from cost.xlsx.
    Idempotent: skips tiers that already exist (matched by room_name).
    Call inside an app context, e.g.:

        from model.seed import seed_data
        with app.app_context():
            seed_data()
    """
    from models import RoomType
    from database import db

    existing_names = {r.room_name for r in RoomType.query.all()}
    created = []

    for tier_name, rooms in _ROOM_TYPE_TIERS:
        if tier_name in existing_names:
            continue
        # Representative rate for the tier: average across its rooms.
        kwh_values = [ROOM_RATES[r]["kwh_per_pc_hour"] for r in rooms if r in ROOM_RATES]
        cost_values = [ROOM_RATES[r]["cost_per_pc_hour"] for r in rooms if r in ROOM_RATES]
        if not kwh_values:
            continue
        avg_kwh = round(sum(kwh_values) / len(kwh_values), 5)
        avg_cost = round(sum(cost_values) / len(cost_values), 2)

        room_type = RoomType(
            room_name=tier_name,
            kwh_per_pc_hour=avg_kwh,
            cost_per_pc_hour=avg_cost,
        )
        db.session.add(room_type)
        created.append(tier_name)

    if created:
        db.session.commit()

    return created


if __name__ == "__main__":
    import sys
    import os

    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from app import app

    with app.app_context():
        created = seed_data()
        if created:
            print(f"[OK] Seeded RoomType tiers: {', '.join(created)}")
        else:
            print("[OK] RoomType already seeded, nothing to do.")
