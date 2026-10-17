# WeKnora 本地部署运维手册

腾讯 WeKnora（LLM 知识库/RAG 平台）本地 Docker Compose 部署。
仓库地址: /Users/javaedge/soft/VSProjects/WeKnora（上游 github.com/Tencent/WeKnora）

> 本手册由 2026-10-14 完整部署过程整理而成，**「踩坑记录」一节收录了全过程真实遇到的问题、根因与修复方案**，生产环境部署前请先读完该节和文末自查清单。

## 部署信息

| 项目 | 值 |
|---|---|
| 版本 | v0.8.3（2026-10-14 随仓库 clone 锁定） |
| Web UI | http://127.0.0.1:18090 （宿主机 FRONTEND_PORT，官方默认 80 已被 px0 占用） |
| 后端 API | http://127.0.0.1:18091/health （宿主机 APP_PORT，官方默认 8080 已被 px0 占用） |
| 核心服务 | frontend(nginx) / app(Go) / docreader(Python gRPC) / postgres(paradedb pg17) / redis |
| 数据卷 | weknora_postgres-data（业务数据）、weknora_data-files（文件存储）、weknora_docreader-tmp（临时） |
| 密钥 | .env 中 JWT_SECRET / SYSTEM_AES_KEY / SYSTEM_SIGNING_KEY / DB_PASSWORD / REDIS_PASSWORD（随机生成，勿随仓库外泄） |
| 模型 | UI onboarding 引导配置；本机 LM Studio 需配 SSRF 白名单，见「踩坑记录」#8 |

首次使用: 打开 http://127.0.0.1:18090 注册账号并完成引导，第一个注册用户即系统管理员。

## 日常操作（均在 WeKnora 目录执行）

```bash
cd /Users/javaedge/soft/VSProjects/WeKnora

docker compose ps                                # 查看容器状态
docker compose logs -f app                       # 看后端日志
docker compose logs -f docreader                 # 看解析服务日志
```

## 升级到最新版

```bash
./ops/update.sh              # 自动先备份，再 git pull + 拉新镜像 + 滚动重启 + 健康检查
./ops/update.sh --tag v0.8.3 # 固定升级到指定 release tag
```

升级须知:
- 升级前务必阅读官方升级说明 https://weknora.weixin.qq.com/docs/07-releases
- 必须保留原 .env 中的 SYSTEM_AES_KEY / JWT_SECRET / SYSTEM_SIGNING_KEY，否则数据库加密字段无法解密、登录态全部失效
- 数据库迁移（AUTO_MIGRATE=true 自动执行）大表可能耗时较长，属正常现象
- 固定版本模式: 编辑 .env 的 WEKNORA_VERSION=v0.x.x 后同样执行 ./ops/update.sh
- **升级后必须人工核对 `docker-compose.override.yml` 与新版 compose 的兼容性**（本部署的 postgres command / healthcheck 修正依赖上游字段，上游改版可能失效）

## 备份与迁移

```bash
./ops/backup.sh                       # 备份到 ~/weknora-backups/weknora-<时间戳>/（自动保留最近 10 份）
./ops/restore.sh ~/weknora-backups/weknora-<时间戳>            # 本机恢复（保留本机 .env）
./ops/restore.sh ~/weknora-backups/weknora-<时间戳> --with-env # 迁移到新机器（用备份的 .env 覆盖）
```

备份内容: database.dump（pg_dump 逻辑备份，跨版本可恢复）+ data-files.tgz（文件卷）+ config.tgz（.env 与 config/，含密钥）。

迁移到新机器步骤:
1. 新机器安装 Docker、clone 本仓库、cp .env.example .env
2. `./ops/restore.sh <备份目录> --with-env`（自动完成建库/恢复/启动）
3. 或手工: docker compose up -d postgres → pg_restore → 恢复 data-files → 全栈 up -d

## 在管理面板中使用

已在 project-launcher 面板（http://localhost:8090）注册:
- 分组「📚 WeKnora 知识库平台」，入口 http://127.0.0.1:18090
- 面板「启动」会自动拉起 Docker Desktop 并 `up -d`；「停止」执行 `down`
- 状态检测用真实 HTTP 请求（curl UI），不用端口监听，避免误报
- **注意: 面板「停止」= 整个 Docker 栈 down（含数据库）**。服务使用中不要点停止——注册/写请求落在 down/up 重启窗口期会直接失败（真实案例见「踩坑记录」#7）。日常无需停止，容器 restart: unless-stopped 随 Docker Desktop 自启

## 踩坑记录：问题现象 → 根因 → 修复 → 预防

### #1 Docker Desktop 重启后 daemon 起不来
- **现象**: daemon 无响应，容器全部退出
- **根因**: 用 `pkill Docker` 强杀进程，清理不干净，daemon 无法重新初始化
- **修复**（正确姿势）:
  ```bash
  osascript -e 'quit app "Docker"'; open -a Docker
  ```
- **预防**: 永远不用 pkill 处理 Docker Desktop

### #2 宿主机磁盘写满 → docker pull / 迁移连环失败
- **现象**: `docker compose pull` 报 `read-only file system`、containerd meta.db 无法写入；后续所有 pull 命中残留损坏 layer，恒定报 `unexpected commit digest`（docreader v0.8.2/v0.8.3 同一 layer 跨镜像源复现）
- **根因**: 宿主机磁盘被写满（仅剩 432Mi），containerd content store 的元数据与镜像层损坏
- **修复**: 手动清理磁盘腾出空间 → `docker system prune -f` 真正回收 → 必要时对损坏镜像 `docker rmi <image> && docker pull <image>` 重拉
- **预防**: 拉取大镜像前确认宿主机剩余空间 > 8GB；定期 `docker system prune -f`；把磁盘水位纳入监控

### #3 `WEKNORA_VERSION=latest` 镜像不存在
- **现象**: compose 警告 "Some service image(s) must be built from source"，无法启动
- **根因**: 上游未向 Docker Hub 发布 latest tag
- **修复**: .env 固定官方 release tag，当前 `WEKNORA_VERSION=v0.8.3`
- **预防**: 升级时用 `./ops/update.sh --tag vX.Y.Z`，先查官方 releases 页确认 tag 存在

### #4 app 连 postgres 被拒（connection refused）
- **现象**: app 启动后报无法连接数据库，迁移无法执行
- **根因**: paradedb 镜像 entrypoint 的 `exec postgres` 不带 listen_addresses，默认只听 localhost，拒绝跨容器连接
- **修复**: `docker-compose.override.yml` 中指定 `command: ["postgres", "-c", "listen_addresses=*", "-c", "shared_preload_libraries=pg_search"]`
- **预防**: 任何用官方 paradedb/postgres 镜像做跨容器部署的场景都显式设置 listen_addresses

### #5 `CREATE EXTENSION pg_search` SIGBUS 打崩 postgres 后端
- **现象**: 迁移执行到一半后端 signal 7 Bus error，schema_migrations 停在 dirty 状态
- **根因**: 双重——(a) #2 磁盘写满事故导致镜像层内 pg_search.so 本地损坏；(b) pg_search 必须 `shared_preload_libraries=pg_search` 预加载（层损坏修复后才暴露的真实需求）
- **修复**: `docker rmi paradedb/paradedb:v0.25.11-pg17 && docker pull` 重拉镜像（修 a）→ override 加 shared_preload_libraries（修 b）→ `down -v` 重建
- **预防**: 同 #2；另 ParadeDB 升级大版本时先确认 pg_search 预加载参数

### #6 迁移中断：pg_isready 健康检查误报 healthy 的竞态
- **现象**: 表数异常偏少（12 张 vs 完整 75 张）、schema_migrations dirty，迁移没有真正执行完
- **根因**: paradedb 初始化/恢复阶段会先起临时服务器，pg_isready 对临时实例也返回 healthy，app 抢先启动连上后被杀，迁移中断
- **修复**: override 把 healthcheck 换成真实 SQL 查询:
  ```yaml
  healthcheck:
    test: ["CMD-SHELL", "psql -U \"$$POSTGRES_USER\" -d \"$$POSTGRESDB\" -c 'SELECT 1' >/dev/null 2>&1"]
  ```
  并在 app 的 depends_on 上加 `condition: service_healthy`
- **预防**: 所有带数据初始化的 compose 栈，健康检查都要用真实业务查询而不是 pg_isready/ping 类浅探测。迁移完成后核验基线: **v0.8.3 = schema_migrations 118 版本 not dirty、75 张表**

### #7 UI 注册报 "failed to create workspace"
- **现象**: 注册时红色 toast "failed to create workspace"（后端 Register → CreateTenant 失败）
- **根因**: 注册请求恰好落在面板「停止→启动」的全栈 down/up 重启窗口期，app 无可用数据库
- **修复**: 重启完成后注册即成功（容器 17:50:26–49 重建，17:54 起服务健康）；清理了测试产生的脏 tenants/users
- **预防**: 使用期间不要在面板点 WeKnora「停止」（= 整个 Docker 栈下线含数据库）；给状态检测留出健康检查时间，别在 up 后立刻发请求

### #8 本机模型（LM Studio）SSRF 校验失败
- **现象**: 配置 Base URL `http://localhost:1234/v1` 报 "SSRF validation failed: hostname localhost is restricted"
- **根因**: WeKnora 的 SSRF 防护默认拦截 localhost/内网地址，需显式白名单
- **修复**: .env 添加（已生效，app + docreader 均读取）:
  ```
  SSRF_WHITELIST_EXTRA=localhost,127.0.0.1,host.docker.internal
  ```
- **关键认知**: Docker 容器内 localhost 指向容器自身而非宿主机，**Base URL 必须填 `http://host.docker.internal:1234/v1`** 才能访问宿主机上的 LM Studio / Ollama（compose 已内置 `extra_hosts: host.docker.internal:host-gateway`）。容器内验证: `docker compose exec app curl http://host.docker.internal:1234/v1/models`

### #9 电脑重启后 redis / app 崩溃循环
- **现象**: 宿主机重启后 Docker 自动拉起容器，但 docker 面板显示 WeKnora-app、WeKnora-redis 反复重启（Restarting），UI 能开但功能不可用
- **根因**:
  1. redis: 非正常关机导致 AOF 增量文件 `appendonlydir/appendonly.aof.N.incr.aof` 末尾写入被截断（日志: `Bad file format reading the append only file ... use ./redis-check-aof --fix`），redis 拒绝加载，启动即退出；
  2. app: redis 反复退出期间容器网络端点被摘除，app 连不上 redis（日志: `连接Redis失败: dial tcp: lookup redis on 127.0.0.11:53: no such host`），启动 panic，跟着 crash loop。
- **修复**（顺序不能反，先修 redis 再管 app）:
  ```bash
  # 1. 从崩溃循环中的容器拷出 AOF 目录（docker cp 对停止/重启中的容器可用，exec 不行）
  mkdir -p /tmp/aoffix && docker cp WeKnora-redis:/data/appendonlydir /tmp/aoffix/appendonlydir
  # 2. 用官方工具修复（会截断到最后一个完整命令，只丢关机前半截写入）
  docker run --rm -v /tmp/aoffix:/fix redis:7.0-alpine sh -c "echo y | redis-check-aof --fix /fix/appendonlydir/appendonly.aof.N.incr.aof"
  # 3. 拷回容器并拉起
  docker cp /tmp/aoffix/appendonlydir/appendonly.aof.N.incr.aof WeKnora-redis:/data/appendonlydir/
  docker compose -f docker-compose.yml -f docker-compose.override.yml --env-file .env up -d redis app
  ```
- **注意**: redis 服务未声明持久化卷，AOF 在容器可写层——`down` 重建容器会丢 redis 数据（影响仅限 asynq 任务队列等瞬态数据，主数据在 postgres）。且容器重建后此修复手段（docker cp）失效，只能 down -v 重新来
- **排查提示**: 看到 app 报 `lookup redis ... no such host`，是下游症状，根因在 redis 自身，别去改 app 配置
- **预防**: 宿关机前先在面板停 WeKnora（优雅停机，compose stop 会 SIGTERM 让 redis 落盘）；重启后先进 Docker 面板看有没有容器处于 Restarting，别直接开始用

### #10 官方 README / 网页抓取被拦截
- **现象**: WebFetch 对 github.com 与 raw.githubusercontent.com 均失败
- **修复**: 改用 `curl -sL <url> | tr -d '\r'` 落盘再读
- **说明**: 仅影响信息收集方式，不影响部署本身，记录备查

## 生产部署前置检查清单

按序执行，全部打勾再 up:

- [ ] 宿主机磁盘剩余 > 8GB（否则必然触发 #2 连锁故障）
- [ ] Docker Desktop 已启动且 daemon 正常（不用 pkill 重启）
- [ ] .env 从 .env.example 复制，密钥全部随机生成，`WEKNORA_VERSION` 为真实存在的 release tag（勿用 latest）
- [ ] 端口 18090/18091 未被占用（被占则改 FRONTEND_PORT/APP_PORT）
- [ ] `docker-compose.override.yml` 存在且三处修正齐全（listen_addresses / pg_search 预加载 / psql healthcheck）
- [ ] `docker compose -f docker-compose.yml -f docker-compose.override.yml --env-file .env config` 校验无警告
- [ ] `./ops/backup.sh` 先做一次基线备份再动数据
- [ ] 启动后核验: 5 容器 healthy、迁移基线（118 版本 not dirty / 75 张表）、UI 200、API `{"status":"ok"}`
- [ ] 配本机模型时: 白名单变量 + Base URL 用 `host.docker.internal`（见 #8）

## 环境注意事项（补充）

- Docker Desktop 的 VM 内存仅 7.75GB（Settings → Resources 可调大），全栈 + 模型推理时注意宿主机内存压力
- 未启用可选 profile（minio 对象存储 / neo4j 图谱 / langfuse 追踪 / qdrant 等向量库），默认 ParadeDB pgvector 存储向量；需要时: `docker compose --profile minio --profile neo4j up -d`
- Docker 沙箱后端默认关闭（WEKNORA_SANDBOX_DOCKER_ENABLED=false），开启等同宿主机 root，仅私有化单机按需开
- override 文件中 SSRF_WHITELIST_EXTRA 已含本机直连地址，升级重新生成 .env 时勿遗漏（可从 .env.example 的新版注释确认变量名是否有变）
