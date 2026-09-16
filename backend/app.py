from gevent import monkey
monkey.patch_all()
from flask import Flask, render_template
from config import Config
from database import init_db, db
from routes import api
from models import PcLog
from datetime import datetime
import threading
import time
import pytz
import sys
import os
from gevent.pywsgi import WSGIServer
from prometheus_flask_exporter import PrometheusMetrics
from prometheus_client import Gauge

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "model"))
from seed import ROOM_RATES, get_room_rate, seed_data  # noqa: E402


rooms =  ['601','602','603','604','605','606','608','610','611',
        '621','622','623','624','625','626','627','628','629','630'
        ,'706', '708', '710', '722', '724', '721', '723', '725'
        , '727', '729', '730', '731']

pcs_per_room = 41
events = {'boot', 'restart'}


GRAFANA_URL = "http://localhost:3000/public-dashboards/c7e54921b9a74926a8038bf6f6dbc216"

lab_pcs_status = Gauge(
    'lab_pcs_status', 'Current PC status count per room', ['room', 'status']
)

pc_lab_top_longest_running_seconds = Gauge(
    'pc_lab_top_longest_running_seconds',
    'Uptime in seconds of the top 20 longest-running PCs',
    ['rank', 'room', 'hostname', 'pcnum']
)


# Live cost/hour and kWh/hour per room, driven by on_count * rate from
# ROOM_RATES (backend/model/seed.py, sourced from cost.xlsx). Value is the
# actual metric (Rp/h or kWh/h); rank+room are the only labels so this
# doesn't create a new series per float value.
pc_lab_cost_per_room = Gauge(
    'pc_lab_cost_per_room',
    'Live electricity cost (Rp/hour) for the room, based on PCs currently on',
    ['rank', 'room']
)

pc_lab_kwh_per_room = Gauge(
    'pc_lab_kwh_per_room',
    'Live power draw (kWh/hour) for the room, based on PCs currently on',
    ['rank', 'room']
)


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)
    metrics = PrometheusMetrics(app)
    try:
        init_db(app)
    except:
        print("[INFO] DB FAILED TO CONNECT")
    app.register_blueprint(api)

    @app.route("/main")
    def main_menu():
        pcs = PcLog.query.order_by(PcLog.id.desc()).limit(3000).all()
        pcs = [p.to_dict() for p in pcs]
        rooms_data = build_room_status(pcs, rooms)
        generated_at = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

        return render_template(
            "mainmenu.html",
            rooms=rooms,
            rooms_data=rooms_data,
            pcs_per_room=pcs_per_room,

            generated_at=generated_at,
        )

    @app.route("/main/room/<room_id>")
    def get_room_details(room_id):
        room_prefix = f"BN{room_id}%"
        room_id_data = PcLog.query.filter(PcLog.hostname.like(room_prefix)).order_by(PcLog.id.desc()).limit(5000).all()
        room_id_data = [d.to_dict() for d in room_id_data]

        pcs = build_pc_details(room_id_data)
        on_count = sum(1 for p in pcs if p['status'] == 'on')
        off_count = sum(1 for p in pcs if p['status'] == 'off')
        rate = get_room_rate(room_id)
        return render_template(
            "room_details.html",
            room_id=room_id,
            pcs=pcs,
            on_count=on_count,
            off_count=off_count,
            unknown_count=pcs_per_room - on_count - off_count,
            kwh_per_hour=round(rate['kwh_per_pc_hour'] * on_count, 3),
            cost_per_hour=round(rate['cost_per_pc_hour'] * on_count),
            cost_per_pc_hour=rate['cost_per_pc_hour'],
        )


    @app.route("/monitoring")
    def monitoring():
        return render_template("monitoring.html", grafana_url=GRAFANA_URL)

    return app

def format_date(value):
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value)
        except ValueError:
            return value

    if isinstance(value, datetime):
        return value.strftime('%b %d, %H:%M')

    return value

def parse_datetime(value):
    if isinstance(value, datetime):
        return value
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None

def format_duration(time):
    total_minutes = int(time.total_seconds() // 60)

    if total_minutes <= 0:
        return 'from the future'
    if total_minutes < 1:
        return 'less than a minute'
    days, rem = divmod(total_minutes, 1440)
    hours, minutes = divmod(rem, 60)
    parts = []
    if days:
        parts.append(f'{days}d')
    if hours:
        parts.append(f'{hours}h')
    if minutes and not days:
        parts.append(f'{minutes}m')
    return ' '.join(parts) if parts else '0m'


def update_longest_running(top_n=20):
    logs = PcLog.query.order_by(PcLog.id.desc()).all()
    logs = [p.to_dict() for p in logs]

    per_host = {}
    for entry in logs:
        hostname = entry.get('hostname', '')
        if len(hostname) < 5 or not hostname[-5:].isdigit():
            continue
        room = hostname[-5:-2]
        event_type = entry.get('event_type')
        created_at = parse_datetime(entry.get('created_at'))
        if created_at is None:
            continue
        pcnum = int(hostname[-2:])
        host = per_host.setdefault(hostname, {'room': room,'pcnum': pcnum, 'last_boot': None, 'last_off': None})
        if event_type == "Shutdown":
            if host['last_off'] is None or created_at > host['last_off']:
                host['last_off'] = created_at
        else:
            if host['last_boot'] is None or created_at > host['last_boot']:
                host['last_boot'] = created_at

    indonesia_timezone = pytz.timezone('Asia/Jakarta')
    time_raw =  datetime.now(indonesia_timezone)
    now = time_raw.replace(tzinfo=None)
    running = []
    for hostname, host in per_host.items():
        is_on = host['last_boot'] and (not host['last_off'] or host['last_boot'] > host['last_off'])
        if not is_on:
            continue
        uptime_seconds = (now - host['last_boot']).total_seconds()
        running.append((uptime_seconds, hostname, host['room'], host['pcnum']))

    running.sort(reverse=True)
    top = running[:top_n]

    pc_lab_top_longest_running_seconds.clear()
    for rank, (uptime_seconds, hostname, room, pcnum) in enumerate(top, start=1):
        pc_lab_top_longest_running_seconds.labels(rank=str(rank), room=room, hostname=f'PC {hostname}', pcnum=pcnum).set(uptime_seconds)



def update_metrics_once(top_n=20):
    pcs = PcLog.query.order_by(PcLog.id.desc()).limit(3000).all()
    pcs = [p.to_dict() for p in pcs]
    rooms_data = build_room_status(pcs, rooms)

    for room, stats in rooms_data.items():
        lab_pcs_status.labels(room=room, status='on').set(stats['on'])
        lab_pcs_status.labels(room=room, status='off').set(stats['off'])
        lab_pcs_status.labels(room=room, status='unknown').set(stats['unknown'])

    # Live cost/kWh per hour, ranked, mirroring update_longest_running().
    room_costs = []
    for room, stats in rooms_data.items():
        rate = get_room_rate(room)
        cost_per_hour = rate['cost_per_pc_hour'] * stats['on']
        kwh_per_hour = rate['kwh_per_pc_hour'] * stats['on']
        room_costs.append((cost_per_hour, kwh_per_hour, room))

    room_costs.sort(reverse=True)
    top = room_costs[:top_n]

    pc_lab_cost_per_room.clear()
    pc_lab_kwh_per_room.clear()
    for rank, (cost_per_hour, kwh_per_hour, room) in enumerate(top, start=1):
        pc_lab_cost_per_room.labels(rank=str(rank), room=room).set(round(cost_per_hour, 2))
        pc_lab_kwh_per_room.labels(rank=str(rank), room=room).set(round(kwh_per_hour, 3))





def build_room_status(pcs, rooms):
    latest_by_host = {}
    for p in pcs:
        hostname = p.get('hostname', '')
        if hostname in latest_by_host:
            continue
        if len(hostname) < 5 or not hostname[-5:].isdigit():
            continue
        room = hostname[-5:-2]
        pcnum = int(hostname[-2:])
        if room not in rooms or not (1 <= pcnum <= pcs_per_room):
            continue
        if p.get('event_type') == "Shutdown":
            pcStatus = 'off'
        else:
            pcStatus = 'on'
        latest_by_host[hostname] = {
            'room': room,
            'status': pcStatus,
        }
    data = {}
    for room in rooms:
        on_count = sum(1 for e in latest_by_host.values() if e['room'] == room and e['status'] == 'on')
        off_count = sum(1 for e in latest_by_host.values() if e['room'] == room and e['status'] == 'off')
        data[room] = {
            'on': on_count,
            'off': off_count,
            'unknown': pcs_per_room - on_count - off_count,
        }
    return data


def build_pc_details(logs):
    per_host = {}
    for entry in logs:
        hostname = entry.get('hostname', '')
        if len(hostname) < 5 or not hostname[-5:].isdigit():
            continue
        pcnum = int(hostname[-2:])
        if not (1 <= pcnum <= pcs_per_room):
            continue

        event_type = entry.get('event_type')
        created_at = parse_datetime(entry.get('created_at'))
        if created_at is None:
            continue

        host = per_host.setdefault(hostname, {
            'pcnum': pcnum, 'last_boot': None, 'last_restart': None, 'last_off': None
        })

        if event_type == "Shutdown":
            if host['last_off'] is None or created_at > host['last_off']:
                host['last_off'] = created_at
        elif event_type == "Restart":
            if host['last_restart'] is None or created_at > host['last_restart']:
                host['last_restart'] = created_at
        else:
            if host['last_boot'] is None or created_at > host['last_boot']:
                host['last_boot'] = created_at

    indonesia_timezone = pytz.timezone('Asia/Jakarta')
    time_raw =  datetime.now(indonesia_timezone)
    now = time_raw.replace(tzinfo=None)
    by_pcnum = {}
    for host in per_host.values():
        last_boot = host['last_boot']
        last_restart = host['last_restart']
        last_off = host['last_off']
        last_on = max((t for t in (last_boot, last_restart) if t is not None), default=None)

        if last_on and (not last_off or last_on > last_off):
            status = 'on'
        elif last_off:
            status = 'off'
        else:
            status = 'unknown'

        uptime = None
        if status == 'on' and last_on:
            uptime = format_duration(now - last_on)
        elif status == 'off' and last_on and last_off:
            uptime = format_duration(last_off - last_on)

        if status == 'on':
            label = f'Turned on at {format_date(last_on)}'
        elif status == 'off':
            label = f'Shut down at {format_date(last_off)}'
        else:
            label = 'No recent log'

        by_pcnum[host['pcnum']] = {
            'pcnum': host['pcnum'],
            'status': status,
            'label': label,
            'last_boot': format_date(last_boot) or 'No boot log',
            'last_restart': format_date(last_restart) or 'No restart log',
            'last_off': format_date(last_off) or 'No shutdown log',
            'uptime': uptime,
        }

    pcs = []
    for i in range(1, pcs_per_room + 1):
        pcs.append(by_pcnum.get(i) or {
            'pcnum': i,
            'status': 'unknown',
            'label': 'No recent log',
            'last_boot': 'No boot log',
            'last_restart': 'No restart log',
            'last_off': 'No shutdown log',
            'uptime': None,
        })
    return pcs

app = create_app()
# Auto-create tables when running directly (dev convenience).
# In production, use Flask-Migrate instead.
print("NAME : ", __name__, flush=True)
with app.app_context():
    db.create_all()
    try:
        seed_data()
    except Exception:
        import traceback
        traceback.print_exc()

def update_metrics_loop():
    while True:
        try:
            with app.app_context():
                update_metrics_once()
                update_longest_running()
        except Exception as e:
                import traceback
                traceback.print_exc()
        time.sleep(30)


threading.Thread(target=update_metrics_loop, daemon=True).start()

if __name__ == "__main__":
    http_server = WSGIServer(('0.0.0.0', 5000), app)
    http_server.serve_forever()


