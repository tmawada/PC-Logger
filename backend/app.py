from gevent import monkey
monkey.patch_all()

from flask import Flask, render_template
from config import Config
from database import init_db, db
from routes import api
from models import PcLog
from collections import OrderedDict
from datetime import datetime

from gevent.pywsgi import WSGIServer
from prometheus_flask_exporter import PrometheusMetrics
from prometheus_client import Gauge, Counter, generate_latest, CONTENT_TYPE_LATEST


rooms =  ['601','602','603','604','605','606','608','610','611',
        '621','622','623','624','625','626','627','628','629','630'
        ,'706', '708', '710', '722', '724', '721', '723', '725'
        , '727', '729', '730', '731']

pcs_per_room = 41
events = {'boot', 'restart'}


GRAFANA_URL = "http://localhost:3000/d/adxngvv/pc-logging?orgId=1&kiosk&theme=dark"
 
lab_pcs_status = Gauge(
    'lab_pcs_status', 'Current PC status count per room', ['room', 'status']
)
pc_log_events_total = Counter(
    'pc_log_events_total', 'Total PC log events ingested', ['room', 'event_type']
)
pc_log_ingest_errors_total = Counter(
    'pc_log_ingest_errors_total', 'Events with an unparseable or unrecognized hostname'
)
pc_last_event_timestamp = Gauge(
    'pc_last_event_timestamp_seconds', 'Unix time of the last log received per PC', ['hostname']
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

    @app.route("/metrics")
    def metrics():
        pcs = PcLog.query.order_by(PcLog.id.desc()).limit(3000).all()
        pcs = [p.to_dict() for p in pcs]
        rooms_data = build_room_status(pcs, ROOMS)
    
        for room, stats in rooms_data.items():
            lab_pcs_status.labels(room=room, status='on').set(stats['on'])
            lab_pcs_status.labels(room=room, status='off').set(stats['off'])
            lab_pcs_status.labels(room=room, status='unknown').set(stats['unknown'])
    
        seen_hosts = set()
        for p in pcs:
            hostname = p.get('hostname', '')
            if hostname in seen_hosts:
                continue
            seen_hosts.add(hostname)
            created_at = p.get('created_at')
            if created_at is not None:
                pc_last_event_timestamp.labels(hostname=hostname).set(created_at.timestamp())
    
        return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)
    
    
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
    latest_by_host = {}
    for entry in logs:
        hostname = entry.get('hostname', '')
        # print("hostname : ", hostname, flush=True)
        # print("\n")
        if len(hostname) < 2 or not hostname[-2:].isdigit():
            continue
        if hostname in latest_by_host:
            continue
        pcnum = int(hostname[-2:])
        if not (1 <= pcnum <= pcs_per_room):
            continue
        if entry.get('event_type') == "Shutdown":
            status = 'off'
        else:
            status = 'on'
        ts = format_date(entry.get('created_at')) or 'unknown time'
        label = f'Turned on at {ts}' if status == 'on' else f'Shut down at {ts}'
        latest_by_host[hostname] = {'pcnum': pcnum, 'status': status, 'label': label}
    
    # print("logs: ", logs, flush=True)

    by_pcnum = {e['pcnum']: e for e in latest_by_host.values()}
    pcs = []
    for i in range(1, pcs_per_room + 1):
        pcs.append(by_pcnum.get(i) or {'pcnum': i, 'status': 'unknown', 'label': 'No recent log'})
    # print("pcs: ", pcs, flush=True)
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
