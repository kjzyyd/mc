# mc-one-click-server

无头 Linux 一键开 Minecraft 服务器工具。单文件脚本，自动选版本、下载服务端、匹配 Java、写 EULA、生成配置并开服，支持多开与 mod 平台。

## 核心用法

```bash
# 一键交互：安装向导，逐步选择(服务端类型 → 版本 → 内存 → 设置 → 开服)
./mc.sh

# 常用命令
./mc.sh install paper 1.21.4    # 指定类型+版本安装
./mc.sh start / run / stop / restart / status
./mc.sh settings                # 全中文分类设置(基础/世界/玩法/性能/内存/高级)
# 服务端包装好后即缓存：同类型+同版本再跑 install 不会重复下载，直接复用
./mc.sh on / off / rs / st      # 快捷命令：开/停/重启/状态
./mc.sh cmd 'list'              # 给运行中的服务器发指令
./mc.sh console / log           # 附加控制台 / 实时日志
./mc.sh ps                      # 列出所有运行中的多开实例
./mc.sh config                  # 高级：直接编辑 server.properties
./mc.sh versions                # 浏览可选版本
./mc.sh mod                     # 交互：粘贴 mod 下载链接 → 自动下载到 mods 文件夹
./mc.sh mod "<链接>" [...]      # 直接给一个或多个 mod 直链下载
```

## 安装 Mod

开服前先选 `fabric`/`forge`/`neoforge` 等 mod 平台，然后：

- 去 Modrinth / CurseForge 找到 某 mod 的 **下载文件直链**（一般是 `.jar`，可能带 `?` 参数）；
- 运行 `./mc.sh mod`，把链接粘贴进去（一次可贴多个，空格隔开），脚本会自动下载到 `<实例目录>/mods/`；
- 也会校验下载到的确实是个 `.jar`（不是登录页/HTML）；下载失败或无效会提示并清理；
- 命令行直链：`./mc.sh mod "https://xxx/mod.jar" "https://yyy/mod2.jar"`；
- 装完记得 `./mc.sh restart` 让服务器加载新 mod。

## 支持的服务端类型

| 类型 | 说明 |
|------|------|
| `paper` | Paper，高效/插件端（默认推荐） |
| `vanilla` | 官方原版（含快照） |
| `purpur` / `folia` | Paper 的增强 / 多线程分支 |
| `fabric` | Fabric mod 平台 |
| `forge` | 经典 Forge mod 平台 |
| `neoforge` | NeoForge mod 平台（1.20.5+） |

## 设置中心（全中文分类）

`./mc.sh settings` 提供数据驱动的分类设置菜单，所有提示与选项均为中文，常用项开箱即用：

| 分类 | 覆盖内容 |
|------|----------|
| 1 基础与端口 | 端口、正版验证、MOTD 欢迎语、最大玩家、白名单、挂机踢出 |
| 2 世界与生成 | 世界名/类型/种子、村庄等结构、下界、动物/怪物/村民、出生点保护 |
| 3 游戏玩法 | 生存/创造/冒险模式、难度、PVP、命令方块、飞行、极限模式 |
| 4 性能 | 视距、模拟距离、卡顿判定、压缩阈值、世界大小 |
| 5 内存 RAM | 档位菜单：本机推荐/1G~16G/自定义 |
| 6 高级 | 菜单按编号挑选任意键编辑（可添加新键） |

- 所有入口均为菜单：布尔项「是/否」，枚举项直接选序号（也可输入原生值），内存选档位。
- 改完端口/正版/内存等需 `./mc.sh restart` 生效。

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