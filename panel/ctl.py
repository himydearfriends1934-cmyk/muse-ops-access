#!/usr/bin/env python3
"""Muse 侧命令行:经 SSH 在服务器上读写面板数据库。
子命令:
  queue                        输出待处理用户消息、待审批/已批准/执行中任务与当前授权档位(JSON)
  reply TEXT                   以 Muse 身份回一条消息,并把待处理消息标记为已处理
  note TEXT                    以系统身份发一条消息(不改消息处理状态)
  task-create TITLE COMMAND DETAIL [LEVEL]   新建任务,LEVEL=normal|major;是否直接放行由面板授权档位决定,输出 "id status"
  task-start ID                把已批准任务标记为执行中(状态不对会报错)
  task-result ID STATUS TEXT   回写任务结果,STATUS 为 done 或 failed
  session-start NOTE           登记一次连接,输出 "id status";每个请求确认档下连接为 pending,需面板确认后才 active
  session-end ID               正常结束一次连接
  session-check ID             输出 {"alive": bool, "auth_mode": ..., "aborted": [task_ids]}
  audit ACTION DETAIL          追加一条审计记录
"""
import json, os, sqlite3, sys, time

DB = os.environ.get("MUSE_PANEL_DB", "/var/lib/muse-ops-panel/panel.db")


def conn():
    os.umask(0o007)
    c = sqlite3.connect(DB, timeout=10)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("""CREATE TABLE IF NOT EXISTS connections
                 (id INTEGER PRIMARY KEY AUTOINCREMENT, started INT, ended INT DEFAULT 0,
                  note TEXT DEFAULT '', status TEXT DEFAULT 'active')""")
    cols = [r[1] for r in c.execute("PRAGMA table_info(tasks)")]
    if cols and "level" not in cols:
        c.execute("ALTER TABLE tasks ADD COLUMN level TEXT DEFAULT 'normal'")
    c.commit()
    return c


def now():
    return int(time.time())


def get_mode(c):
    row = c.execute("SELECT value FROM kv WHERE key='auth_mode'").fetchone()
    return row[0] if row else "major"


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]
    c = conn()
    if cmd == "queue":
        msgs = [dict(r) for r in c.execute(
            "SELECT id,ts,content FROM messages WHERE role='user' AND status='pending' ORDER BY id")]
        pend = [dict(r) for r in c.execute(
            "SELECT id,ts,title,level FROM tasks WHERE status='pending' ORDER BY id")]
        appr = [dict(r) for r in c.execute(
            "SELECT id,ts,title,detail,command,level FROM tasks WHERE status IN ('approved','running') ORDER BY id")]
        print(json.dumps({"auth_mode": get_mode(c), "pending_messages": msgs,
                          "pending_tasks": pend, "approved_tasks": appr}, ensure_ascii=False))
    elif cmd == "reply":
        c.execute("INSERT INTO messages(ts,role,content,status) VALUES(?,?,?,'')", (now(), "assistant", args[0]))
        c.execute("UPDATE messages SET status='handled' WHERE role='user' AND status='pending'")
        c.commit()
        print("ok")
    elif cmd == "note":
        c.execute("INSERT INTO messages(ts,role,content,status) VALUES(?,?,?,'')", (now(), "system", args[0]))
        c.commit()
        print("ok")
    elif cmd == "task-create":
        title, command, detail = (args + ["", "", ""])[:3]
        level = args[3] if len(args) > 3 and args[3] in ("normal", "major") else "normal"
        mode = get_mode(c)
        status = "approved" if (mode == "full" or (mode == "major" and level == "normal")) else "pending"
        cur = c.execute(
            "INSERT INTO tasks(ts,title,detail,command,status,updated,level) VALUES(?,?,?,?,?,?,?)",
            (now(), title, detail, command, status, now(), level))
        c.commit()
        print(f"{cur.lastrowid} {status}")
    elif cmd == "task-start":
        cur = c.execute("UPDATE tasks SET status='running', updated=? WHERE id=? AND status='approved'",
                        (now(), int(args[0])))
        c.commit()
        print("ok" if cur.rowcount else "ERROR: 任务不在已批准状态(可能已被中止或未批准)")
        return 0 if cur.rowcount else 3
    elif cmd == "task-result":
        tid, status, text = int(args[0]), args[1], args[2] if len(args) > 2 else ""
        if status not in ("done", "failed"):
            print("STATUS 只能是 done 或 failed", file=sys.stderr)
            return 2
        c.execute("UPDATE tasks SET status=?, result=?, updated=? WHERE id=? AND status!='aborted'",
                  (status, text, now(), tid))
        c.commit()
        print("ok")
    elif cmd == "session-start":
        status = "pending" if get_mode(c) == "each" else "active"
        cur = c.execute("INSERT INTO connections(started,note,status) VALUES(?,?,?)",
                        (now(), args[0] if args else "", status))
        c.commit()
        print(f"{cur.lastrowid} {status}")
    elif cmd == "session-end":
        c.execute("UPDATE connections SET status='ended', ended=? WHERE id=? AND status='active'",
                  (now(), int(args[0])))
        c.commit()
        print("ok")
    elif cmd == "session-check":
        row = c.execute("SELECT status FROM connections WHERE id=?", (int(args[0]),)).fetchone()
        aborted = [r[0] for r in c.execute("SELECT id FROM tasks WHERE status='aborted' ORDER BY id")]
        print(json.dumps({"alive": bool(row) and row[0] == "active",
                          "auth_mode": get_mode(c), "aborted_tasks": aborted}))
    elif cmd == "audit":
        c.execute("INSERT INTO audit(ts,actor,action,detail) VALUES(?,?,?,?)",
                  (now(), "claude-ssh", args[0], args[1] if len(args) > 1 else ""))
        c.commit()
        print("ok")
    else:
        print(f"未知子命令: {cmd}", file=sys.stderr)
        return 2
    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
