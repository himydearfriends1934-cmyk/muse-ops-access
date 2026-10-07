#!/usr/bin/env python3
"""Muse 运维接入系统 - 面板后端(纯 Python 标准库,零依赖)。
功能:管理员登录、与 Muse 对话、运维任务审批、机器状态、审计日志。
数据存放在单个 SQLite 文件里;Muse 经 SSH 用 ctl.py 读写同一数据库。
"""
import argparse, hashlib, hmac, json, os, secrets, shutil, sqlite3, subprocess, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ADMIN_USER = "admin"
PBKDF2_ROUNDS = 200_000
LOCK_WINDOW, LOCK_MAX_FAILS, LOCK_SECONDS = 600, 5, 300
SESSION_TTL = 7 * 24 * 3600
MAX_BODY = 64 * 1024
MAX_MSG_LEN = 4000
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")


def now():
    return int(time.time())


def db_connect(path):
    os.umask(0o007)
    conn = sqlite3.connect(path, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db(path, password):
    conn = db_connect(path)
    conn.executescript("""
    CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY, created INT, expires INT);
    CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INT, role TEXT, content TEXT, status TEXT DEFAULT '');
    CREATE TABLE IF NOT EXISTS tasks(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INT, title TEXT, detail TEXT, command TEXT,
                                     status TEXT DEFAULT 'pending', result TEXT DEFAULT '', updated INT DEFAULT 0);
    CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INT, actor TEXT, action TEXT, detail TEXT);
    """)
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PBKDF2_ROUNDS)
    conn.execute("INSERT OR REPLACE INTO kv(key,value) VALUES('admin_pass',?)",
                 (f"pbkdf2${PBKDF2_ROUNDS}${salt.hex()}${digest.hex()}",))
    conn.execute("INSERT INTO audit(ts,actor,action,detail) VALUES(?,?,?,?)",
                 (now(), "system", "init", "面板数据库已初始化"))
    conn.commit()
    conn.close()


def check_password(stored, password):
    try:
        _, rounds, salt_hex, digest_hex = stored.split("$")
        digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt_hex), int(rounds))
        return hmac.compare_digest(digest.hex(), digest_hex)
    except Exception:
        return False


def host_status():
    st = {"hostname": "", "os": "", "uptime_text": "", "load": "", "mem": "", "disk": "", "failed_units": ""}
    try:
        st["hostname"] = open("/etc/hostname").read().strip()
    except Exception:
        pass
    if not st["hostname"]:
        import socket
        st["hostname"] = socket.gethostname()
    try:
        for line in open("/etc/os-release"):
            if line.startswith("PRETTY_NAME="):
                st["os"] = line.split("=", 1)[1].strip().strip('"')
                break
    except Exception:
        pass
    try:
        up = float(open("/proc/uptime").read().split()[0])
        d, rem = divmod(int(up), 86400)
        st["uptime_text"] = (f"{d} 天 " if d else "") + f"{rem // 3600} 小时 {rem % 3600 // 60} 分钟"
        st["load"] = " ".join(open("/proc/loadavg").read().split()[:3])
    except Exception:
        pass
    try:
        mem = {}
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1)
            mem[k] = int(v.split()[0])
        total, avail = mem.get("MemTotal", 0), mem.get("MemAvailable", 0)
        st["mem"] = f"{(total - avail) / 1048576:.1f}G / {total / 1048576:.1f}G 已用"
    except Exception:
        pass
    try:
        u = shutil.disk_usage("/")
        st["disk"] = f"根分区 {u.used / 2**30:.1f}G / {u.total / 2**30:.1f}G({u.used / u.total:.0%})"
    except Exception:
        pass
    try:
        out = subprocess.run(["systemctl", "list-units", "--state=failed", "--no-legend", "--plain"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        st["failed_units"] = f"{len([l for l in out.splitlines() if l.strip()])} 个失败单元" if out else "无失败单元"
    except Exception:
        st["failed_units"] = "未知(无 systemctl)"
    return st


class Handler(BaseHTTPRequestHandler):
    db_path = ""
    server_version = "MuseOpsPanel/0.1"

    def log_message(self, *args):
        pass

    # ---------- helpers ----------
    def db(self):
        return db_connect(self.db_path)

    def send_json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            raise ValueError("body too large")
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def kv_get(self, conn, key, default=""):
        row = conn.execute("SELECT value FROM kv WHERE key=?", (key,)).fetchone()
        return row["value"] if row else default

    def kv_set(self, conn, key, value):
        conn.execute("INSERT OR REPLACE INTO kv(key,value) VALUES(?,?)", (key, value))

    def session_user(self):
        cookie = self.headers.get("Cookie") or ""
        token = ""
        for part in cookie.split(";"):
            part = part.strip()
            if part.startswith("muse_session="):
                token = part.split("=", 1)[1]
        if not token:
            return None
        conn = self.db()
        row = conn.execute("SELECT * FROM sessions WHERE token=? AND expires>?", (token, now())).fetchone()
        conn.close()
        return ADMIN_USER if row else None

    def require_auth(self):
        if self.session_user():
            return True
        self.send_json(401, {"error": "未登录"})
        return False

    # ---------- routing ----------
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith("/api/"):
            self.handle_api("GET", path, parse_qs(parsed.query))
        else:
            self.serve_static(path)

    def do_POST(self):
        parsed = urlparse(self.path)
        self.handle_api("POST", parsed.path, {})

    def serve_static(self, path):
        if path in ("/", "/index.html"):
            filename = "index.html"
        else:
            filename = path.lstrip("/")
            if "/" in filename or filename.startswith("."):
                self.send_error(404)
                return
        full = os.path.join(STATIC_DIR, filename)
        if not os.path.isfile(full):
            self.send_error(404)
            return
        ctype = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                 ".css": "text/css; charset=utf-8"}.get(os.path.splitext(full)[1], "application/octet-stream")
        data = open(full, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_api(self, method, path, qs):
        try:
            if path == "/api/login" and method == "POST":
                return self.api_login()
            if path == "/api/logout" and method == "POST":
                return self.api_logout()
            if path == "/api/me" and method == "GET":
                if not self.require_auth():
                    return
                return self.send_json(200, {"user": ADMIN_USER})
            if not self.require_auth():
                return
            if path == "/api/messages" and method == "GET":
                return self.api_messages_get(qs)
            if path == "/api/messages" and method == "POST":
                return self.api_messages_post()
            if path == "/api/tasks" and method == "GET":
                return self.api_tasks_get()
            if path.startswith("/api/tasks/") and method == "POST":
                parts = path.strip("/").split("/")
                return self.api_task_action(int(parts[2]), parts[3])
            if path == "/api/status" and method == "GET":
                return self.send_json(200, host_status())
            if path == "/api/audit" and method == "GET":
                return self.api_audit_get(qs)
            self.send_json(404, {"error": "接口不存在"})
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "请求格式不对"})
        except BrokenPipeError:
            pass

    # ---------- api impl ----------
    def api_login(self):
        data = self.read_json()
        password = str(data.get("password", ""))
        conn = self.db()
        state = json.loads(self.kv_get(conn, "login_lock", "{}") or "{}")
        if state.get("locked_until", 0) > now():
            conn.close()
            return self.send_json(429, {"error": "登录已锁定,请几分钟后再试"})
        stored = self.kv_get(conn, "admin_pass")
        if stored and check_password(stored, password):
            token = secrets.token_urlsafe(32)
            conn.execute("INSERT INTO sessions(token,created,expires) VALUES(?,?,?)",
                         (token, now(), now() + SESSION_TTL))
            self.kv_set(conn, "login_lock", "{}")
            conn.commit()
            conn.close()
            body = json.dumps({"user": ADMIN_USER}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", f"muse_session={token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL}")
            self.end_headers()
            self.wfile.write(body)
            return
        fails = [t for t in state.get("fails", []) if t > now() - LOCK_WINDOW]
        fails.append(now())
        if len(fails) >= LOCK_MAX_FAILS:
            state = {"fails": [], "locked_until": now() + LOCK_SECONDS}
        else:
            state = {"fails": fails}
        self.kv_set(conn, "login_lock", json.dumps(state))
        conn.commit()
        conn.close()
        self.send_json(401, {"error": "密码不对"})

    def api_logout(self):
        conn = self.db()
        cookie = self.headers.get("Cookie") or ""
        for part in cookie.split(";"):
            part = part.strip()
            if part.startswith("muse_session="):
                conn.execute("DELETE FROM sessions WHERE token=?", (part.split("=", 1)[1],))
        conn.commit()
        conn.close()
        self.send_json(200, {"ok": True})

    def api_messages_get(self, qs):
        after = int(qs.get("after_id", ["0"])[0] or 0)
        conn = self.db()
        rows = conn.execute("SELECT * FROM messages WHERE id>? ORDER BY id ASC LIMIT 200", (after,)).fetchall()
        conn.close()
        self.send_json(200, {"messages": [dict(r) for r in rows]})

    def api_messages_post(self):
        content = str(self.read_json().get("content", "")).strip()
        if not content:
            return self.send_json(400, {"error": "内容不能为空"})
        content = content[:MAX_MSG_LEN]
        conn = self.db()
        cur = conn.execute("INSERT INTO messages(ts,role,content,status) VALUES(?,?,?,?)",
                           (now(), "user", content, "pending"))
        conn.commit()
        mid = cur.lastrowid
        conn.close()
        self.send_json(200, {"id": mid})

    def api_tasks_get(self):
        conn = self.db()
        rows = conn.execute("SELECT * FROM tasks ORDER BY id DESC LIMIT 100").fetchall()
        conn.close()
        self.send_json(200, {"tasks": [dict(r) for r in rows]})

    def api_task_action(self, task_id, action):
        if action not in ("approve", "reject"):
            return self.send_json(404, {"error": "动作不存在"})
        new_status = "approved" if action == "approve" else "rejected"
        conn = self.db()
        row = conn.execute("SELECT status FROM tasks WHERE id=?", (task_id,)).fetchone()
        if not row:
            conn.close()
            return self.send_json(404, {"error": "任务不存在"})
        if row["status"] != "pending":
            conn.close()
            return self.send_json(409, {"error": "该任务已处理"})
        conn.execute("UPDATE tasks SET status=?, updated=? WHERE id=?", (new_status, now(), task_id))
        conn.execute("INSERT INTO audit(ts,actor,action,detail) VALUES(?,?,?,?)",
                     (now(), "panel", action, f"任务 #{task_id} 已{'批准' if action == 'approve' else '拒绝'}"))
        conn.commit()
        conn.close()
        self.send_json(200, {"ok": True})

    def api_audit_get(self, qs):
        limit = min(int(qs.get("limit", ["100"])[0] or 100), 300)
        conn = self.db()
        rows = conn.execute("SELECT * FROM audit ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        conn.close()
        self.send_json(200, {"audit": [dict(r) for r in rows]})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=13628)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--db", default="/var/lib/muse-ops-panel/panel.db")
    ap.add_argument("--init", action="store_true", help="用环境变量 MUSE_PANEL_INIT_PW 初始化/重置管理员密码")
    args = ap.parse_args()
    Handler.db_path = args.db
    if args.init:
        password = os.environ.get("MUSE_PANEL_INIT_PW", "")
        if len(password) < 8:
            print("MUSE_PANEL_INIT_PW 至少 8 位", file=sys.stderr)
            return 1
        os.makedirs(os.path.dirname(args.db), exist_ok=True)
        init_db(args.db, password)
        print("管理员密码已设置")
        return 0
    if not os.path.exists(args.db):
        print("数据库不存在,请先 --init", file=sys.stderr)
        return 1
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
