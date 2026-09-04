from gevent import monkey
monkey.patch_all()

from flask import Flask, render_template
from config import Config
from database import init_db, db
from routes import api
from models import PcLog

from gevent.pywsgi import WSGIServer

rooms =  ['601','602','603','604','605','606','608','610','611',
        '621','622','623','624','625','626','627','628','629','630'
        ,'706', '708', '710', '722', '724', '721', '723', '725'
        , '727', '729', '730', '731']

def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    init_db(app)
    app.register_blueprint(api)

    @app.route("/")
    def dashboard():
        return render_template("index.html")


    @app.route("/main")
    def main_menu():
        pcs = PcLog.query.order_by(PcLog.id.desc()).limit(3000).all()
        pcs = [p.to_dict() for p in pcs]
        return render_template("mainmenu.html", rooms = rooms, pcs = pcs )

    @app.route("/logs")
    def logs_page():
        return render_template("logs.html")

    @app.route("/event-log")
    def event_log_page():
        return render_template("event_log.html")

    return app


app = create_app()

# Auto-create tables when running directly (dev convenience).
# In production, use Flask-Migrate instead.
with app.app_context():
    db.create_all()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
    # http_server = WSGIServer(('0.0.0.0', 5000), app)
    # http_server.serve_forever()

    # app.run(host="0.0.0.0", port=5000, debug=True, threaded=True)
