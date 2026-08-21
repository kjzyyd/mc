# mc-one-click-server

无头 Linux 一键开 Minecraft 服务器工具。单文件脚本，自动选版本、下载服务端、匹配 Java、写 EULA、生成配置并开服，支持多开与 mod 平台。

## 核心用法

```bash
# 一键交互：选类型 → 选版本 → 自动开服(含引导式常用设置)
./mc.sh

# 常用命令
./mc.sh install paper 1.21.4    # 指定类型+版本安装
./mc.sh start / run / stop / restart / status
./mc.sh settings                # 引导式常用设置(正版验证/端口/白名单/模式/难度...)
./mc.sh cmd 'list'              # 给运行中的服务器发指令
./mc.sh console / log           # 附加控制台 / 实时日志
./mc.sh ps                      # 列出所有运行中的多开实例
./mc.sh config                  # 高级：直接编辑 server.properties
./mc.sh versions                # 浏览可选版本
```

## 支持的服务端类型

| 类型 | 说明 |
|------|------|
| `paper` | Paper，高效/插件端（默认推荐） |
| `vanilla` | 官方原版（含快照） |
| `purpur` / `folia` | Paper 的增强 / 多线程分支 |
| `fabric` | Fabric mod 平台 |
| `forge` | 经典 Forge mod 平台 |
| `neoforge` | NeoForge mod 平台（1.20.5+） |

## 多开（多服务器）

- 每个实例 = 一个独立目录，实例名取目录名（可用 `INSTANCE=<名>` 覆盖）。
- 各实例独立 screen 会话（`mc-<实例>`）与配置文件，互不冲突。
- 端口被占用时自动顺延到空闲端口（已写入 `server.properties`）。

```bash
mkdir myserver && cd myserver && /path/to/mc.sh   # 再开一个服
./mc.sh ps                                          # 查看运行中的实例
```

## 系统要求

- Linux（Debian/Ubuntu 系自动装 `screen`/JDK/curl/jq）
- 出网（安装时从 Mojang / PaperMC / Forge / Fabric 下载服务端）
- 已请求你是否同意 Minecraft EULA（安装时提示）

## 环境变量（可选）

| 变量 | 说明 | 默认 |
|------|------|------|
| `MC_DIR` | 服务器根目录 | 当前目录 |
| `INSTANCE` | 实例名 | 目录名 |
| `RAM` | 内存 MB | 系统内存一半(1G~16G 夹取) |
| `PORT`/`MOTD`/`GAMEMODE`/`DIFFICULTY`/`MAX_PLAYERS` | 开服配置 | — |
```

## License

MIT