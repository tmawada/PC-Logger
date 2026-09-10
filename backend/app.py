from gevent import monkey
monkey.patch_all()

from flask import Flask, render_template
from config import Config
from database import init_db, db
from routes import api
from models import PcLog
from collections import OrderedDict
from datetime import datetime
import threading
import time
from zoneinfo import ZoneInfo
import pytz

from gevent.pywsgi import WSGIServer
from prometheus_flask_exporter import PrometheusMetrics
from prometheus_client import Gauge, Counter, generate_latest, CONTENT_TYPE_LATEST


rooms =  ['601','602','603','604','605','606','608','610','611',
        '621','622','623','624','625','626','627','628','629','630'
        ,'706', '708', '710', '722', '724', '721', '723', '725'
        , '727', '729', '730', '731']

pcs_per_room = 41
events = {'boot', 'restart'}


GRAFANA_URL = "http://localhost:3000/d/pc-logging-overview/pc-logging?orgId=1&kiosk&theme=dark"
 
lab_pcs_status = Gauge(
    'lab_pcs_status', 'Current PC status count per room', ['room', 'status']
)

pc_lab_longest_running = Gauge(
    'pc_lab_longest_running', 'Lab PC that has been running the longest', ['room', 'hostname']
)

 

def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)
    metrics = PrometheusMetrics(app)

    init_db(app)
    app.register_blueprint(api)

    @app.route("/")
    def dashboard():
        return render_template("index.html")


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

        # pc data -> last restart, last shutdown, last turned on        
        # # print("room prefix", room_prefix, flush=True)
        # # print("room_id_data: ", room_id_data, flush=True)
        pcs = build_pc_details(room_id_data)
        # print("FETCHED INFO FOR ROOM ", room_id, flush=True)
        on_count = sum(1 for p in pcs if p['status'] == 'on')
        off_count = sum(1 for p in pcs if p['status'] == 'off')
        return render_template(
            "room_details.html",
            room_id=room_id,
            pcs=pcs,
            on_count=on_count,
            off_count=off_count,
            unknown_count=pcs_per_room - on_count - off_count,
        )

    @app.route("/logs")
    def logs_page():
        return render_template("logs.html")

    @app.route("/event-log")
    def event_log_page():
        return render_template("event_log.html")


    
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
    # print("time : ", time )
    # print("\n")
    # print("time, total seconds : ", time.total_seconds())

    total_minutes = int(time.total_seconds() // 60)
    # print("Uptime : ", total_minutes)

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


def update_longest_running():
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

        host = per_host.setdefault(hostname, {'room': room, 'last_boot': None, 'last_off': None})
        if event_type == "Shutdown":
            if host['last_off'] is None or created_at > host['last_off']:
                host['last_off'] = created_at
        else:
            if host['last_boot'] is None or created_at > host['last_boot']:
                host['last_boot'] = created_at



    now =  datetime.now()
    longest_hostname = None
    longest_room = None
    longest_seconds = -1

    for hostname, host in per_host.items():
        is_on = host['last_boot'] and (not host['last_off'] or host['last_boot'] > host['last_off'])
        if not is_on:
            continue
        uptime_seconds = (now - host['last_boot']).total_seconds()
        if uptime_seconds > longest_seconds:
            longest_seconds = uptime_seconds
            longest_hostname = hostname
            longest_room = host['room']

    pc_lab_longest_running.clear()
    if longest_hostname is not None:
        pc_lab_longest_running.labels(room=longest_room, hostname=longest_hostname).set(longest_seconds)

def update_metrics_once():
    pcs = PcLog.query.order_by(PcLog.id.desc()).limit(3000).all()
    pcs = [p.to_dict() for p in pcs]
    rooms_data = build_room_status(pcs, rooms)
 
    for room, stats in rooms_data.items():
        lab_pcs_status.labels(room=room, status='on').set(stats['on'])
        lab_pcs_status.labels(room=room, status='off').set(stats['off'])
        lab_pcs_status.labels(room=room, status='unknown').set(stats['unknown'])
 
 
 
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
    # # print("pcs: ", pcs, flush=True)
    data = {}
    for room in rooms:
        on_count = sum(1 for e in latest_by_host.values() if e['room'] == room and e['status'] == 'on')
        off_count = sum(1 for e in latest_by_host.values() if e['room'] == room and e['status'] == 'off')
        data[room] = {
            'on': on_count,
            'off': off_count,
            'unknown': pcs_per_room - on_count - off_count,
        }
    # # print("datas : ", data, flush=True)
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

    # current_time_indonesia = datetime.now(indonesia_timezone)
    # print("indo time : ", current_time_indonesia, flush=True)
    indonesia_timezone = pytz.timezone('Asia/Jakarta')
    time_raw =  datetime.now(indonesia_timezone)
    now = time_raw.replace(tzinfo=None)
    # print("Time now : ", now, flush=True)
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
with app.app_context():
    db.create_all()

if __name__ == "__main__":
    # # print("testrun", flush=True)
    # app.run(host="0.0.0.0", port=5000, debug=True)
    http_server = WSGIServer(('0.0.0.0', 5000), app)
    http_server.serve_forever()

    # app.run(host="0.0.0.0", port=5000, debug=True, threaded=True)
