import multiprocessing
from psycogreen.gevent import patch_psycopg

bind = "0.0.0.0:5000"
workers = 1
worker_class = "gevent"
worker_connections = 1000
timeout = 30
keepalive = 2
max_requests = 1000
max_requests_jitter = 100
preload_app = True
accesslog = "-"
errorlog = "-"
loglevel = "info"

def post_fork(server, worker):
    """
    Executed right after a worker process is forked.
    This injects the C-extension patch for PostgreSQL.
    """
    patch_psycopg()
    worker.log.info("Successfully made psycopg2 cooperative with gevent.")

    