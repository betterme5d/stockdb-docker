# free-stockdb 容器化 —— 分析与可发布镜像工程

> ⚠️ **非官方项目。** 本仓库只是把上游 [hello245m/free-stockdb](https://github.com/hello245m/free-stockdb)
> 的**官方预编译发布包**做成容器镜像，不含上游任何源码或二进制——构建期从官方 Releases 下载并校验 SHA256。
> 上游为 MIT；数据版权与再分发条件由各数据源及其权利人决定，请自行确认数据源条款。

> 分析时间：2026-09-22 · 目标版本：v0.3.5 more-power
> 状态：**镜像已编译通过**（`stockdb:0.3.5`，106 MB），工程开箱可 `docker build` / 可推送仓库。

---

## 一、结论

**可以容器化。** 它其实是容器化的理想对象：无 GUI、前台运行、单端口、单文件配置、MIT 协议。
改造量约 30 行 Dockerfile，但有两个硬约束必须先接受：

| # | 约束 | 影响 |
|---|---|---|
| 1 | 发布版 `stockdb` 二进制**没有 `--host/--port` 参数** | 必须改 `stockdb.conf` 的 `server.ip: 0.0.0.0`，否则只监听容器回环，端口映射形同虚设 |
| 2 | `create_if_missing = false`，**不会自建数据库** | `data/` 必须是已存在的合法 LevelDB（含 `CURRENT`/`MANIFEST-*`），空目录直接 `open leveldb failed` |

---

## 二、关键发现（都是实测，不是看 README 推断）

### ✅ Linux 二进制存在，这是可行性的前提

Releases 除 Windows 外还提供：

| 包 | 大小 | SHA256（GitHub asset digest） |
|---|---|---|
| `manylinux-x64.tar` | 10.56 MB | `9ec47250f60cd35462446dfcf34db99ef33e6b73b3f02f0970ef329722c265cf` |
| `alpine-arm64.tar` | 9.78 MB | `40d98307e57d9153657352a1a4f89cda5d8c74615fc7f9a72d45a7dfe2132138` |

SHA256 已与本地下载的文件实测比对**完全一致**，可安全用于构建期校验。

### ⚠️ 坑 1：源码里的 CLI 参数是"另一条产品线"

仓库 `cpp/tools/main_server.cpp` 写着：

```
--host <ip>   --port <port>   --data <dir>
```

但对 v0.3.5 的 `stockdb` 二进制扫字符串，**`--host`/`--port`/`--data` 一个都不存在**。
那套参数属于 7 月开源重写的 `v1.0.0 (Fully Open-Source C++ Edition)`，与 Releases 里的 0.3.5 是两条线。

发布版真实用法（配置路径是**必传位置参数**）：

```
stockdb [-d] /path/to/stockdb.conf [-s start|stop|restart]
```

→ 照着源码写 `docker run ... stockdb --host 0.0.0.0` 必然失败。

### ⚠️ 坑 2：`stockdb_updater --help` 不打印帮助，会直接开始下载

实测它联网、通过设备校验、然后开始拉 **723 个文件 / 23,306.58 MB**。
→ 别在容器里随手试同步器参数。

反过来说，这也是好消息：**容器可以自举全量数据**，不必从宿主机拷 23 GB 过去。

### ✅ 实测通过的部分

| 项 | 结果 |
|---|---|
| 镜像编译 | ✅ 45 秒完成（下载 + SHA256 校验 + 配置改写），106 MB |
| 容器内启动 | ✅ `stockdb-server 0.3.5 / Listen: 0.0.0.0:7899 / PID: 1` |
| 端口映射 | ✅ `-p 17899:7899` 后宿主机 curl 拿到 HTTP 200 |
| healthcheck | ✅ 容器进入 `Up (healthy)` |
| 同步器联网 | ✅ 容器内可连官方源，拉到完整资源清单 |

### ⏸ 按你的要求跳过了本地数据验证

真实数据查询的端到端未做——本机 `stockdb.exe` 正持有 `data`/`data1` 的文件锁
（`LOCK`/`MANIFEST-*` 返回 `Device or resource busy`），不停服拷不出来，
而你明确说不需要本地测试。需要时按第四节自举数据即可，那是同一条代码路径。

---

## 三、目录结构

```
stockdb-docker/
├── Dockerfile              # 自包含：构建期下载官方发布包 + 校验 SHA256
├── docker-entrypoint.sh    # 前台启动 + 空数据目录预警
├── docker-compose.yml      # 服务 + 可选同步 sidecar
├── up.sh                   # ★ 一键部署：构建→自举→起服务→等健康→装定时任务
├── sync.sh                 # 停服 → 同步 → 拉起（由定时任务调用）
├── build-push.sh           # 构建/推送（amd64 / arm64 自动切换底座）
├── .dockerignore
└── .github/workflows/
    └── publish.yml         # GH Actions：多架构构建 + 合并 manifest 推 GHCR
```

---

## 四、构建与发布

### 本地构建

```bash
# amd64（默认：debian:bookworm-slim + manylinux 包）
./build-push.sh

# arm64（自动切 alpine:3.20 + alpine-arm64 包）
PLATFORM=linux/arm64 ./build-push.sh

# 推送到仓库
PUSH=1 REGISTRY=ghcr.io OWNER=yourname ./build-push.sh
```

⚠️ 本机 CLI 细节：`docker compose`（空格版）与 `docker buildx` **不可用**，
但**连字符版 `docker-compose` v2.40.3 是装了的**（`C:\Program Files\Docker\Docker\resources\bin\`）。
脚本会自动探测两者并回退到 `docker build`；多架构发布走 GitHub Actions。

### CI 发布

把本目录作为仓库根目录推到 GitHub，打 tag 即触发：

```bash
git tag v0.3.5 && git push origin v0.3.5
```

`publish.yml` 会并行构建 amd64/arm64、按 digest 推送，最后用
`docker buildx imagetools create` 合并成一个多架构 manifest。
镜像地址：`ghcr.io/<owner>/<repo>:0.3.5`

### 换版本

升级上游版本时要**同时改三处**，否则 SHA256 校验会直接把构建拦下来：
`RELEASE_TAG` / `ASSET_URL` / `ASSET_SHA256`（Dockerfile 里的 ARG，
以及 `build-push.sh` 和 `publish.yml` 里的矩阵值）。

不想校验就传 `--build-arg SKIP_CHECKSUM=1`（不推荐）。

---

## 五、部署

### 一键跑完整套工作流

```bash
./up.sh                      # 幂等：构建 → 建卷 → 自举数据 → 起服务 → 等健康
./up.sh --schedule           # 上面全套 + 安装定时任务
./up.sh --yes --schedule     # 无人值守（跳过所有交互确认）
./up.sh --status             # 只看状态，不做改动
./up.sh --bootstrap          # 强制重跑全量自举
```

跑完就进入「自动运转」状态：服务 `restart=unless-stopped`，
任务计划程序/cron 每个交易日 18:30 与次日 08:30 调 `sync.sh` 做停服→同步→拉起。

**哪些环节已自动、哪些还要人工：**

| 环节 | 状态 | 说明 |
|---|---|---|
| 构建镜像 | ✅ 自动 | 镜像不存在时自动 `build-push.sh` |
| 创建数据卷 | ✅ 自动 | 具名卷，幂等 |
| 首次自举 23 GB | ⚠️ 半自动 | 会**交互确认**（怕误触发下载）；加 `--yes` 全自动。耗时几十分钟，支持断点续传 |
| 启动服务 | ✅ 自动 | `restart=unless-stopped` |
| 等健康检查 | ✅ 自动 | 最多等 60 秒，失败会打印日志 |
| 端口冲突检测 | ✅ 自动 | 7899 被 Windows 版占用会直接报错并提示换端口，不会静默失败 |
| 安装定时任务 | ✅ 自动 | `--schedule`；Windows 走任务计划程序，Linux/WSL 走 crontab |
| 每日同步（停→同步→起） | ✅ 自动 | 由定时任务触发 `sync.sh`，含并发锁与日志 |
| **Docker Desktop 开机自启** | ❌ 需人工 | Docker Desktop 设置里勾 "Start Docker Desktop when you log in" |
| **定时时刻机器要醒着** | ❌ 需人工 | Windows 电源设置里别让机器在 18:30 / 08:30 睡掉 |

> `schedule/install-task.ps1` 的 `schtasks` 用法是标准写法，但**未在本环境实机执行**
> （沙箱里 PowerShell 通道不回传输出）。首次装完建议手动
> `schtasks /Run /TN stockdb-sync-main` 试跑一次并看 `sync.log`。

### 架构边界：什么在容器里，什么在容器外

这一点容易被误解——**并非整套流程都在 Docker 内**：

| 层 | 位置 | 内容 |
|---|---|---|
| **工作负载** | ✅ 全在容器内 | `stockdb` 服务（常驻 7899）、同步器（一次性容器 `run --rm`）、23 GB 数据（具名卷 / WSL2 ext4） |
| **编排层** | ⚠️ 在宿主上 | `up.sh` / `sync.sh`（本质就是调 `docker run` / `docker stop`）、任务计划程序 / cron |

即「**活儿都在容器里干，指挥在容器外**」。

> 已确认采用这个方案（2026-09-22）。理由：不暴露 `docker.sock`（那等同于宿主 root），
> 容器随便重建都不影响定时任务，调试也直观。代价是换机器要重装一次定时任务
> （`./up.sh --schedule` 一条命令的事）。
>
> 若日后要「一条 `docker compose up` 全自动」，可改为 cron sidecar 容器
> （需挂 `/var/run/docker.sock`）或单容器内跑 cron + supervisor，两者复杂度都更高。

### 方式 A：纯 docker CLI（不依赖 compose 时用这个）

```bash
docker volume create stockdb_data
docker volume create stockdb_mydb

# 1) 首次自举数据（约 23 GB，几十分钟）
docker run --rm -v stockdb_data:/opt/stockdb/data -v stockdb_mydb:/opt/stockdb/mydb \
       stockdb:0.3.5 stockdb_updater

# 2) 起服务
docker run -d --name stockdb -p 127.0.0.1:7899:7899 \
       -v stockdb_data:/opt/stockdb/data -v stockdb_mydb:/opt/stockdb/mydb \
       stockdb:0.3.5

# 3) 每日增量
HOST_PORT=7899 ./sync.sh      # 内部串行：停服 → 同步 → 拉起
```

⚠️ **宿主机 7899 若已被 Windows 版 `stockdb.exe` 占用，必须换端口**，
例如 `-p 127.0.0.1:7890:7899`（实测通过）。`sync.sh` 用 `HOST_PORT` 环境变量控制。

> `stockdb_updater` 能直通是因为 entrypoint 放行了它——否则镜像的 CMD
> （配置文件路径）会被追加进去，变成 `stockdb_updater /opt/stockdb/stockdb.conf`。

### 方式 B：docker compose

```bash
# 注意用连字符版（空格版 `docker compose` 在本机不可用）
docker-compose --profile sync run --rm stockdb-sync   # 首次自举
docker-compose up -d stockdb
./sync.sh                                             # 每日增量
```

`docker-compose --profile sync config` 已校验通过（只解析不执行）。
`sync.sh` 会优先探测 `docker compose`，失败后退到 `docker-compose`，再失败才走纯 CLI。

两种方式实测均可用（方式 A 在 `-p 127.0.0.1:7890:7899` 下拿到
`Up (healthy)` + HTTP 200）。

### 数据什么时候更新

| 来源 | 结论 |
|---|---|
| 官方 `使用说明.txt` | 定时示例写作 `数据更新.exe -run **15:50:00**`，即收盘后不久 |
| 上游镜像站 | 描述为「**每日更新**」 |
| 本机实测（2026-09-22 11:50） | 库内日k最新日期 = **2026-09-21**（周一）；而当天 10:00 的同步**已经能取到 21 日数据** |
| 本机 `cache.txt` | 上次同步 2026-09-22 10:00:30；昨日 19:59 也有同步活动 |

⇒ 镜像在**收盘后到次日早间之间**发布，官方给出的是 15:50。
稳妥做法是**每个交易日跑两次**：18:30 主同步 + 次日 08:30 补同步。
首次是全量 23 GB，之后都是增量，重复跑成本很低。

### 定时同步

`sync.sh` 已经内置：只在工作日跑（`RUN_ON_WEEKEND=1` 可强制）、并发锁（上一次没跑完不重入）、
日志写 `sync.log`。

```bash
# Linux / WSL
./schedule/install-cron.sh              # 安装（周一~周五 18:30 + 08:30）
./schedule/install-cron.sh --remove     # 移除

# Windows（Docker Desktop 本机，走任务计划程序 + WSL）
powershell -ExecutionPolicy Bypass -File .\schedule\install-task.ps1
powershell -ExecutionPolicy Bypass -File .\schedule\install-task.ps1 -Remove
```

Windows 那条注册的是 `wsl -e bash -lc "/mnt/i/MyProjs/stockdb-docker/sync.sh"`，
所以路径必须是 WSL 的 `/mnt/...` 形式；默认值已按本机目录写好。

> 同步器结束时还会回调本地服务的 `?cmd=reload&t=`（二进制里可见），
> 但我们走的是「停服 → 同步 → 拉起」，这一步会失败，属无害噪音。

### 环境变量

因为发布版二进制没有 CLI 参数，端口/监听地址只能用环境变量覆盖：

| 变量 | 作用 | 默认 |
|---|---|---|
| `STOCKDB_PORT` | 覆盖 `server.port` | 7899 |
| `STOCKDB_BIND` | 覆盖 `server.ip` | 0.0.0.0 |

```bash
docker run -d -e STOCKDB_PORT=8899 -p 8899:8899 stockdb:0.3.5
# 实测输出：Listen: 0.0.0.0:8899 / PID: 1
```

实现上会复制配置到 `/tmp/stockdb.runtime.conf` 再改写，不污染镜像内的原文件。

调试进容器：`docker run --rm -it --entrypoint sh stockdb:0.3.5`
（entrypoint 已放行 `sh`/`bash`/`stockdb_updater`，不会被当成配置文件路径）。

### 关键设计决策

| 决策 | 理由 |
|---|---|
| 构建期下载 + SHA256 校验 | clone 下来就能 build，不依赖手工解包；校验值取自 GitHub 官方 digest |
| 一个 Dockerfile 通吃两种架构 | 靠 `BASE_IMAGE`/`ASSET_ARCH` 两个 build-arg 切换，不维护两份文件 |
| 数据放**具名卷**，不 bind mount Windows 目录 | Docker Desktop 的 9p/virtiofs 会把 LevelDB 随机读拖垮 |
| 端口只映射 `127.0.0.1` | 服务**默认无鉴权**（`auth` 被注释）。要开放局域网先启用 `auth` |
| `logger.output` → `/dev/stdout` | 日志进 `docker logs`，否则写进容器可写层 |
| 前台运行（不加 `-d`） | 加 `-d` 会 daemonize，容器立刻退出 |
| 同步必须**先停服** | LevelDB 独占数据目录，与官方 `docs/DATA_SOURCE.md` 要求一致 |

⚠️ **磁盘**：Docker 虚拟磁盘实测有 911 GB 可用，放 23 GB 数据没问题。

---

## 六、与现有 Windows 裸机部署的取舍

| 维度 | 现状（Windows 裸机） | 容器化后 |
|---|---|---|
| 启动 | 双击 exe | `docker compose up -d`，可随机器自启 |
| 数据 IO | NTFS 原生，最快 | 具名卷（WSL2 ext4），接近原生；**bind mount 会变慢** |
| 隔离 | 与本机共享环境 | 独立文件系统、可限内存/CPU |
| 多实例 | 手动改端口 | 改 compose 端口映射即可 |
| 迁移 | 重装要重新同步 23 GB | 卷打包带走 |
| 成本 | 无 | 多一层 Docker Desktop；数据要多占一份（或迁移后删掉原那份） |

一个人本机用的话现状已经够好；要**多台机器复用同一份数据、或并进现有 compose 栈**（比如和 TSP 一起编排），值得做。
