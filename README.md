# MUSE 运维接入系统

装在你自己的服务器上:一个面板 + 一个供 Muse 接入的运维账号。
你在面板里和 Muse 对话、审批高风险操作、看审计日志;Muse 不知道你的任何密码,
靠 SSH 公钥登录(私钥只在 Muse 的运行环境里,公钥放在服务器上)。

## 安装(服务器上 root 执行)

```
bash install.sh
```

会依次完成:

1. 建运维账号 `muse-ops`:密码锁定、仅允许 Muse 的公钥登录、sudo 免密(所有 sudo
   操作记到 `/var/log/muse-ops-sudo.log`),只对该账号禁用密码登录,不影响你自己。
2. 建面板运行账号 `muse-panel`,程序装到 `/opt/muse-ops-panel`,数据(SQLite)在
   `/var/lib/muse-ops-panel/panel.db`。
3. 现场设置面板管理员密码(用户名固定 `admin`,密码只以哈希存本机)。
4. 注册 systemd 服务 `muse-ops-panel`,默认端口 **13628**(可用
   `MUSE_PANEL_PORT=8899 bash install.sh` 改)。

装完把脚本末尾打印的 IP、SSH 端口、账号三行发给 Muse,他接入后会先做只读核验,
之后你们在面板里沟通。若云厂商有安全组,需放行面板端口(建议只对你自己的 IP 放行)。

## 日常使用

打开 `http://<服务器IP>:13628/` 登录后有四个页签:

- **对话**:给 Muse 留言。他每隔几分钟经 SSH 过来看一次,回复也在这里(所以延迟
  是几分钟,不是实时)。
- **审批与任务**:白名单外的操作(任意 shell 命令等)会先生成任务卡片,你点
  「批准执行」他才会做;「拒绝」即作罢。已完成/失败的任务带结果回显。
- **机器状态**:主机名、系统、运行时长、负载、内存、磁盘、失败服务一览。
- **审计日志**:谁在什么时候做了什么(面板审批、Muse 经 SSH 的动作都会记)。

Muse 经 SSH 读写面板数据的命令是 `/usr/local/bin/muse-panel-ctl`
(queue / reply / task-create / task-result / audit)。

## 安全模型

- Muse 不持有你任何账号的密码:`muse-ops` 密码锁定且禁密码登录,只认公钥。
- 面板密码只存 PBKDF2 哈希在本机;登录连错 5 次锁定 5 分钟;会话 7 天过期。
- Muse 的 sudo 操作全量记日志(`/var/log/muse-ops-sudo.log`),面板审计可查。
- 白名单内的只读巡检他直接做;白名单外的命令必须经面板审批。

## 吊销 Muse 的访问(随时,不需要 Muse 配合)

```
userdel -r muse-ops
```

或只删 `/home/muse-ops/.ssh/authorized_keys` 里的公钥。删完他立刻进不来。

## 卸载

```
bash uninstall.sh            # 卸载面板程序/服务,保留数据与运维账号
bash uninstall.sh --purge    # 连数据、muse-panel/muse-ops 账号、sudo 与 sshd 配置一并清除
```

## 重置面板密码

停服务后执行(把新密码替换进去):

```
systemctl stop muse-ops-panel
MUSE_PANEL_INIT_PW='新密码至少8位' runuser -u muse-panel -- \
  python3 /opt/muse-ops-panel/server.py --init --db /var/lib/muse-ops-panel/panel.db
systemctl start muse-ops-panel
```

## 组成

- `panel/server.py` 面板后端(Python 标准库零依赖:登录/对话/审批/状态/审计 API)
- `panel/static/index.html` 面板前端(单文件)
- `panel/ctl.py` Muse 侧命令行(经 SSH 调用)
- `install.sh` / `uninstall.sh` 一键安装/卸载
