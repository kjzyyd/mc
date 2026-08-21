#!/usr/bin/env bash
# ============================================================================
#  mc.sh — 无头 Linux 一键开服脚本 (Headless Linux Minecraft Server One-Click)
# ============================================================================
#  说明: 单文件脚本，自动选择版本、下载服务端、装/选 Java、写 EULA、
#        生成 server.properties、后台(screen)或前台开服，并提供运维命令。
#
#  用法:
#     ./mc.sh                 # 交互菜单(未装则一键 install+start)
#     ./mc.sh install         # 下载/安装服务端(可选: type version)
#     ./mc.sh start           # 后台开服(screen)
#     ./mc.sh run             # 前台开服(适合 systemd/docker/no-tty)
#     ./mc.sh stop            # 优雅停机
#     ./mc.sh restart         # 重启
#     ./mc.sh status          # 运行状态
#     快捷命令: on/up=开, off/down=停, rs/re=重启, st=状态
#     ./mc.sh console         # 附加到服务器控制台
#     ./mc.sh cmd 'say hi'    # 向运行中的服务器发一条指令
#     ./mc.sh mod              # 交互: 粘贴 mod 下载链接, 自动下载到 mods 文件夹
#     ./mc.sh mod <链接> [...] # 直接给链接下载多个 mod
#     ./mc.sh log             # 实时查看日志
#     ./mc.sh versions        # 列出可选版本
#     ./mc.sh settings        # 引导式常用设置(正版验证/端口/白名单/模式/难度...)
#     ./mc.sh config          # 高级: 直接编辑 server.properties
#
#  支持服务端类型:
#     vanilla  原版官方(含快照) / paper(高效,推荐) / purpur / folia
#     fabric   Fabric(mod) / forge Forge(mod) / neoforge NeoForge(mod)
#
#  多开(多服务器):
#     - 每个实例 = 一个独立目录, 实例名默认取目录名(可 INSTANCE=<名> 覆盖)
#     - 各实例独立 screen 会话(mc-<实例名>)与配置, 互不冲突, 可同时启动多个
#     - ./mc.sh ps         列出所有运行中的实例
#     - 想多开: mkdir 新目录 && cd 进去 && ./mc.sh 即可
#
#  环境变量/MC_DIR/server.conf 可覆盖默认:
#     MC_DIR      服务器根目录(默认: 当前目录)
#     INSTANCE    实例名(默认: 目录名, 决定 screen 会话与配置文件)
#     RAM         内存(MB)  默认: 系统内存一半, 1G~16G 之间
#     MOTD|PORT|GAMEMODE|DIFFICULTY|MAX_PLAYERS  开服配置
# ============================================================================

set -euo pipefail

# ----------------------------- 通用工具函数 ---------------------------------
say()  { printf '\033[1;36m[mc]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }

die() { err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------ 路径/常量与多开标识 --------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="${MC_DIR:-$PWD}"
# 多开: 每个实例用独立的 screen 会话名与元配置文件, 由目录名派生,
#        亦可显式用 INSTANCE=<名> 覆盖。同目录下的多实例互不干扰。
_instance_default="$(basename "$MC_DIR" | tr 'A-Z ' 'a-z_' | tr -cd 'a-z0-9_')"
_instance_default="${_instance_default:-server}"
INSTANCE="${INSTANCE:-$_instance_default}"
SNAME="mc-$INSTANCE"
CONF="$MC_DIR/server-$INSTANCE.conf"
UA="mc-oneshot/1.0 (https://github.com/kjzyyd/mc)"
# 数据源地址可用环境变量覆盖, 便于指向镜像/代理(如大陆网络访问官方 API 被限速时)
VANILLA_MANIFEST="${VANILLA_MANIFEST:-https://launchermeta.mojang.com/mc/game/version_manifest_v2.json}"
PAPER_API="${PAPER_API:-https://fill.papermc.io/v3/projects}"
FORGE_DATA="${FORGE_DATA:-https://files.minecraftforge.net/net/minecraftforge/forge/promo_maven_slim.json}"
FORGE_MAVEN="${FORGE_MAVEN:-https://maven.minecraftforge.net/net/minecraftforge/forge}"
NEOFORGE_META="${NEOFORGE_META:-https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml}"
NEOFORGE_MAVEN="${NEOFORGE_MAVEN:-https://maven.neoforged.net/releases/net/neoforged/neoforge}"
FABRIC_META="${FABRIC_META:-https://meta.fabricmc.net/v2/versions}"

# 硬化版请求: 带连接/总超时 + 重试, 避免元数据 API 卡住或瞬时失败导致"获取版本错误"
cget() { # 输出到 stdout; 失败返回非 0
  curl -sfL -A "$UA" --connect-timeout 8 --max-time 25 \
       --retry 2 --retry-delay 1 --retry-all-errors "$@"
}

export JVM_FLAGS=""

# ------------------------------ 版本要求查询 ---------------------------------
# 配置元数据读写
load_conf() { [ -f "$CONF" ] && . "$CONF" || true; }

# --------- 选择并确认 Java (按 Minecraft 版本自动匹配) ---------
required_java() {
  local v="$1"
  case "$v" in
    1.8*|1.9*|1.1[0-6]*)                echo 8 ;;
    1.17*|1.18*|1.19*|1.20.[0-4]*)       echo 17 ;;
    *)                                    echo 21 ;;
  esac
}

java_major_system() {
  java -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p'
}

find_java() {
  local want="$1" b
  for b in /usr/lib/jvm/java-$want-openjdk-*/bin/java \
           /usr/lib/jvm/java-$want-openjdk/bin/java \
           /usr/lib/jvm/java-$want*/bin/java; do
    [ -x "$b" ] && { echo "$b"; return 0; }
  done
  if need_cmd java && [ "$(java_major_system)" = "$want" ]; then
    command -v java; return 0
  fi
  return 1
}

install_java() {
  local want="$1"
  local pkg="openjdk-${want}-jre-headless"
  warn "未找到 Java $want, 尝试安装 $pkg ..."
  if [ "$EUID" -eq 0 ]; then
    apt-get update -y && apt-get install -y "$pkg"
  else
    command -v apt-get >/dev/null 2>&1 || die "不支持在此系统自动安装(仅支持 apt/Debian/Ubuntu), 请手动安装 Java $want"
    sudo apt-get update -y && sudo apt-get install -y "$pkg"
  fi
  find_java "$want" && return 0
  die "Java $want 安装失败, 请手动安装后重试"
}

check_deps_lazy() {
  for d in curl jq; do
    need_cmd "$d" || die "缺少依赖 $d, 请执行: sudo apt-get install -y $d"
  done
  # screen 仅后台模式需要, 不强制预装
}

# ------------------------------ 内存推荐 ------------------------------------
auto_ram() {
  local tot kb
  tot=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
  kb=${tot:-0}; kb=$(( kb > 0 ? kb : 2048000 ))
  local mb=$(( kb / 1024 )); local half=$(( mb / 2 ))
  half=$(( half < 1024 ? 1024 : half )); half=$(( half > 16384 ? 16384 : half ))
  echo "$half"
}

# ------------------------------ 下载器 --------------------------------------
# vanilla: 官方原版
list_vanilla() { # -> 空格分隔 id:type
  cget "$VANILLA_MANIFEST" \
    | jq -r '.versions[] | select(.type=="release" or .type=="snapshot") | .id'
}
dl_vanilla() { # (version) -> server.jar
  local v="$1" m url jar
  m=$(cget "$VANILLA_MANIFEST") || die "无法获取原版版本清单"
  url=$(echo "$m" | jq -r --arg v "$v" '.versions[]|select(.id==$v)|.url')
  [ -n "$url" ] && [ "$url" != "null" ] || die "原版没有该版本: $v"
  jar=$(cget "$url" | jq -r '.downloads.server.url') \
    || die "无法解析 $v 下载地址"
  cget -o server.jar "$jar" || die "下载失败: $jar"
}

# Fill v3 (paper / purpur / waterfall / bungeecord ...)
list_paper() { # (project) -> versions newest-first, 逗号分隔-> 换行
  local proj="$1"
  cget "$PAPER_API/$proj" \
    | jq -r '.versions | to_entries | sort_by(.key) | reverse | map(.key)[]'
}
paper_download_urls() { # (project version) -> stdout: one download url
  local proj="$1" v="$2" json url
  json=$(cget "$PAPER_API/$proj/versions/$v/builds") || return 1
  url=$(echo "$json" | jq -r '
        ( [ .[] | select(.channel=="STABLE" or .channel=="RECOMMENDED") ] | last
          .downloads."server:default".url ) // ( .[] | last | .downloads."server:default".url // empty )')
  if [ -n "$url" ] && [ "$url" != "null" ]; then echo "$url"; return 0; fi
  # 兜底: 任意可用 server:default url
  url=$(echo "$json" | jq -r '[.[] | .downloads."server:default".url] | map(select(.!=null)) | last // empty')
  if [ -n "$url" ] && [ "$url" != "null" ]; then echo "$url"; return 0; fi
  return 1
}
dl_paper() { # (project version) -> server.jar
  local proj="$1" v="$2" url
  url=$(paper_download_urls "$proj" "$v")
  [ -n "$url" ] || die "$proj $v 没有可用 STABLE 构建(或网络不通)"
  cget -o server.jar "$url" || die "下载失败: $url"
}

# Fabric: 单文件启动物 + 首次运行联网补库
list_fabric() {
  cget "$FABRIC_META/game" \
    | jq -r '.[] | select(.stable==true) | .version'
}
dl_fabric() { # (mc version) -> server.jar
  local v="$1" loader installer
  loader=$(cget "$FABRIC_META/loader/$v" | jq -r '.[0].loader.version') \
    || die "未获取到 $v 的 fabric loader"
  installer=$(cget "$FABRIC_META/installer" | jq -r '.[0].version')
  cget -o server.jar \
    "$FABRIC_META/loader/$v/$loader/$installer/server/jar" || die "fabric 服务端下载失败"
}

# Forge(经典 MinecraftForge): 通过 --installServer 生成启动环境
list_forge() { # MC 版本(有 forge 支持的最新在前)
  cget "$FORGE_DATA" \
    | jq -r '.promos | to_entries
             | map(select(.key|test("-(recommended|latest)$")))
             | map(.key | sub("-(recommended|latest)$";""))
             | unique | sort | reverse[]'
}
forge_build() { # (mc) -> 最新 forge 构建号
  cget "$FORGE_DATA" \
    | jq -r --arg rec "$1-recommended" --arg lat "$1-latest" '.promos[$rec] // .promos[$lat]'
}
dl_forge() { # (mc version) 安装 forge
  local v="$1" fb inst java
  fb=$(forge_build "$v")
  [ -n "$fb" ] && [ "$fb" != "null" ] || die "forge 没有 $v 对应的构建"
  FORGE_VERSION="$fb"
  inst="forge-$v-$fb-installer.jar"
  cget -o "$inst" "$FORGE_MAVEN/$v-$fb/$inst" || die "forge 安装器下载失败"
  need_cmd java || die "forge 安装需要 java"
  java="$(command -v java)"
  say "运行 Forge 安装器 --installServer ..."
  "$java" -jar "$inst" --installServer >/dev/null 2>&1 || die "forge --installServer 失败"
  rm -f "$inst"
  UNIX_ARGS="$(ls "libraries/net/minecraftforge/forge/$v-$fb/unix_args.txt" 2>/dev/null | head -n1)"
  SERVER_JAR="$(ls forge-*-universal.jar 2>/dev/null | head -n1)"
  [ -n "$UNIX_ARGS" ] || [ -n "$SERVER_JAR" ] \
    || die "forge 安装产物异常(未找到 unix_args.txt / universal.jar)"
}

# NeoForge: 自 1.20.5 起的主流 mod 平台, 同样走 --installServer
list_neoforge() { # neoforge 版本号(新版在前)
  cget "$NEOFORGE_META" \
    | grep -o '<version>[^<]*</version>' | sed -E 's#</?version>##g' | grep -v '^$' | tac
}
dl_neoforge() { # (neoforge version)
  local ver="$1" inst java
  inst="neoforge-$ver-installer.jar"
  cget -o "$inst" "$NEOFORGE_MAVEN/$ver/$inst" \
    || die "neoforge 安装器下载失败"
  need_cmd java || die "neoforge 安装需要 java"
  java="$(command -v java)"
  say "运行 NeoForge 安装器 --installServer ..."
  "$java" -jar "$inst" --installServer >/dev/null 2>&1 || die "neoforge --installServer 失败"
  rm -f "$inst"
  UNIX_ARGS="$(ls "libraries/net/neoforged/neoforge/$ver/unix_args.txt" 2>/dev/null | head -n1)"
  [ -n "$UNIX_ARGS" ] || die "neoforge 安装产物异常(未找到 unix_args.txt)"
}

# 统一的"列出某类型版本"派发
list_dist() {
  local dist="$1"
  case "$dist" in
    vanilla) list_vanilla ;;
    paper|purpur|folia|waterfall|bungeecord) list_paper "$dist" ;;
    fabric) list_fabric ;;
    forge) list_forge ;;
    neoforge) list_neoforge ;;
    *) die "不支持的服务端类型: $dist" ;;
  esac
}

# ------------------------------ 版本选择菜单 --------------------------------
pick_version() {
  local dist="$1"
  say "获取 $dist 可选版本中..."
  local raw=()
  while IFS= read -r l; do raw+=( "$l" ); done < <(list_dist "$dist")
  if [ ${#raw[@]} -eq 0 ]; then
    if ! command -v jq >/dev/null 2>&1; then
      die "缺少依赖 jq(JAVA 版本列表解析工具), 请执行: sudo apt-get install -y jq ; 装完重试"
    fi
    die "获取 $dist 版本列表失败(官方 API 被屏蔽或超时), 可:\n  a) 用镜像: VANILLA_MANIFEST/PAPER_API/FABRIC_META/... 指向镜像后再试\n  b) 手动指定版本跳过列表: ./mc.sh install $dist <版本>"
  fi
  # 去重并保留最新有序
  local uniq=() prev=""
  for l in "${raw[@]}"; do [ "$l" != "$prev" ] && uniq+=("$l"); prev="$l"; done

  local v=""
  while :; do
    echo ""
    echo "================ 可用版本(${dist}) ================"
    local n=${#uniq[@]}
    for ((i=0;i<n;i++)); do printf '%3d) %s\n' $((i+1)) "${uniq[i]}"; done
    echo "   0) 手动输入版本号"
    echo "==============================================="
    read -rp "请选择版本编号 [1-$n], 0 手动输入, 回车取最新: " sel || return 1
    if [ "$sel" = "0" ]; then
      read -rp "手动输入版本号(如 1.21.4 / 26.2): " v || return 1
      [ -n "$v" ] && { VERSION="$v"; break; }
      warn "版本号不能为空, 请再选一次"
    elif [ -z "$sel" ]; then
      warn "好的, 就用最新版本: ${uniq[0]}"
      VERSION="${uniq[0]}"; break
    elif [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "$n" ]; then
      VERSION="${uniq[$((sel-1))]}"; break
    else
      warn "没这个选项, 请从列表里选一个编号"
    fi
  done
}

# ------------------------------ 安装 / 下载 --------------------------------
install_server() {
  check_deps_lazy
  local dist="${1:-paper}" ver="${2:-}"
  load_conf
  local prev_d="${DISTRIBUTION:-}" prev_v="${VERSION:-}"
  # 覆盖安装时清空旧产物字段
  DISTRIBUTION="$dist"
  BUILD="latest"
  FORGE_VERSION=""
  UNIX_ARGS=""
  SERVER_JAR="server.jar"

  if [ -n "$ver" ]; then VERSION="$ver"; else pick_version "$dist"; fi
  [ -n "$VERSION" ] || VERSION="latest"

  # 已装过同类型+同版本 且 服务端文件还在 => 直接复用, 跳过重复下载
  if [ "$prev_d" = "$dist" ] && [ "$prev_v" = "$VERSION" ] \
     && [ -n "$SERVER_JAR" ] && [ -f "$MC_DIR/$SERVER_JAR" ]; then
    say "已装好: $dist @ $VERSION, 直接复用, 不用再下载"
    ensure_eula
    ok "服务端可用了, 直接开服即可: ./mc.sh start (或菜单选 1)"
    return 0
  fi

  mkdir -p "$MC_DIR"
  cd "$MC_DIR"

  say "下载 $dist 服务端..."
  case "$dist" in
    vanilla)   dl_vanilla "$VERSION" ;;
    paper|purpur|waterfall|bungeecord|folia) dl_paper "$dist" "$VERSION" ;;
    fabric)    dl_fabric "$VERSION" ;;
    forge)     dl_forge "$VERSION" ;;
    neoforge)  dl_neoforge "$VERSION" ;;
    *) die "不支持的服务端类型: $dist (可选 vanilla/paper/purpur/folia/fabric/forge/neoforge)" ;;
  esac

  [ -n "$SERVER_JAR" ] && ok "服务端文件: $MC_DIR/$SERVER_JAR ($dist @ $VERSION)" \
                       || ok "服务端已生成: $dist @ $VERSION (启动方式: @$UNIX_ARGS)"

  # EULA - 自动同意开服协议
  ensure_eula

  # 保存元数据
  cat > "$CONF" <<EOF
DISTRIBUTION="$DISTRIBUTION"
VERSION="$VERSION"
BUILD="latest"
SERVER_JAR="$SERVER_JAR"
FORGE_VERSION="$FORGE_VERSION"
UNIX_ARGS="$UNIX_ARGS"
EOF
  ok "安装完成啦 (实例=$INSTANCE) → $dist @ $VERSION"
  echo ""
  echo "    接下来只需两步:"
  echo "    1. 开服:    ./mc.sh start"
  echo "    2. 进服:    你在游戏里添加服务器 IP, 地址就是这台机的 IP:端口"
  echo "       (默认端口 25565, 可用 ./mc.sh settings 修改, 或是上面给到的实际端口)"
  echo "    小提示: 如果朋友连不上, 多半是防火墙/云安全组没放行端口, 记得去控制台开放 TCP 端口"
  echo ""
  say "想换个版本重装? 随时 ./mc.sh install 重新选就行, 不怕"
}

# ------------------------- 构建启动 JVM 参数与命令 ---------------------------
make_server_cmd() {
  local req jm java sys
  req=$(required_java "$VERSION")
  sys=$(java_major_system 2>/dev/null || echo 0)
  jm=0
  if java=$(find_java "$req"); then
    jm="$req"
  else
    warn "版本 $VERSION 建议 Java $req, 当前系统 Java=$sys, 尝试用现有 Java 启动..."
    if [ "$sys" -ge "$req" ] && need_cmd java; then
      java="$(command -v java)"; jm="$sys"
    else
      install_java "$req"
      java=$(find_java "$req"); jm="$req"
    fi
  fi

  local ram="${RAM:-$(auto_ram)}"
  local flags=(
    "-Xms${ram}M" "-Xmx${ram}M"
    "-XX:+UseG1GC" "-XX:+ParallelRefProcEnabled" "-XX:MaxGCPauseMillis=200"
    "-XX:InitiatingHeapOccupancyPercent=20" "-Djava.awt.headless=true"
  )
  if [ "$jm" -ge 11 ]; then
    local g1=("-XX:G1NewSizePercent=30" "-XX:G1MaxNewSizePercent=40"
              "-XX:G1HeapRegionSize=8M" "-XX:G1ReservePercent=20"
              "-XX:G1MixedGCCountTarget=4")
    # JDK 23+ 将部分 G1 调优参数标为实验性, 需显式解锁
    [ "$jm" -ge 23 ] && flags+=("-XX:+UnlockExperimentalVMOptions")
    flags+=("${g1[@]}")
  fi
  if [ "$jm" -ge 17 ] && [ "$jm" -lt 23 ]; then
    flags+=("-XX:+UseStringDeduplication")
  fi
  flags+=("-Dterminal.ansi=false")

  # forge/neoforge 用生成的 unix_args 启动, 其余 -jar 启动
  case "$DISTRIBUTION" in
    forge|neoforge)
      if [ -n "${UNIX_ARGS:-}" ] && [ -f "$MC_DIR/$UNIX_ARGS" ]; then
        SERVER_CMD="${java} ${flags[*]} @$MC_DIR/$UNIX_ARGS nogui"
      elif [ -n "${SERVER_JAR:-}" ] && [ -f "$MC_DIR/$SERVER_JAR" ]; then
        SERVER_CMD="${java} ${flags[*]} -jar ${SERVER_JAR} nogui"
      else
        die "${DISTRIBUTION} 未正确安装(unix_args/服务端文件缺失), 请重新 install"
      fi ;;
    fabric)
      local fjar="${SERVER_JAR:-server.jar}"
      [ -f "$MC_DIR/$fjar" ] || die "fabric 未安装($fjar 缺失)"
      SERVER_CMD="${java} ${flags[*]} -jar ${fjar} nogui" ;;
    *)
      [ -f "$MC_DIR/${SERVER_JAR:-server.jar}" ] || die "${SERVER_JAR:-server.jar} 缺失, 请重新 install"
      SERVER_CMD="${java} ${flags[*]} -jar ${SERVER_JAR} nogui" ;;
  esac
}

# 默认 server.properties (避免首启卡交互)
ensure_properties() {
  local f="$MC_DIR/server.properties"
  [ -f "$f" ] && return 0
  {
    echo "motd=${MOTD:-欢迎来到我的世界服务器 — mc.sh一键开服}"
    echo "server-port=${PORT:-25565}"
    echo "gamemode=${GAMEMODE:-survival}"
    echo "difficulty=${DIFFICULTY:-easy}"
    echo "max-players=${MAX_PLAYERS:-20}"
    echo "online-mode=true"
    echo "spawn-protection=16"
    echo "view-distance=10"
    echo "enable-command-block=false"
    echo "white-list=false"
    echo "pvp=true"
  } > "$f"
  ok "已生成默认 server.properties"
}

# ---------- 多开端口自适应: 端口被占用时自动顺延到空闲端口 ----------
port_in_use() { # (port) -> 0=被占用
  local p="$1"
  if need_cmd ss; then
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$" && return 0 || return 1
  else
    (echo >/dev/tcp/127.0.0.1/"$p") 2>/dev/null && return 0 || return 1
  fi
}
ensure_eula() { # 开服/安装时自动同意 EULA(用户下载即视为同意官方条款)
  [ -f "$MC_DIR/eula.txt" ] && grep -qi '^eula=true' "$MC_DIR/eula.txt" && return 0
  warn "自动同意 Minecraft 最终用户许可协议 EULA (https://aka.ms/MinecraftEULA)"
  printf 'eula=true\n' > "$MC_DIR/eula.txt"
  ok "已写入 eula.txt (同意开服协议)"
}

ensure_free_port() {
  local f="$MC_DIR/server.properties"
  [ -f "$f" ] || return 0
  local p; p=$(sed -n 's/^server-port=\([0-9][0-9]*\).*/\1/p' "$f" | head -n1)
  [ -n "$p" ] || p=25565
  if port_in_use "$p"; then
    local np="$p" i
    for i in $(seq $((p+1)) 25640); do
      port_in_use "$i" || { np=$i; break; }
    done
    warn "端口 $p 已被其它实例占用, 自动改用端口 $np(已写入 server.properties)"
    sed -i "s/^server-port=.*/server-port=$np/" "$f"
  fi
}
current_port() {
  printf -v p '%s' "$(sed -n 's/^server-port=\([0-9][0-9]*\).*/\1/p' "$MC_DIR/server.properties" 2>/dev/null | head -n1)"
  echo "${p:-25565}"
}

# ------------------------------ 启动/停止 ------------------------------------
run_foreground() {
  check_deps_lazy
  load_conf
  [ -f "$CONF" ] || die "尚未安装, 请先执行 ./mc.sh install"
  cd "$MC_DIR"
  ensure_properties
  ensure_eula
  ensure_free_port
  make_server_cmd
  say "启动 $DISTRIBUTION $VERSION (前台模式, 端口 $(current_port))"
  say "启动命令: ${SERVER_CMD}"
  # shellcheck disable=SC2086
  eval "$SERVER_CMD"
}

start() {
  check_deps_lazy
  load_conf
  [ -f "$CONF" ] || die "尚未安装, 请先执行 ./mc.sh install"
  if session_alive; then ok "服务器已在运行(session: $SNAME)"; return 0; fi

  need_cmd screen || {
    warn "缺少 screen, 尝试安装..."
    if [ "$EUID" -eq 0 ]; then apt-get update -y && apt-get install -y screen
    else command -v apt-get >/dev/null 2>&1 && sudo apt-get update -y && sudo apt-get install -y screen
    fi
    need_cmd screen || die "请手动安装 screen 后重试: sudo apt-get install -y screen"
  }

  cd "$MC_DIR"
  mkdir -p logs
  ensure_properties
  ensure_eula
  ensure_free_port
  make_server_cmd
  say "启动 $DISTRIBUTION $VERSION (后台 screen 模式, 端口 $(current_port))"
  # shellcheck disable=SC2086
  screen -dmS "$SNAME" bash -lc "cd '$MC_DIR' && exec $SERVER_CMD >> '$MC_DIR/logs/latest.log' 2>&1"
  sleep 3
  if session_alive; then
    ok "服务器已后台启动 (session=$SNAME, 端口 $(current_port))"
    echo ""
    echo "    搞定, 现在可以进服玩了! 游戏里添加服务器:  IP:$(current_port)"
    echo "      在本机连就用 127.0.0.1, 朋友远程连就用你服务器的公网 IP"
    echo "    小提示: 朋友连不上通常是防火墙/云安全组没放行端口, 记得去控制台放行 TCP $(current_port)"
    echo ""
    say "运维命令: 日志 ./mc.sh log · 发指令 ./mc.sh cmd 'help' · 控制台 ./mc.sh console"
  else
    err "启动失败，日志:"
    tail -n 40 "$MC_DIR/logs/latest.log" 2>/dev/null || true
    exit 1
  fi
}

session_alive() { screen -ls 2>/dev/null | grep -q "$SNAME"; }
screen_pid() {
  screen -ls 2>/dev/null | grep "$SNAME" | grep -oE '[0-9]+' | head -n1
}

stop() {
  load_conf
  if ! session_alive; then warn "服务器未在运行"; return 0; fi
  say "正在发送 stop 指令(优雅停机)..."
  screen -S "$SNAME" -p 0 -X stuff 'stop^M'
  for _ in $(seq 1 30); do
    session_alive || { ok "服务器已停止"; return 0; }
    sleep 1
  done
  warn "超时未退出, 强制结束。PID: $(screen_pid)"
  screen -S "$SNAME" -X quit 2>/dev/null && ok "已停止" || warn "请手动结束进程"
}

status() {
  load_conf
  if session_alive; then
    ok "运行中: $DISTRIBUTION $VERSION  (screen=$SNAME)"
    local pid; pid=$(screen_pid)
    say "PID=$pid   内存: $(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f MB", $1/1024}')"
  else
    warn "未运行 ($DISTRIBUTION ${VERSION:-未安装})"
    [ -f "$CONF" ] && say "可使用 ./mc.sh start 开服"
  fi
}

# ------------------------------ 交互命令 ------------------------------------
cmd_send() { load_conf; session_alive || die "服务器未运行"; screen -S "$SNAME" -p 0 -X stuff "${1}^M"; ok "已发送: $1"; }
view_log()  { load_conf; tail -f "$MC_DIR/logs/latest.log"; }
attach()    { load_conf; session_alive || die "服务器未运行"; exec screen -r "$SNAME"; }

# ---------- server.properties 读写助手 ----------
get_prop() { sed -n "s|^$1=\(.*\)|\1|p" "$MC_DIR/server.properties" 2>/dev/null | head -n1; }
set_prop() { # key value (不存在则追加; 转义 sed 特殊字符以免 MOTD 颜色码等被破坏)
  local k="$1" v="$2" f="$MC_DIR/server.properties"
  local e; e="$(printf '%s' "$v" | sed 's/[\\&|]/\\&/g')"
  if grep -q "^${k}=" "$f"; then sed -i "s|^${k}=.*|${k}=${e}|" "$f"; else echo "${k}=${v}" >> "$f"; fi
  ok "已设置: $k = $v"
}

config_menu() { # 高级: 菜单式编辑 server.properties 的任意键(无需手敲键名)
  load_conf
  [ -f "$MC_DIR/server.properties" ] || die "请先 ./mc.sh install 生成配置"
  local f="$MC_DIR/server.properties"
  while :; do
    echo ""
    echo "=========== server.properties(按编号挑选) ==========="
    mapfile -t keys < <(grep -v '^#' "$f" | grep -v '^$' | cut -d= -f1)
    [ ${#keys[@]} -eq 0 ] && { warn "配置是空的"; return; }
    local _i=0 _k
    for _k in "${keys[@]}"; do
      _i=$((_i+1))
      printf '  %2d) %-30s = %s\n' "$_i" "$_k" "$(get_prop "$_k")"
    done
    echo "     A) 添加新键   (0) 返回"
    read -rp "选一个编号去修改: " sel || return
    if [ "$sel" = "0" ] || [ -z "$sel" ]; then break; fi
    if [ "$sel" = "A" ] || [ "$sel" = "a" ]; then
      read -rp "新键名: " nk || return
      [ -n "$nk" ] || continue
      read -rp "$nk = " nv || continue
      [ -n "$nv" ] && { printf '%s=%s\n' "$nk" "$nv" >>"$f"; ok "已添加: $nk = $nv"; }
      continue
    fi
    [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#keys[@]}" ] || { [ -z "$sel" ] && warn "回车前先选个编号" || warn "没有这个编号"; continue; }
    _k="${keys[$((sel-1))]}"
    read -rp "$_k = " v
    [ -n "$v" ] && set_prop "$_k" "$v"
  done
  ok "配置已完成, 重启生效: ./mc.sh restart"
}

# ---------- 常用设置引导式菜单(数据驱动, 全中文) ----------
# 每个设置条目格式: 键名;中文说明;类型;默认值  (顶层用 ';', 枚举内才用 '|', 二者不冲突)
#   类型: bool                      -> 是/否
#         num / str                 -> 数字 / 文本
#         enum:值|中文,值|中文       -> 选择列表(也允许直接输入原生值)
cn_bool() { case "${1,,}" in true|on|yes|1) echo 是;; *) echo 否;; esac; }

prompt_yn() { # 说明 当前值(默认用当前) -> true/false
  local ans
  read -rp "$1 (是/否) [当前=$2]: " ans >&2
  case "${ans,,}" in
    y|yes|是|true|1|on) echo true ;;
    n|no|否|false|0|off) echo false ;;
    *) echo "${2:-false}" ;;
  esac
}

prompt_enum() { # 说明 当前值 "选项|中文,选项|中文" -> 选中的值
  local label="$1" cur="$2" opts="$3"
  IFS=',' read -r -a pairs <<<"$opts"
  local i pair val cn mark
  printf '选项:\n' >&2
  for i in "${!pairs[@]}"; do
    pair="${pairs[$i]}"; val="${pair%%|*}"; cn="${pair#*|}"
    mark=""; [ "$val" = "$cur" ] && mark="  ← 当前"
    printf '  %2d) %-14s(%s)%s\n' "$((i+1))" "$cn" "$val" "$mark" >&2
  done
  read -rp "$label [当前=$cur]: " ans >&2
  if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#pairs[@]}" ]; then
    echo "${pairs[$((ans-1))]%%|*}"; return
  fi
  [ -n "$ans" ] || ans="$cur"
  echo "$ans"   # 允许直接输入原生值
}

edit_setting() { # 条目 "键;说明;类型;默认"
  local IFS=';' key label type default; read -r key label type default <<<"$1"
  local cur v; cur="$(get_prop "$key")"; [ -z "$cur" ] && cur="$default"
  case "$type" in
    bool)        v=$(prompt_yn "$label" "$cur") ;;
    enum:*)      v=$(prompt_enum "$label" "$cur" "${type#enum:}") ;;
    num)         read -rp "$label [当前=$cur]: " v >&2
                 [[ "$v" =~ ^[0-9]+$ ]] || v="${v:-$cur}" ;;
    *)           read -rp "$label [当前=$cur]: " v >&2
                 [ -n "$v" ] || v="$cur" ;;
  esac
  [ -n "$v" ] && set_prop "$key" "$v"
}

i18n_cat() { # 分类标题 条目...
  local title="$1"; shift
  local entries=("$@")
  while :; do
    echo ""
    echo "================== $title =================="
    local i=0 e key label type default cur dis
    for e in "${entries[@]}"; do
      i=$((i+1))
      IFS=';' read -r key label type default <<<"$e"
      cur="$(get_prop "$key")"; [ -z "$cur" ] && cur="$default"
      case "$type" in bool) dis=$(cn_bool "$cur");; *) dis="$cur";; esac
      printf '  %2d) %-20s 当前=%s\n' "$i" "$label" "$dis"
    done
    echo "  (0) 返回上层"
    read -rp "$(printf '选择 1-%d 修改, 0 返回: ' "$i")" sel || return
    if [ "$sel" = "0" ] || [ -z "$sel" ]; then break; fi
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "$i" ]; then
      edit_setting "${entries[$((sel-1))]}"
    else
      warn "输入无效, 请重新选择"
    fi
  done
}

# ---- 设置分组数据 ----
set_base=( # 基础与端口
  'server-port;服务器端口(1-65535);num;25565'
  'server-ip;服务器绑定IP(一般留空);str;'
  'online-mode;正版账号验证;bool;true'
  'motd;服务器欢迎语(MOTD);str;欢迎来到我的世界服务器'
  'enforce-secure-profile;仅正版注册会话(防盗);bool;true'
  'max-players;最大玩家数;num;20'
  'player-idle-timeout;挂机踢出(分钟,0为不踢);num;0'
  'white-list;开启白名单;bool;false'
  'enforce-whitelist;强制白名单(拒绝未在白名单的人);bool;false'
)
set_world=( # 世界与生成
  'level-name;世界文件夹名;str;world'
  'level-type;世界类型;enum:minecraft:normal|普通,flat|超平坦,large_biomes|大型生物群系,amplified|放大,single_biome_surface|单一生态系;minecraft:normal'
  'seed;世界种子(留空随机);str;'
  'generate-structures;生成村庄等结构;bool;true'
  'allow-nether;启用下界(地狱);bool;true'
  'spawn-protection;出生点保护半径(0为关);num;16'
  'spawn-animals;生成动物;bool;true'
  'spawn-monsters;生成怪物;bool;true'
  'spawn-npcs;生成村民;bool;true'
)
set_play=( # 游戏玩法
  'gamemode;默认游戏模式;enum:survival|生存,creative|创造,adventure|冒险,spectator|旁观;survival'
  'difficulty;游戏难度;enum:peaceful|和平,easy|简单,normal|普通,hard|困难;easy'
  'pvp;允许玩家互殴(PVP);bool;true'
  'enable-command-block;允许命令方块;bool;false'
  'command-block-output;命令方块输出到聊天;bool;true'
  'allow-flight;允许飞行(防外挂误踢);bool;false'
  'hardcore;极限模式(死亡永久);bool;false'
  'announce-player-achievements;广播进度成就;bool;true'
)
set_perf=( # 性能
  'view-distance;玩家视距(区块);num;10'
  'simulation-distance;模拟距离(区块);num;10'
  'max-tick-time;卡顿判定毫秒(0为关);num;60000'
  'network-compression-threshold;网络压缩阈值(0为关);num;256'
  'max-world-size;最大世界尺寸(区块);num;29999984'
  'prevent-proxy-connections;禁止代理连接喷射(反作弊);bool;false'
)

# 写入内存配置(下次启动生效)
set_ram() {
  local v="$1"
  sed -i '/^RAM=/d' "$CONF" 2>/dev/null || true
  printf 'RAM=%s\n' "$v" >>"$CONF"
  ok "已设置内存: $v MB (下次启动生效)"
}

# 菜单式分配内存: 给常用档位 + 自定义, 非法输入重试, 0 保持不变
edit_ram() {
  load_conf
  local rec cur
  rec=$(auto_ram)
  cur="${RAM:-$rec}"
  while :; do
    echo ""
    echo "== 设置服务器内存 (当前: ${cur}MB, 本机推荐: ${rec}MB) =="
    echo "  1) $rec MB      (本机自动推荐)"
    echo "  2) 1024 MB   (1G, 小服/纯生存开荒)"
    echo "  3) 2048 MB   (2G, 基础小服)"
    echo "  4) 4096 MB   (4G, 多数小服都够)"
    echo "  5) 8192 MB   (8G, 中大型多人服)"
    echo "  6) 16384 MB  (16G, 大型整合包/高配)"
    echo "  7) 自定义"
    echo "  (0) 保持不变"
    read -rp "请选内存档位: " c || return
    case "${c:-}" in
      ""|0) say "保持: $cur MB"; return ;;
      1) set_ram "$rec"; return ;;
      2) set_ram 1024; return ;;
      3) set_ram 2048; return ;;
      4) set_ram 4096; return ;;
      5) set_ram 8192; return ;;
      6) set_ram 16384; return ;;
      7) read -rp "输入自定义内存(MB): " v || return
         if [[ "$v" =~ ^[0-9]+$ ]]; then set_ram "$v"; return; fi
         warn "要填数字哦(比如 3072), 再选一次" ;;
      *) warn "没有 [${c}] 这个档位, 再选一次" ;;
    esac
  done
}

settings_menu() {
  load_conf
  [ -f "$MC_DIR/server.properties" ] || ensure_properties
  while :; do
    echo ""
    echo "==================== 服务器设置(分类) ===================="
    echo "  1) 基础与端口(端口/正版/MOTD/玩家/白名单)"
    echo "  2) 世界与生成"
    echo "  3) 游戏玩法(模式/难度/PVP/命令方块)"
    echo "  4) 性能(视距/模拟距离/压缩)"
    echo "  5) 启动内存 RAM 分配"
    echo "  6) 高级设置(直接编辑 server.properties)"
    echo "  (0) 返回上一级"
    read -rp "请选择分类: " c || break
    case "$c" in
      1) i18n_cat "基础与端口" "${set_base[@]}" ;;
      2) i18n_cat "世界与生成" "${set_world[@]}" ;;
      3) i18n_cat "游戏玩法" "${set_play[@]}" ;;
      4) i18n_cat "性能" "${set_perf[@]}" ;;
      5) edit_ram ;;
      6) config_menu ;;
      *) break ;;
    esac
  done
  ok "设置已保存。端口/正版/内存等需重启生效: ./mc.sh restart"
}

# ---------- 安装 Mod(mods 文件夹下载) ----------
need_mods_dir() { mkdir -p "$MC_DIR/mods"; }

# 下载单个 mod: 填写直链(Modrinth/CurseForge 提供的文件下载地址, 或任意 .jar 直链)
dl_mod() {
  local url="$1" name
  name=$(basename "${url%%\?*}")
  [ -n "$name" ] && [ "$name" != "/" ] || name="mod-$(date +%s).jar"
  say "正在下载: $name"
  curl -sfL -A "$UA" -o "$MC_DIR/mods/$name" "$url" \
    || { warn "下载失败: $url"; rm -f "$MC_DIR/mods/$name"; return 1; }
  local magic; magic=$(head -c 4 "$MC_DIR/mods/$name" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    504b*) ;; # PK... 是 jar/zip 开头, 正常
    *) warn "${name} 看着不像包会魔术字节, 可能链接需登录或返回了网页, 已删除"
       rm -f "$MC_DIR/mods/$name"; return 1 ;;
  esac
  ok "已安装: mods/$name"
}

mod_menu() { # 交互: 一次性粘贴多个链接(空格分隔)
  need_mods_dir
  local u urls
  while :; do
    local cnt=$(ls "$MC_DIR/mods" 2>/dev/null | wc -l)
    echo ""
    echo "== 安装 Mod (mods 目录已有 $cnt 个文件) =="
    echo "  说明: 去 Modrinth/CurseForge 复制 mod 的【下载文件的直链】粘贴进来即可."
    echo "        也可以一次贴好几个, 用空格隔开; 想删掉某个文件去 $MC_DIR/mods 里手动删就行."
    read -rp "粘贴下载链接(可多个), 回车返回: " urls || break
    [ -z "$urls" ] && break
    for u in $urls; do dl_mod "$u"; done
    echo ""
    read -rp "还要继续装其它 mod 吗? [Y/n] " go || break
    case "${go:-Y}" in n|N|no|否) break;; esac
  done
}

choose_dist() { # 菜单走 stderr, 选择结果印到 stdout(供 $(...) 捕获); 非法输入重试, 0 取消
  while :; do
    echo "" >&2
    echo "== 第 1 步 · 选择服务端类型 ==" >&2
    echo "  1) paper     Paper(高效/插件, 推荐, 支持众多插件)" >&2
    echo "  2) vanilla   原版官方(最干净, 含快照)" >&2
    echo "  3) purpur    Purpur(Paper 增强, 更多特性)" >&2
    echo "  4) folia     Folia(多线程实验性, 生态不成熟慎用)" >&2
    echo "  5) fabric    Fabric(mod 加载, 轻量快速)" >&2
    echo "  6) forge     Forge(经典 mod 平台, 老馒头最爱)" >&2
    echo "  7) neoforge  NeoForge(1.20.5+ 主流 mod 平台)" >&2
    echo "  0) 算了, 取消" >&2
    read -rp "请输入数字 [1-7], 0 取消: " t >&2 || { echo ""; return 1; }
    case "${t:-}" in
      0) echo ""; return 1 ;;
      1) echo paper;; 2) echo vanilla;; 3) echo purpur;; 4) echo folia;;
      5) echo fabric;; 6) echo forge;; 7) echo neoforge;;
      "") warn "回车前请先选一个数字哦" >&2; continue ;;
      *) warn "没有 [${t}] 这个选项, 再选一次" >&2; continue ;;
    esac
    return 0
  done
}

version_list() {
  local dist="${1:-paper}"
  check_deps_lazy
  say "$dist 可用版本(最新在前):"
  list_dist "$dist"
}

# 安装向导: 逐步让用户选择, 每一步都有明确选项, 取消可随时返回
guided_install() {
  local dist
  echo ""
  echo "=============================================="
  echo "    mc.sh 安装向导 —— 跟着提示一步步选就好"
  echo "=============================================="
  dist=$(choose_dist) || { warn "好, 已取消安装"; return; }
  say "选好了: 服务端类型 = $dist"

  echo ""
  say "第 2 步 · 选版本"
  pick_version "$dist" || { warn "好, 已取消安装"; return; }
  say "选好了: 版本 = $VERSION"

  echo ""
  say "第 3 步 · 下载安装 (类型=$dist, 版本=$VERSION)"
  install_server "$dist" "$VERSION"

  echo ""
  say "第 4 步 · 分配内存(也给个推荐值给你参考)"
  edit_ram

  echo ""
  read -rp "第 5 步 · 现在要不要趁热配置一下服务器(端口/正版验证/难度/模式等)? [Y/n] " s
  case "${s:-Y}" in
    y|Y|"") settings_menu ;;
    *) warn "好, 先用默认设置, 想改随时 ./mc.sh settings" ;;
  esac
}

# ---------- 多开管理: 列出所有运行中实例与已知实例目录 ----------
list_instances() {
  echo "== 运行中的 mc 实例(多开) =="
  local f=0 s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    echo "  [运行中] $s   (screen -r $s 附加)"
    f=1
  done < <(screen -ls 2>/dev/null | grep -oE 'mc-[a-zA-Z0-9_]+' | sort -u)
  [ "$f" = "0" ] && echo "  (当前没有运行中的实例)"
  echo "== 当前目录附近已安装的实例(目录名即实例) =="
  local k=0 g
  for g in "$PWD"/*/server-*.conf; do
    [ -f "$g" ] || continue
    echo "  $(basename "$(dirname "$g")")   -> cd <该目录> && ./mc.sh <start|stop|status>"
    k=1
  done
  [ "$k" = "0" ] && echo "  (当前目录下暂无已安装实例)"
  echo "提示: 想在别处再开一个服, 直接建新目录进去运行 ./mc.sh 即可, 端口在 server.properties 里改"
}

menu() {
  if [ ! -f "$CONF" ]; then
    echo ""
    echo "  欢迎使用 mc.sh —— 无头 Linux 一键开服"
    echo "  第一次使用, 来, 我带你装一个服务器, 全程傻瓜式, 每步都有选项."
    echo ""
    guided_install
    if [ -f "$CONF" ]; then
      echo ""
      read -rp "开服已经是最后一步了, 现在就要开服吗? [Y/n] " r
      case "${r:-Y}" in
        y|Y|"") start ;;
        *) say "好, 先不开。想玩的时候敲 ./mc.sh start 就启动啦" ;;
      esac
    else
      warn "看来中途取消了, 随时再跑一次 ./mc.sh 重新开始向导"
    fi
    return
  fi
  local _st="未运行"; session_alive && _st="运行中:端口$(current_port)"
  echo ""
  echo "  欢迎回来!  当前实例: $INSTANCE  |  状态: $_st"
  echo "  =========================================="
  echo "   1) 开服         2) 停止         3) 重启"
  echo "   4) 状态         5) 控制台       6) 发指令"
  echo "   7) 日志         8) 设置中心      9) 换版本重装"
  echo "   M) 安装 Mod      A) 多开实例      0) 退出"
  echo "  =========================================="
  read -rp "  想做点什么? 输入数字或字母: " c
  case "${c:-0}" in
    1) start;; 2) stop;; 3) stop; start;;
    4) status;; 5) attach;; 6) read -rp "  要发的指令(如 help): " x; cmd_send "$x";;
    7) view_log;; 8) settings_menu;; 9) guided_install;;
    m|M) mod_menu;;
    a|A) list_instances;;
    *) echo "  下次再来玩~ 拜拜"; exit 0;;
  esac
}

# ------------------------------ 入口 ---------------------------------------
main() {
  local action="${1:-menu}"; shift || true
  case "$action" in
    install)   install_server "${1:-paper}" "${2:-}" ;;
    start|on|up)   start ;;
    run)       run_foreground ;;
    stop|off|down) stop ;;
    restart|rs|re) stop; start ;;
    status|st) status ;;
    console)   attach ;;
    cmd)       cmd_send "${1?缺少指令参数字符串}" ;;
    log)       view_log ;;
    versions)  version_list "$(choose_dist)"; echo; say "安装示例: ./mc.sh install <类型> <版本>" ;;
    ps|instances|list) list_instances ;;
    settings)  settings_menu ;;
    config)    config_menu ;;
    mod)      if [ $# -eq 0 ]; then mod_menu; else local _u; for _u in "$@"; do dl_mod "$_u"; done; fi ;;
    help|-h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)         menu ;;
  esac
}

main "$@"