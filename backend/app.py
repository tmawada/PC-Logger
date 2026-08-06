from flask import Flask, render_template
from config import Config
from database import init_db, db
from routes import api


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    init_db(app)
    app.register_blueprint(api)

    @app.route("/")
    def dashboard():
        return render_template("index.html")

    return app


app = create_app()

# Auto-create tables when running directly (dev convenience).
# In production, use Flask-Migrate instead.
with app.app_context():
    db.create_all()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
