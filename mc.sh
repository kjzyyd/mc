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
#     ./mc.sh console         # 附加到服务器控制台
#     ./mc.sh cmd 'say hi'    # 向运行中的服务器发一条指令
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
UA="mc-oneshot/1.0 (https://github.com/yourname/mc-server-oneshot)"
VANILLA_MANIFEST="https://launchermeta.mojang.com/mc/game/version_manifest_v2.json"
PAPER_API="https://fill.papermc.io/v3/projects"
FORGE_DATA="https://files.minecraftforge.net/net/minecraftforge/forge/promo_maven_slim.json"
FORGE_MAVEN="https://maven.minecraftforge.net/net/minecraftforge/forge"
NEOFORGE_META="https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
NEOFORGE_MAVEN="https://maven.neoforged.net/releases/net/neoforged/neoforge"
FABRIC_META="https://meta.fabricmc.net/v2/versions"

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
  curl -sfL -H "User-Agent: $UA" "$VANILLA_MANIFEST" \
    | jq -r '.versions[] | select(.type=="release" or .type=="snapshot") | .id'
}
dl_vanilla() { # (version) -> server.jar
  local v="$1" m url jar
  m=$(curl -sfL -H "User-Agent: $UA" "$VANILLA_MANIFEST") || die "无法获取原版版本清单"
  url=$(echo "$m" | jq -r --arg v "$v" '.versions[]|select(.id==$v)|.url')
  [ -n "$url" ] && [ "$url" != "null" ] || die "原版没有该版本: $v"
  jar=$(curl -sfL -H "User-Agent: $UA" "$url" | jq -r '.downloads.server.url') \
    || die "无法解析 $v 下载地址"
  curl -sfL -H "User-Agent: $UA" -o server.jar "$jar" || die "下载失败: $jar"
}

# Fill v3 (paper / purpur / waterfall / bungeecord ...)
list_paper() { # (project) -> versions newest-first, 逗号分隔-> 换行
  local proj="$1"
  curl -sfL -H "User-Agent: $UA" "$PAPER_API/$proj" \
    | jq -r '.versions | to_entries | sort_by(.key) | reverse | map(.key)[]'
}
paper_download_urls() { # (project version) -> stdout: one download url
  local proj="$1" v="$2" json url
  json=$(curl -sfL -H "User-Agent: $UA" "$PAPER_API/$proj/versions/$v/builds") || return 1
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
  curl -sfL -H "User-Agent: $UA" -o server.jar "$url" || die "下载失败: $url"
}

# Fabric: 单文件启动物 + 首次运行联网补库
list_fabric() {
  curl -sfL -H "User-Agent: $UA" "$FABRIC_META/game" \
    | jq -r '.[] | select(.stable==true) | .version'
}
dl_fabric() { # (mc version) -> server.jar
  local v="$1" loader installer
  loader=$(curl -sfL -H "User-Agent: $UA" "$FABRIC_META/loader/$v" | jq -r '.[0].loader.version') \
    || die "未获取到 $v 的 fabric loader"
  installer=$(curl -sfL -H "User-Agent: $UA" "$FABRIC_META/installer" | jq -r '.[0].version')
  curl -sfL -H "User-Agent: $UA" -o server.jar \
    "$FABRIC_META/loader/$v/$loader/$installer/server/jar" || die "fabric 服务端下载失败"
}

# Forge(经典 MinecraftForge): 通过 --installServer 生成启动环境
list_forge() { # MC 版本(有 forge 支持的最新在前)
  curl -sfL -H "User-Agent: $UA" "$FORGE_DATA" \
    | jq -r '.promos | to_entries
             | map(select(.key|test("-(recommended|latest)$")))
             | map(.key | sub("-(recommended|latest)$";""))
             | unique | sort | reverse[]'
}
forge_build() { # (mc) -> 最新 forge 构建号
  curl -sfL -H "User-Agent: $UA" "$FORGE_DATA" \
    | jq -r --arg rec "$1-recommended" --arg lat "$1-latest" '.promos[$rec] // .promos[$lat]'
}
dl_forge() { # (mc version) 安装 forge
  local v="$1" fb inst java
  fb=$(forge_build "$v")
  [ -n "$fb" ] && [ "$fb" != "null" ] || die "forge 没有 $v 对应的构建"
  FORGE_VERSION="$fb"
  inst="forge-$v-$fb-installer.jar"
  curl -sfL -H "User-Agent: $UA" -o "$inst" "$FORGE_MAVEN/$v-$fb/$inst" || die "forge 安装器下载失败"
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
  curl -sfL -H "User-Agent: $UA" "$NEOFORGE_META" \
    | grep -o '<version>[^<]*</version>' | sed -E 's#</?version>##g' | grep -v '^$' | tac
}
dl_neoforge() { # (neoforge version)
  local ver="$1" inst java
  inst="neoforge-$ver-installer.jar"
  curl -sfL -H "User-Agent: $UA" -o "$inst" "$NEOFORGE_MAVEN/$ver/$inst" \
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
  [ ${#raw[@]} -gt 0 ] || die "无法获取版本列表(可能网络受限), 可手动指定: ./mc.sh install $dist <版本>"
  # 去重并保留最新有序
  local uniq=() prev=""
  for l in "${raw[@]}"; do [ "$l" != "$prev" ] && uniq+=("$l"); prev="$l"; done

  echo ""
  echo "================ 可用版本(${dist}) ================"
  local n=${#uniq[@]}
  for ((i=0;i<n;i++)); do printf '%3d) %s\n' $((i+1)) "${uniq[i]}"; done
  echo "   0) 手动输入版本号"
  echo "==============================================="
  local sel
  read -rp "请选择版本编号 [$(($n>30?n:1))-$n]: " sel 2>/dev/null || sel=""
  if [ "$sel" = "0" ] || [ -z "$sel" ]; then
    read -rp "手动输入版本号(如 1.21.4 / 26.2): " v
  elif [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "$n" ]; then
    v="${uniq[$((sel-1))]}"
  else
    warn "输入无效, 使用最新版本"
    v="${uniq[0]}"
  fi
  VERSION="$v"
}

# ------------------------------ 安装 / 下载 --------------------------------
install_server() {
  check_deps_lazy
  local dist="${1:-paper}" ver="${2:-}"
  load_conf
  # 覆盖安装时清空旧产物字段
  DISTRIBUTION="$dist"
  BUILD="latest"
  FORGE_VERSION=""
  UNIX_ARGS=""
  SERVER_JAR="server.jar"

  if [ -n "$ver" ]; then VERSION="$ver"; else pick_version "$dist"; fi
  [ -n "$VERSION" ] || VERSION="latest"

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

  # EULA - 首次自动接受(开源协议要求用户确认)
  if [ ! -f "$MC_DIR/eula.txt" ]; then
    warn "一次点击即视为同意 Minecraft EULA (https://aka.ms/MinecraftEULA)"
    printf 'eula=true\n' > "$MC_DIR/eula.txt"
    ok "已写入 eula.txt"
  fi

  # 保存元数据
  cat > "$CONF" <<EOF
DISTRIBUTION="$DISTRIBUTION"
VERSION="$VERSION"
BUILD="latest"
SERVER_JAR="$SERVER_JAR"
FORGE_VERSION="$FORGE_VERSION"
UNIX_ARGS="$UNIX_ARGS"
EOF
  ok "安装完成(实例=$INSTANCE)。可用: ./mc.sh start 开服"
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
    echo "motd=${MOTD:-A Headless MC Server by mc.sh}"
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
  ensure_free_port
  make_server_cmd
  say "启动 $DISTRIBUTION $VERSION (后台 screen 模式, 端口 $(current_port))"
  # shellcheck disable=SC2086
  screen -dmS "$SNAME" bash -lc "cd '$MC_DIR' && exec $SERVER_CMD >> '$MC_DIR/logs/latest.log' 2>&1"
  sleep 3
  if session_alive; then
    ok "服务器已后台启动 (session=$SNAME, 端口 $(current_port))"
    ok "查看日志: ./mc.sh log   发送指令: ./mc.sh cmd 'help'   附加控制台: ./mc.sh console"
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
set_prop() { # key value (不存在则追加)
  local k="$1" v="$2" f="$MC_DIR/server.properties"
  if grep -q "^${k}=" "$f"; then sed -i "s|^${k}=.*|${k}=${v}|" "$f"; else echo "${k}=${v}" >> "$f"; fi
  ok "已设置: $k = $v"
}

config_menu() { # 高级: 直接编辑 server.properties 的任意键
  load_conf
  [ -f "$MC_DIR/server.properties" ] || die "请先 ./mc.sh install 生成配置"
  local f="$MC_DIR/server.properties"
  while :; do
    echo ""
    echo "=========== server.properties ==========="
    grep -v '^#' "$f" | grep -v '^$' | nl -ba
    echo "========================================"
    read -rp "要修改的键(或回车退出): " k
    [ -z "$k" ] && break
    if grep -q "^${k}=" "$f"; then
      read -rp "$k = " v; [ -n "$v" ] && set_prop "$k" "$v"
    else
      warn "未找到键: $k (支持上表任意键名)"
    fi
  done
  ok "配置已完成, 重启生效: ./mc.sh restart"
}

# ---------- 常用设置引导式菜单(友好配置) ----------
yn() { # 归一化为 true/false
  case "${1,,}" in y|yes|true|1|on) echo true;; *) echo false;; esac
}
prompt_yn() { # label current
  local ans
  read -rp "$1 [当前=$2] (y/n): " ans >&2
  [ -n "$ans" ] && yn "$ans" || echo "$2"
}
pick_enum() { # label current options...  (stdout 只输出最终值)
  local label="$1" cur="$2"; shift 2
  printf '可选: %s\n' "$*" >&2
  local ans
  read -rp "$label [当前=$cur]: " ans >&2
  printf '%s' "${ans:-$cur}"
}

settings_menu() {
  load_conf
  [ -f "$MC_DIR/server.properties" ] || ensure_properties
  local v
  while :; do
    echo ""
    echo "================ 常用设置 ================"
    echo "当前端口: $(get_prop server-port || echo 25565)"
    echo "  1) 端口 server-port:        $(get_prop server-port)"
    echo "  2) 正版验证 online-mode:    $(get_prop online-mode)    (验证正版用户, 盗版服请关)"
    echo "  3) 白名单 white-list:       $(get_prop white-list)"
    echo "  4) 游戏模式 gamemode:       $(get_prop gamemode)"
    echo "  5) 难度 difficulty:         $(get_prop difficulty)"
    echo "  6) 允许PVP pvp:             $(get_prop pvp)"
    echo "  7) 最大玩家 max-players:    $(get_prop max-players)"
    echo "  8) 服务器欢迎语 motd:        $(get_prop motd)"
    echo "  9) 视距 view-distance:      $(get_prop view-distance)"
    echo " 10) 出生点保护 spawn:        $(get_prop spawn-protection)"
    echo " 11) 命令方块 allow-cmdblock: $(get_prop enable-command-block)"
    echo "按对应数字修改, 其他键退出"
    read -rp "> " c
    case "$c" in
      1) v=$(pick_enum "端口(1-65535)" "$(get_prop server-port || echo 25565)" 10000 25565 25566); set_prop server-port "$v";;
      2) v=$(prompt_yn "是否验证正版用户(online-mode)" "$(get_prop online-mode || echo true)"); set_prop online-mode "$v";;
      3) v=$(prompt_yn "白名单(white-list)" "$(get_prop white-list || echo true)"); set_prop white-list "$v";;
      4) v=$(pick_enum "游戏模式(gamemode)" "$(get_prop gamemode || echo survival)" survival creative adventure spectator); set_prop gamemode "$v";;
      5) v=$(pick_enum "难度(difficulty)" "$(get_prop difficulty || echo easy)" peaceful easy normal hard); set_prop difficulty "$v";;
      6) v=$(prompt_yn "允许PVP" "$(get_prop pvp || echo true)"); set_prop pvp "$v";;
      7) v=$(pick_enum "最大玩家数" "$(get_prop max-players || echo 20)" 5 10 20 50); set_prop max-players "$v";;
      8) read -rp "MOTD(欢迎语, 当前: $(get_prop motd)): " v; [ -n "$v" ] && set_prop motd "$v";;
      9) v=$(pick_enum "视距(view-distance)" "$(get_prop view-distance || echo 10)" 8 10 12 16); set_prop view-distance "$v";;
      10) v=$(pick_enum "出生点保护半径" "$(get_prop spawn-protection || echo 16)" 0 1 16); set_prop spawn-protection "$v";;
      11) v=$(prompt_yn "允许命令方块(enable-command-block)" "$(get_prop enable-command-block || echo false)"); set_prop enable-command-block "$v";;
      *) break;;
    esac
  done
  ok "设置已保存。改端口/正版等需重启生效: ./mc.sh restart"
}

choose_dist() {
  # 菜单输出到 stderr, 仅把最终选择印到 stdout(供 $(...) 捕获)
  echo "选择服务端类型:" >&2
  echo "  1) paper    Paper(高效/插件, 推荐)" >&2
  echo "  2) vanilla  原版官方(含快照)" >&2
  echo "  3) purpur   Purpur(Paper 增强)" >&2
  echo "  4) folia    Folia(多线程实验)" >&2
  echo "  5) fabric   Fabric(mod 加载, 轻量快速)" >&2
  echo "  6) forge    Forge(经典 mod 平台)" >&2
  echo "  7) neoforge NeoForge(1.20.5+ 主流 mod 平台)" >&2
  read -rp "类型 [1-7]: " t >&2
  case "${t:-1}" in
    1) echo paper;; 2) echo vanilla;; 3) echo purpur;; 4) echo folia;;
    5) echo fabric;; 6) echo forge;; 7) echo neoforge;;
    *) echo paper;;
  esac
}

version_list() {
  local dist="${1:-paper}"
  check_deps_lazy
  say "$dist 可用版本(最新在前):"
  list_dist "$dist"
}

version_menu() {
  install_server "$(choose_dist)"
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
    echo "========== mc.sh 一键开服 =========="
    echo "检测到尚未安装服务器, 开始引导安装..."
    version_menu
    echo ""
    echo "安装完成。现在开服吗? [Y/n]"
    read -rp "> " r
    case "${r:-Y}" in
      y|Y|"") start ;;
      *) say "已跳过开服, 稍后执行 ./mc.sh start" ;;
    esac
    return
  fi
  echo ""
  echo "========== mc.sh 服务器管理 (实例=$INSTANCE) =========="
  echo "  1) 开服(start)   2) 停止(stop)   3) 重启(restart)"
  echo "  4) 状态(status)  5) 控制台(console)  6) 发送指令(cmd)"
  echo "  7) 看日志(log)   8) 常用设置(settings)  9) 重新安装(换版本)"
  echo "  A) 多开实例列表   0) 退出"
  read -rp "请选择: " c
  case "${c:-0}" in
    1) start;; 2) stop;; 3) stop; start;;
    4) status;; 5) attach;; 6) read -rp "指令: " x; cmd_send "$x";;
    7) view_log;; 8) settings_menu;; 9) install_server "$(choose_dist)";;
    a|A) list_instances;;
    *) exit 0;;
  esac
}

# ------------------------------ 入口 ---------------------------------------
main() {
  local action="${1:-menu}"; shift || true
  case "$action" in
    install)   install_server "${1:-paper}" "${2:-}" ;;
    start)     start ;;
    run)       run_foreground ;;
    stop)      stop ;;
    restart)   stop; start ;;
    status)    status ;;
    console)   attach ;;
    cmd)       cmd_send "${1?缺少指令参数字符串}" ;;
    log)       view_log ;;
    versions)  version_list "$(choose_dist)"; echo; say "安装示例: ./mc.sh install <类型> <版本>" ;;
    ps|instances|list) list_instances ;;
    settings)  settings_menu ;;
    config)    config_menu ;;
    help|-h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)         menu ;;
  esac
}

main "$@"