#!/usr/bin/env python3
"""Muse 侧命令行:经 SSH 在服务器上读写面板数据库。
子命令:
  queue                        输出待处理用户消息与已批准待执行任务(JSON)
  reply TEXT                   以 Muse 身份回一条消息,并把待处理消息标记为已处理
  note TEXT                    以系统身份发一条消息(不改消息处理状态)
  task-create TITLE COMMAND DETAIL   新建一个待审批任务,输出任务 id
  task-result ID STATUS TEXT   回写任务结果,STATUS 为 done 或 failed
  audit ACTION DETAIL          追加一条审计记录
"""
import json, os, sqlite3, sys, time

DB = os.environ.get("MUSE_PANEL_DB", "/var/lib/muse-ops-panel/panel.db")


def conn():
    os.umask(0o007)
    c = sqlite3.connect(DB, timeout=10)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    return c


def now():
    return int(time.time())


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
            "SELECT id,ts,title FROM tasks WHERE status='pending' ORDER BY id")]
        appr = [dict(r) for r in c.execute(
            "SELECT id,ts,title,detail,command FROM tasks WHERE status='approved' ORDER BY id")]
        print(json.dumps({"pending_messages": msgs, "pending_tasks": pend, "approved_tasks": appr},
                         ensure_ascii=False))
    elif cmd == "reply":
        text = args[0]
        c.execute("INSERT INTO messages(ts,role,content,status) VALUES(?,?,?,'')", (now(), "assistant", text))
        c.execute("UPDATE messages SET status='handled' WHERE role='user' AND status='pending'")
        c.commit()
        print("ok")
    elif cmd == "note":
        c.execute("INSERT INTO messages(ts,role,content,status) VALUES(?,?,?,'')", (now(), "system", args[0]))
        c.commit()
        print("ok")
    elif cmd == "task-create":
        title, command, detail = (args + ["", "", ""])[:3]
        cur = c.execute("INSERT INTO tasks(ts,title,detail,command,status,updated) VALUES(?,?,?,?,'pending',?)",
                        (now(), title, detail, command, now()))
        c.commit()
        print(cur.lastrowid)
    elif cmd == "task-result":
        tid, status, text = int(args[0]), args[1], args[2] if len(args) > 2 else ""
        if status not in ("done", "failed"):
            print("STATUS 只能是 done 或 failed", file=sys.stderr)
            return 2
        c.execute("UPDATE tasks SET status=?, result=?, updated=? WHERE id=?", (status, text, now(), tid))
        c.commit()
        print("ok")
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
