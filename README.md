# rm-koreader-heal

> 一条命令修好 reMarkable 上「系统升级后 KOReader 打不开」。

---

## 问题是什么

reMarkable 的系统 OTA 升级是**整块替换根文件系统**：`/etc`、`/usr` 等全部重置，只有 `/home` 分区保留。于是升级之后：

| 位置 | 升级后 |
|---|---|
| KOReader 本体 `/home/root/koreader/` | ✅ 完好无损 |
| `/etc/systemd/system/koreader.service` | ❌ 被清掉 |
| `/etc/systemd/system/button-listen.service` | ❌ 被清掉 |
| `/etc/localtime`（时区） | ❌ 重置回 UTC |

`button-listen` 就是那个监听「长按中键唤起 KOReader」的服务。它一没了 → 长按中键毫无反应 → 表现出来就是**「升级后 KOReader 无法启动」**。

但 KOReader 本体、书、插件、设置**全都还在** `/home` 里，一点问题都没有。缺的只是 `/etc` 下那两个服务的注册。

**别急着重装 KOReader。** 跑一下这个脚本就好。

## 这个脚本做什么

在 Mac 上运行，四步：

1. **自动发现设备** —— USB 直连（`10.11.99.1`）或 Wi-Fi（局域网 IP），也可以 `--host` 指定；
2. **SSH 连进去** —— 优先用公钥免密，没有就用密码；
3. **体检** —— 判断 KOReader 本体在不在、两个服务在不在、时区有没有被重置、根分区还剩多少空间；
4. **补齐 + 复检** —— 把缺的服务从 `/home` 重新注册回 `/etc`，`daemon-reload`，把 `button-listen` 拉起来，必要时恢复时区。

**幂等**：设备健康时它只报告、不改动任何东西。随时可以重复跑。

```
$ ./rm-koreader-heal.sh

rm-koreader-heal.sh 1.0.0
────────────────────────────────────────────────────────────
  [1/5] 发现设备
      ✓ 10.11.99.1  (USB)
  [2/5] 连接与鉴权
      ✓ 已连接 (公钥免密)
  [3/5] 体检 + 修复
      ✓ KOReader 本体    /home/root/koreader
      • 设备型号        reMarkable 1.0
      • 系统版本        3.29.0.149
  [4/5] 修复
      ✓ 注册 koreader.service
      ✓ 注册 button-listen.service
      ✓ systemctl daemon-reload
      ✓ 恢复时区 → Asia/Hong_Kong
      ✓ button-listen  enabled/active  (长按中键可唤起 KOReader)
  [5/5] 复检
      ✓ 完成 — OK changed=1
────────────────────────────────────────────────────────────
修复完成 — 到设备上长按中键约 3 秒即可唤起 KOReader。
```

## 快速开始

```bash
git clone https://github.com/tangbonze/rm-koreader-heal.git
cd rm-koreader-heal
chmod +x rm-koreader-heal.sh

# 建议先装公钥，以后免密码（只需要设备密码一次）
./rm-koreader-heal.sh --install-key

# 之后就可以随时一键修复
./rm-koreader-heal.sh
```

设备密码在 reMarkable 上：**设置 → 关于 → 往下滑**，有一行 `Password: xxxxxx`。

只想看看有没有问题、先不动设备：

```bash
./rm-koreader-heal.sh --check
```

## 两层自愈：让它下次不用你操心

脚本除了修当下的问题，还会在设备上留下两个自愈钩子（可用 `--no-device-heal` / `--no-boot-service` 关掉）：

### 第一层 —— 设备侧「SSH 登录即自愈」

在 `/home/root/koreader/restore-services.sh`（幂等）+ `/home/root/.bashrc` 末尾一行钩子。

`/home` 分区在 OTA 后**保留**，所以这两样东西也保留。升级后你只要 SSH 登录设备一次，服务就自动补回来：

```sh
# 设备上执行（或直接 ssh 进去后自动触发）
/home/root/koreader/restore-services.sh
```

> ⚠️ 用 `ssh root@设备 "命令"` 这种**非交互**方式不会读 `.bashrc`，需要手动跑一次上面这行。

### 第二层 —— Mac 侧守护

```bash
./rm-koreader-heal.sh --watch        # 默认每 60s 查一次
./rm-koreader-heal.sh --watch=120    # 自定义间隔
```

设备一上线、或服务又缺失、或时区又被重置，就**自动修复**。Ctrl-C 退出。

想让它登录 Mac 后自动常驻：

```bash
./launchd/install.sh        # 装成 LaunchAgent（开机/登录自启 + KeepAlive）
./launchd/uninstall.sh      # 卸载
```

Mac 不受 reMarkable OTA 影响，所以这一层是真正「不用你动手」的那一层。

## 为什么不能「设备自己扛过 OTA」

我们翻遍了 3.29 固件的启动链路，**设备本机不存在任何能在开机时执行 `/home` 里脚本的钩子**：

| 可能的通道 | 结论 |
|---|---|
| rootfs 的 systemd 单元引用 `/home/root` | 6 处**全是配置路径**（NetworkManager 配置目录、crash 上传路径、wifi 迁移条件、memfault 密钥），没有一处执行钩子 |
| systemd `.path` 触发型单元 | 全机只有一个 `memfault-project-key-monitor.path`，动作**硬编码**为 `systemctl restart memfaultd`；而且 `PathChanged=` 开机不触发 |
| 登录 shell（`.bashrc` / `.profile`） | getty 在跑但**没配 autologin**（全盘 grep `autologin` 为空），开机不产生登录 shell |
| `xochitl.conf` 命令钩子 | 只有 `DeveloperPassword` 等设置项，无命令执行键 |
| rootfs 脚本 `source /home` 里的文件 | `migrate_wifi.sh` 只读配置，不 source |
| 升级保留白名单 | `update.conf` 只有一行版本号，没有保留机制 |
| `/etc`、`/var` 独立分区 | 新固件 fstab 里已**注释掉**，所以 `/etc` 并回了根分区，必被 OTA 清 |
| `/var/lib`（systemd user linger 等） | 也在根分区（实测 `df` 显示挂在 `/dev/root`） |
| 唯一持久可写分区 | `/home`(p7) + `/var/lib/uboot`(p1, FAT)。后者是 bootloader 环境，**改它有变砖风险，不要动** |

结论：**写在 `/etc` 的任何东西都挡不住 OTA，这是 reMarkable 的设计。** 能做的只有——让恢复变成一行命令，或者干脆自动化（上面两层）。

## 常用命令

```bash
./rm-koreader-heal.sh                   # 一键修复（自动发现设备）
./rm-koreader-heal.sh --check           # 只体检
./rm-koreader-heal.sh --dry-run         # 打印将要做什么，但不落盘
./rm-koreader-heal.sh --host 192.168.1.42
./rm-koreader-heal.sh --scan            # 扫本机所在子网找设备
./rm-koreader-heal.sh --install-key     # 装专用公钥，以后免密码
./rm-koreader-heal.sh --watch=120       # 守护模式
./rm-koreader-heal.sh --start-koreader  # 修完顺手把 KOReader 拉起来
./rm-koreader-heal.sh -v                # 排错：打印设备端原始输出
```

## 选项一览

| 选项 | 说明 |
|---|---|
| `--check` / `--status` | 只体检、不改动 |
| `--host HOST` | 指定设备地址；不给则自动发现 |
| `--user` / `--port` | SSH 用户（默认 `root`）/ 端口（默认 `22`） |
| `--scan` | 允许扫描本机子网找设备（默认不扫） |
| `--watch[=秒]` | 守护模式，默认每 60s |
| `--install-key` | 生成专用密钥并装到设备（公钥在 `/home`，OTA 后仍在） |
| `--start-koreader` | 修完启动 KOReader（会占用设备屏幕） |
| `--no-device-heal` | 不装设备侧自愈脚本 |
| `--no-boot-service` | 不装开机自愈 oneshot 服务 |
| `--no-tz` | 不碰设备时区 |
| `--tz ZONE` | 强制设成指定时区，如 `Asia/Hong_Kong` |
| `--dry-run` | 只说不做 |
| `-v` / `--verbose` | 打印设备端原始输出 |
| `--forget-known-hosts` | 清掉本脚本记录的设备主机密钥 |

### 时区行为

默认 `--tz` 不给时，脚本**只在设备时区已被重置**（`UTC` / 空）时才补上本机 Mac 的时区；如果设备上是你自己设过的非 UTC 时区（例如 `Asia/Hong_Kong`），**不会去动它**。

想固定成某个时区（例如永远 `Asia/Hong_Kong`），写个配置文件：

```bash
mkdir -p ~/.config/rm-koreader-heal
cat > ~/.config/rm-koreader-heal/config <<'EOF'
TZ_REQUESTED=Asia/Hong_Kong
EOF
```

配置文件就是普通的 shell 赋值，还可以放 `WATCH_INTERVAL=120`、`RM_HOST=192.168.1.42`、`NO_COLOR=1` 等。

### 密码怎么传

优先公钥免密（先跑一次 `--install-key`）。否则：

```bash
RM_PASSWORD='xxxxxx' ./rm-koreader-heal.sh   # 推荐
./rm-koreader-heal.sh                        # 交互式提示，输入不回显
```

`-p` 会把密码暴露在进程列表里，**不推荐**。

脚本可安全用于非交互环境（cron、launchd、CI、管道、编辑器任务）。连接探测走「只判断能不能连上、绝不阻塞等密码」的路径：已提供密码时交给 `SSH_ASKPASS`，没有密码时用 `BatchMode` 快速失败，再转交互提示或直接报错退出。

## 排错

| 现象 | 原因 / 处理 |
|---|---|
| `没找到可达的 reMarkable` | USB 刚插上时 dropbear 要几秒才起来，稍等重试；Wi-Fi 用 `--host` 或 `--scan` |
| `SSH 登录失败 / Permission denied` | 密码不对，或设备升级后密码变了。看设备「设置 → 关于」 |
| `Host key verification failed` | 设备重装过系统。加 `--forget-known-hosts` |
| `设备上没找到 KOReader 目录` | 这台设备还没装 KOReader，或装法不是 `/home/root/koreader` |
| 修复后长按中键还是没反应 | 把设备**重启一次**；再跑 `--check` 确认 `button-listen` 是 `enabled/active` |
| 根分区满了导致注册失败 | 根分区只有约 228MB。清点 `/etc` 下的临时文件，或把 KoReader 相关的都放在 `/home` |
| 卡在 `root@...` 的密码提示直到超时 | 非交互环境跑、且既没公钥也没设 `RM_PASSWORD`。设 `RM_PASSWORD='xxx'`，或先跑一次 `--install-key` |

## 环境要求

- **macOS**（自带 `bash` 3.2 即可，不需要 Homebrew 装任何东西）
- 只用系统自带的 `ssh` / `scp` / `nc` / `mktemp` / `dns-sd`
- 密码认证依赖 `SSH_ASKPASS`，macOS 12+ 原生支持；更早的系统会自动走「无 tty 用 askpass」的旧规则
- 设备侧：reMarkable 1 / 2，已把 KOReader 装在 `/home/root/koreader`

用到的两个服务文件（`koreader.service`、`button-listen.service`）优先从设备上 KOReader 自带的模板复制；设备上模板缺失时用脚本内置的同内容模板兜底。

## License

MIT
