#!/usr/bin/env bash
###############################################################################
# OnePlus Kernel 本地构建脚本 (local_build.sh)
#
# 本脚本是 .github/workflows/Build Kernel OnePlus.yml 的本地化版本。
# 它在本地复刻了 GitHub Actions 工作流的核心构建逻辑，方便不依赖 CI 直接出包。
#
# 运行环境要求:
#   - Linux 或 Windows WSL2 (Ubuntu 推荐)，无法在原生 Windows PowerShell 运行。
#   - 已安装 sudo / git / curl / python3。
#   - 至少 ~80GB 可用磁盘空间，>=16GB 内存(或开启 swap)。
#
# 使用方式:
#   chmod +x local_build.sh
#   ./local_build.sh                       # 使用下方默认配置构建
#   FILE=oneplus_13_b ./local_build.sh     # 通过环境变量覆盖机型
#   ./local_build.sh --file oneplus_13_b --kpm KPN --no-fast-build
#
# 产物:
#   $WORKROOT/AnyKernel3/  以及 $WORKROOT/AnyKernel3_*.zip
###############################################################################

set -euo pipefail

###############################################################################
# 一、可配置参数 (对应工作流 workflow_dispatch.inputs，可用环境变量或命令行覆盖)
###############################################################################

# 配置文件(机型)，见 README / FILE.md
FILE="${FILE:-oneplus_ace2_pro_b}"
# 管理器调用方向: MIUIX | MIUIX_SPOOF | MD3 | MD3_SPOOF
MANAGER_SOURCE="${MANAGER_SOURCE:-MIUIX}"
# SUSFS 模块下载: CI | Release | N/A
SUSFS_CI="${SUSFS_CI:-N/A}"
# 内核模块实现方式: KPM | KPN | N/A
KPM="${KPM:-KPM}"
# 回退 SUSFS(哈希/次数/-1关闭)，留空使用最新
SUSFS_META="${SUSFS_META:-}"
# 动态清单仓库所有者
DYNAMIC_REPO="${DYNAMIC_REPO:-tycykp}"
# 自定义构建时间(F=使用UTC，-1=关闭)
BUILD_TIME="${BUILD_TIME:-Fri Dec 12 11:37:03 UTC 2025}"
# 分支名/自定义版本标识/回退哈希 (必须含两个 /)
KSU_META="${KSU_META:-builtin/tycykp/}"
# 是否升级 LZ4 到上游最新
LZ4_UPDATE="${LZ4_UPDATE:-false}"
# ZRAM: 开关0/1 / 算法名 / 大小
ZRAM="${ZRAM:-0/lz4kd/8589934592}"
# 自定义内核后缀(留空=随机伪官方后缀，-1=关闭)
SUFFIX="${SUFFIX:-}"
# 自定义内核等级欺骗 SUBLEVEL，留空保持默认
SUBLEVEL="${SUBLEVEL:-}"
# 极速构建(直接 make)；false 则回退官方脚本/bazel
FAST_BUILD="${FAST_BUILD:-true}"
# 关键分区写入保护模块 BBG
LSM_BBG="${LSM_BBG:-true}"
# 网络功能拓展 NETFILTER
NETFILTER="${NETFILTER:-true}"
# 网络拥塞控制 BBR+ECN
CCM="${CCM:-true}"
# Unicode 不可见字码点绕过修复
UNICODE_BYPASS="${UNICODE_BYPASS:-false}"
# 风驰驱动 1.0
SCHED_HMBIRD="${SCHED_HMBIRD:-false}"
# 轻量级 Linux 容器支持 DroidSpaces
DROID_SPACES="${DROID_SPACES:-false}"
# Re-Kernel
RE_KERNEL="${RE_KERNEL:-false}"
# 拉取 SUSFS-DEV 分支
SUSFS_DEV="${SUSFS_DEV:-false}"
# 停用此次缓存(ccache / thinlto)
BUILD_NOCACHE="${BUILD_NOCACHE:-false}"
# 批量构建范围: Off=单机型(使用 FILE) | All=全部机型 | MTK=仅联发科 | Qualcomm=仅高通
BUILD_ALL="${BUILD_ALL:-Off}"

# 工作根目录(相当于 CI 的 GITHUB_WORKSPACE)。所有源码/产物都放在这里。
WORKROOT="${WORKROOT:-$(pwd)/kernel_build_workspace}"
# 本脚本所在仓库目录(用于在离线时复用本地 patches)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 是否在开始前自动安装 apt 依赖
INSTALL_DEPS="${INSTALL_DEPS:-true}"
# 是否自动创建 swap(内存不足时建议开启)
CREATE_SWAP="${CREATE_SWAP:-false}"
# ccache 最大大小
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
# 交互模式：true 时逐项在命令行里让你选择
INTERACTIVE="${INTERACTIVE:-false}"

###############################################################################
# 二、命令行参数解析(可选，覆盖上方默认值)
###############################################################################
# 不带任何参数运行时，默认进入交互式选择
[ $# -eq 0 ] && INTERACTIVE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interactive)  INTERACTIVE=true; shift ;;
    --file)            FILE="$2"; shift 2 ;;
    --build-all)       BUILD_ALL="$2"; shift 2 ;;
    --manager-source)  MANAGER_SOURCE="$2"; shift 2 ;;
    --susfs-ci)        SUSFS_CI="$2"; shift 2 ;;
    --kpm)             KPM="$2"; shift 2 ;;
    --susfs-meta)      SUSFS_META="$2"; shift 2 ;;
    --dynamic-repo)    DYNAMIC_REPO="$2"; shift 2 ;;
    --build-time)      BUILD_TIME="$2"; shift 2 ;;
    --ksu-meta)        KSU_META="$2"; shift 2 ;;
    --zram)            ZRAM="$2"; shift 2 ;;
    --suffix)          SUFFIX="$2"; shift 2 ;;
    --sublevel)        SUBLEVEL="$2"; shift 2 ;;
    --workroot)        WORKROOT="$2"; shift 2 ;;
    --lz4-update)      LZ4_UPDATE=true; shift ;;
    --no-fast-build)   FAST_BUILD=false; shift ;;
    --no-lsm-bbg)      LSM_BBG=false; shift ;;
    --no-netfilter)    NETFILTER=false; shift ;;
    --no-ccm)          CCM=false; shift ;;
    --unicode-bypass)  UNICODE_BYPASS=true; shift ;;
    --sched-hmbird)    SCHED_HMBIRD=true; shift ;;
    --droid-spaces)    DROID_SPACES=true; shift ;;
    --re-kernel)       RE_KERNEL=true; shift ;;
    --susfs-dev)       SUSFS_DEV=true; shift ;;
    --no-cache)        BUILD_NOCACHE=true; shift ;;
    --no-deps)         INSTALL_DEPS=false; shift ;;
    --swap)            CREATE_SWAP=true; shift ;;
    -h|--help)
      grep -E '^#( |!)' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

###############################################################################
# 三、辅助函数
###############################################################################
log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
group(){ echo -e "\n\033[1;36m==== $* ====\033[0m"; }

# 可选 GitHub Token，用于提高 API 速率上限(匿名仅 60 次/小时，易触发 403)
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# 调用 GitHub API：自动带上 token(若有)，不使用 -f，避免 HTTP 错误在 pipefail 下中断脚本
gh_api() {
  local url="$1"
  if [ -n "$GITHUB_TOKEN" ]; then
    curl -sSL -H "Authorization: Bearer $GITHUB_TOKEN" "$url" 2>/dev/null || true
  else
    curl -sSL "$url" 2>/dev/null || true
  fi
}

# ccache 环境(对应工作流 env)
export CCACHE_COMPILERCHECK="none"
export CCACHE_NOHASHDIR="true"
export CCACHE_NOHARDLINK="true"
export CCACHE_IS_KERNEL_COMPILING="true"
export CCACHE_MAXSIZE

# 清单回退目录与 .rej 检查器在所有机型间共享
MANIFEST_FALLBACK="$WORKROOT/.repo/manifests_fallback"
REJ_CHECKER="$WORKROOT/check_rejects.sh"
# 以下路径与具体机型相关，由 setup_paths_for_file() 在构建每个机型前设置
KERNEL_WORKSPACE="$WORKROOT/kernel_workspace"
ACTION_BUILD_DIR="$KERNEL_WORKSPACE/Action-Build"

# 为当前 FILE 设置工作目录：批量构建时每个机型独立目录，避免 repo 同步冲突
setup_paths_for_file() {
  if [ "$BUILD_ALL" != "Off" ]; then
    KERNEL_WORKSPACE="$WORKROOT/builds/$FILE/kernel_workspace"
  else
    KERNEL_WORKSPACE="$WORKROOT/kernel_workspace"
  fi
  ACTION_BUILD_DIR="$KERNEL_WORKSPACE/Action-Build"
  mkdir -p "$KERNEL_WORKSPACE"
}

# .rej 补丁失败检查器
write_reject_checker() {
  cat > "$REJ_CHECKER" << 'EOF'
check_rejects() {
  local SEARCH_DIR="${1:-.}"
  local REJECT_FILES
  REJECT_FILES=$(find "$SEARCH_DIR" -name "*.rej" 2>/dev/null)
  [ -z "$REJECT_FILES" ] && return 0
  while IFS= read -r REJ_FILE; do
    local ORIG_FILE="${REJ_FILE%.rej}"
    ORIG_FILE="${ORIG_FILE#./}"
    echo "❌ 补丁在 ${ORIG_FILE} 出现 hunk FAILED:"
    cat "$REJ_FILE"
  done <<< "$REJECT_FILES"
}
EOF
}

###############################################################################
# 四、构建步骤(对应工作流 jobs.build.steps)
###############################################################################

step_install_deps() {
  [ "$INSTALL_DEPS" != "true" ] && { log "跳过依赖安装(--no-deps)"; return; }
  group "安装构建依赖"
  sudo apt-get update
  # 新版 Ubuntu 中 liblz4-tool 已更名为 lz4，这里优先用 lz4，旧系统回退 liblz4-tool
  local LZ4_PKG="lz4"
  if ! apt-cache show lz4 >/dev/null 2>&1; then LZ4_PKG="liblz4-tool"; fi
  # 官方构建脚本使用 #!/usr/bin/env python，需要 python-is-python3 提供 python 命令
  local PY_PKG=""
  if apt-cache show python-is-python3 >/dev/null 2>&1; then PY_PKG="python-is-python3"; fi
  sudo apt-get install -y --no-install-recommends \
    python3 $PY_PKG git curl libelf-dev build-essential flex bison libssl-dev \
    libncurses-dev "$LZ4_PKG" zlib1g-dev libxml2-utils rsync unzip gawk \
    dos2unix kmod libdw-dev elfutils dwarves ccache jq bc cpio
}

step_create_swap() {
  [ "$CREATE_SWAP" != "true" ] && return
  group "创建并启用 3G Swap"
  sudo swapoff -a || true
  if [ ! -f /swapfile_local ]; then
    sudo fallocate -l 3G /swapfile_local
    sudo chmod 600 /swapfile_local
    sudo mkswap /swapfile_local
  fi
  sudo swapon /swapfile_local || true
  free -h || true
}

step_extract_info() {
  group "解析清单信息 (Extract Manifest Info)"
  if [[ "$FILE" =~ ^(.+)_([a-zA-Z])$ ]]; then
    FILE_CONF="${BASH_REMATCH[1]}"
  else
    FILE_CONF="$FILE"
  fi
  FILE_BASE=$(echo "$FILE_CONF" | sed -E 's/_bak//g; /_aosp/{s/_aosp//g;s/$/(AOSP)/;}; s/_([a-zA-Z0-9])/\U\1/g; s/^oneplus/OnePlus/; s/^realme/RealME/; s/^oppo/OPPO/')
  mkdir -p "$MANIFEST_FALLBACK"
  XML_PATH="$MANIFEST_FALLBACK/${FILE}.xml"
  README_PATH="$MANIFEST_FALLBACK/README.md"
  log "FILE=$FILE, CONF=$FILE_CONF, BASE=$FILE_BASE"

  declare -A REPOS
  REPOS["OnePlusOSS"]="OnePlusOSS|kernel_manifest"
  REPOS["Dynamic"]="${DYNAMIC_REPO}|kernel_manifest"
  REPOS["Appendix"]="Numbersf|Kernel_Manifest_Appendix"

  FOUND_REPO=""; FOUND_REPO_NAME=""; FOUND_BRANCH=""

  check_repo() {
    local ENTRY=$1
    local OWNER=${ENTRY%%|*}
    local REPO_NAME=${ENTRY##*|}
    log "尝试拉取 ${OWNER}/${REPO_NAME} 分支列表..."
    local BRANCHES
    BRANCHES=$(git ls-remote --heads "https://github.com/${OWNER}/${REPO_NAME}.git" | sed 's|.*refs/heads/||')
    [ -z "$BRANCHES" ] && { warn "${OWNER}/${REPO_NAME} 分支列表获取失败"; return 1; }
    local BRANCH XML_URL README_URL
    for BRANCH in $BRANCHES; do
      XML_URL="https://raw.githubusercontent.com/${OWNER}/${REPO_NAME}/${BRANCH}/${FILE}.xml"
      README_URL="https://raw.githubusercontent.com/${OWNER}/${REPO_NAME}/${BRANCH}/README.md"
      if curl -sf --head "$XML_URL" >/dev/null; then
        log "✅ 在 ${OWNER}/${REPO_NAME} 找到 ${FILE}.xml (分支: ${BRANCH})"
        curl -s -o "$XML_PATH" "$XML_URL"
        curl -s -o "$README_PATH" "$README_URL" || true
        FOUND_REPO="$OWNER"; FOUND_REPO_NAME="$REPO_NAME"; FOUND_BRANCH="$BRANCH"
        return 0
      fi
    done
    return 1
  }

  if ! check_repo "${REPOS["OnePlusOSS"]}"; then
    if ! check_repo "${REPOS["Dynamic"]}"; then
      check_repo "${REPOS["Appendix"]}" || true
    fi
  fi
  if [[ -z "$FOUND_REPO" || ! -s "$XML_PATH" ]]; then
    err "无法在任何仓库中找到 ${FILE}.xml"; exit 8
  fi
  MANIFEST_REPO="$FOUND_REPO"
  MANIFEST_REPO_NAME="$FOUND_REPO_NAME"
  MANIFEST_BRANCH="$FOUND_BRANCH"

  local REVISION
  REVISION=$(grep -oP '<project[^>]+revision="\K[^"]+' "$XML_PATH" | head -n1 || true)
  CPU=$(echo "$REVISION" | sed -E 's#^(oneplus|realme|oppo)/([^_]+).*#\2#')
  ANDROID_VERSION=$(echo "$REVISION" | grep -oP '\d{1,2}\.\d{1,2}(\.\d{1,2})?')
  if [[ -n "$CPU" && -n "$ANDROID_VERSION" ]]; then
    log "✅ CPU=$CPU, ANDROID_VERSION=$ANDROID_VERSION"
    ANDROID_SHORT_VERSION="${ANDROID_VERSION%%.*}"
  else
    err "无法从 revision 中提取 CPU 或 ANDROID_VERSION"; exit 1
  fi

  if [[ -s "$README_PATH" ]]; then
    local BUILD_LINE
    BUILD_LINE=$(grep -m1 'oplus_build_kernel.sh' "$README_PATH" || true)
    if [[ -n "$BUILD_LINE" ]]; then
      CPUD=$(echo "$BUILD_LINE" | awk '{print $(NF-1)}')
      BUILD_METHOD=$(echo "$BUILD_LINE" | awk '{print $NF}')
      log "✅ CPUD=$CPUD, BUILD_METHOD=$BUILD_METHOD"
    else
      warn "README.md 中未找到构建命令"; CPUD=""; BUILD_METHOD=""
    fi
  else
    warn "README.md 下载失败或为空"; CPUD=""; BUILD_METHOD=""
  fi
  INFO_VALUE="${FILE_BASE}_Android${ANDROID_VERSION}"
}

step_mtk_compat() {
  group "MTK 兼容性处理"
  if [[ "$CPU" == mt* ]]; then
    log "✅ 检测到 MTK(联发科) 机型: CPU=$CPU"
    IS_MTK=true
    if [ "$NETFILTER" = "true" ]; then
      warn "MTK 机型不支持 NETFILTER，已自动关闭"; NETFILTER=false
    fi
    if [ "$FAST_BUILD" = "false" ]; then
      warn "MTK 机型不支持关闭极速构建，已自动开启"; FAST_BUILD=true
    fi
  else
    log "非 MTK 机型: CPU=$CPU"; IS_MTK=false
  fi
  log "最终生效: NETFILTER=$NETFILTER, FAST_BUILD=$FAST_BUILD"
}

step_configure_git_clone_actionbuild() {
  group "配置 Git 并克隆 Action-Build"
  git config --global user.name "Numbersf" || true
  git config --global user.email "263623064@qq.com" || true
  mkdir -p "$KERNEL_WORKSPACE"
  if [ ! -d "$ACTION_BUILD_DIR/.git" ]; then
    git clone https://github.com/Numbersf/Action-Build.git -b SukiSU-Ultra "$ACTION_BUILD_DIR"
  else
    log "Action-Build 已存在，跳过克隆"
  fi
}

step_install_ccache_ecs() {
  group "安装 Ccache-ECS"
  local LIB_DIR="$ACTION_BUILD_DIR/lib"
  if [ -f "$LIB_DIR/ccache" ]; then
    sudo cp -f "$LIB_DIR/ccache" /usr/bin/ccache && sudo chmod +x /usr/bin/ccache
    log "已安装 ccache-ECS"
  else
    warn "未找到 $LIB_DIR/ccache，使用系统 ccache"
  fi
}

step_init_ccache() {
  [ "$BUILD_NOCACHE" = "true" ] && { log "已停用缓存(--no-cache)"; return; }
  group "初始化 Ccache"
  CCACHE_DIR="$HOME/.ccache_${FILE}"
  export CCACHE_DIR
  mkdir -p "$CCACHE_DIR"
  if command -v ccache >/dev/null 2>&1; then
    ccache -M "$CCACHE_MAXSIZE"
    ccache -s || true
  else
    warn "未安装 ccache"
  fi
}

step_install_repo_tool() {
  group "安装 repo 工具"
  if ! command -v repo >/dev/null 2>&1; then
    curl https://storage.googleapis.com/git-repo-downloads/repo > "$HOME/repo"
    chmod a+x "$HOME/repo"
    sudo mv "$HOME/repo" /usr/local/bin/repo
  else
    log "repo 已安装"
  fi
}

step_repo_sync() {
  group "初始化 Repo 并同步源码"
  cd "$KERNEL_WORKSPACE"
  mkdir -p .repo/manifests
  cp "$MANIFEST_FALLBACK/${FILE}.xml" ".repo/manifests/${FILE}.xml"
  local BASE_URL="https://github.com/${MANIFEST_REPO}/${MANIFEST_REPO_NAME}.git"
  log "使用 $MANIFEST_REPO/$MANIFEST_REPO_NAME($MANIFEST_BRANCH) 初始化仓库..."
  repo init -u "$BASE_URL" -b "$MANIFEST_BRANCH" -m "${FILE}.xml" --depth=1 --no-clone-bundle --no-tags

  local EXCLUDE_PATTERNS=("prebuilts/asuite" "tools/tradefederation/prebuilts")
  shopt -s nullglob globstar
  local mf p attr
  for mf in .repo/manifests/**/*.xml; do
    for p in "${EXCLUDE_PATTERNS[@]}"; do
      for attr in path name; do
        perl -0777 -i -pe "s{<project\\b[^>]*\\b$attr=\"[^\"]*\\Q$p\\E\"[^>]*/>\\s*}{}g" "$mf"
        perl -0777 -i -pe "s{<project\\b[^>]*\\b$attr=\"[^\"]*\\Q$p\\E\"[^>]*>.*?</project>\\s*}{}gs" "$mf"
      done
    done
  done
  shopt -u globstar
  log "已从清单移除可选项目: ${EXCLUDE_PATTERNS[*]}"

  repo sync -c -j"$(nproc)" --no-clone-bundle --no-tags --force-sync

  KERNEL_REPOS=""
  local KERNEL_REPOS_PATH
  KERNEL_REPOS_PATH=$(find . -type f -name "build.config.msm.common" | head -n 1)
  if [[ -n "$KERNEL_REPOS_PATH" ]]; then
    KERNEL_REPOS=$(echo "${KERNEL_REPOS_PATH#./}" | cut -d/ -f2)
    log "✅ KERNEL_REPOS=$KERNEL_REPOS"
  else
    warn "未找到 build.config.msm.common (天玑清单或纯 Kleaf 结构)"
  fi

  local dir
  for dir in kernel_platform/common "kernel_platform/$KERNEL_REPOS"; do
    if [ -e "$dir/BUILD.bazel" ]; then
      sed -i '/^[[:space:]]*"protected_exports_list"[[:space:]]*:[[:space:]]*"android\/abi_gki_protected_exports_aarch64",$/d' "$dir/BUILD.bazel"
    fi
    rm -f "$dir/android/abi_gki_protected_exports_"* 2>/dev/null || true
  done

  if grep -q 'check_defconfig' kernel_platform/common/build.config.gki 2>/dev/null; then
    sed -i 's/check_defconfig//' kernel_platform/common/build.config.gki
  fi
  if grep -q 'check_defconfig = None,' kernel_platform/build/kernel/kleaf/common_kernels.bzl 2>/dev/null; then
    sed -i 's/check_defconfig = None,/check_defconfig = "disabled",/' kernel_platform/build/kernel/kleaf/common_kernels.bzl
    sed -i 's/if check_defconfig == None:/if False:  # check_defconfig == None:/' kernel_platform/build/kernel/kleaf/common_kernels.bzl
  fi
}

step_kernel_version() {
  group "内核版本处理"
  cd "$KERNEL_WORKSPACE/kernel_platform"
  KMI=""
  local f
  for f in ./common/build.config.constants ./common/build.config.common; do
    if [ -f "$f" ]; then
      KMI=$(grep -m1 '^BRANCH=' "$f" | cut -d= -f2)
      [ -n "$KMI" ] && break
    fi
  done
  if [[ -z "$KMI" && -n "$KERNEL_REPOS" ]]; then
    KMI=$(grep -m1 '^android' "./$KERNEL_REPOS/android/ACK_SHA" | cut -d- -f1,2)
  fi
  if [ -n "$KMI" ]; then
    KANDROID_VERSION="${KMI%-*}"
    KERNEL_VERSION="${KMI#*-}"
  else
    warn "未找到 KMI"
  fi

  local ORIG_VERSION NEW_VERSION
  ORIG_VERSION=$(awk '/^VERSION =/ {v=$3} /^PATCHLEVEL =/ {p=$3} /^SUBLEVEL =/ {s=$3} END {print v"."p"."s}' ./common/Makefile)
  if [ -n "$SUBLEVEL" ]; then
    log "修改 SUBLEVEL 为 $SUBLEVEL"
    sed -i "s/^\(SUBLEVEL[[:space:]]*=[[:space:]]*\).*/\1$SUBLEVEL/" ./common/Makefile
  fi
  NEW_VERSION=$(awk '/^VERSION =/ {v=$3} /^PATCHLEVEL =/ {p=$3} /^SUBLEVEL =/ {s=$3} END {print v"."p"."s}' ./common/Makefile)
  TKERNEL_VERSION="$NEW_VERSION"
  log "Kernel Version: $ORIG_VERSION -> $NEW_VERSION"

  KV1=$(echo "${KMI#*-}" | cut -d. -f1)
  KV2=$(echo "${KMI#*-}" | tr -d '.')
  KV3=$(echo "${NEW_VERSION}" | tr -d '.')
  KERNEL_SHORT_PATCH_VERSION=$(echo "$NEW_VERSION" | cut -d. -f1,2 | tr '.' '_')
}

step_rust_version() {
  group "Rust 版本处理"
  cd "$KERNEL_WORKSPACE/kernel_platform"
  RUSTC_VERSION=""
  if [[ -f ./common/build.config.constants ]]; then
    RUSTC_VERSION=$(grep '^RUSTC_VERSION=' ./common/build.config.constants | cut -d'=' -f2 || true)
  fi
  if [[ -n "$RUSTC_VERSION" ]]; then
    log "✅ RUSTC_VERSION=$RUSTC_VERSION"; ENABLE_RUST=true
  else
    log "RUSTC_VERSION 未找到，Rust 编译已禁用"; ENABLE_RUST=false
  fi
}

step_fix_btf_pahole() {
  group "修复 BTF pahole-flags"
  cd "$KERNEL_WORKSPACE/kernel_platform"
  local f
  for f in ./common/scripts/pahole-flags.sh "./$KERNEL_REPOS/scripts/pahole-flags.sh"; do
    [ -f "$f" ] || continue
    if grep -q 'skip_encoding_btf_enum64' "$f"; then continue; fi
    if grep -q 'echo ${extra_paholeopt}' "$f"; then
      perl -0777 -i -pe 's/(echo \$\{extra_paholeopt\})/if [ "\$\{pahole_ver\}" -ge "124" ]; then\n\textra_paholeopt="\$\{extra_paholeopt\} --skip_encoding_btf_enum64"\nfi\n\n$1/' "$f"
      log "已修补 $f"
    fi
  done
}

# setlocalversion 后缀处理 (自定义或随机)
step_kernel_suffix() {
  group "内核后缀处理"
  cd "$KERNEL_WORKSPACE/kernel_platform"
  local USE_SUFFIX="" RANDOM_DIGIT RANDOM_HASH
  if [[ -n "$SUFFIX" && "$SUFFIX" != "-1" ]]; then
    USE_SUFFIX="$SUFFIX"
    log "使用自定义后缀: $USE_SUFFIX"
  elif [[ "$SUFFIX" == "-1" ]]; then
    log "已关闭后缀修改 (-1)"; return
  else
    RANDOM_DIGIT=$(od -An -N1 -tu1 < /dev/urandom | tr -d '[:space:]' | awk '{print $1 % 11}')
    RANDOM_HASH=$(od -An -N7 -tx1 /dev/urandom | tr -d ' \n')
    USE_SUFFIX="${RANDOM_DIGIT}-o-g${RANDOM_HASH}"
    log "使用随机伪官方后缀: $USE_SUFFIX"
  fi

  local f
  for f in ./common/scripts/setlocalversion "./$KERNEL_REPOS/scripts/setlocalversion" ./external/dtc/scripts/setlocalversion; do
    [ -f "$f" ] || continue
    sed -i 's/ -dirty//g' "$f"
    sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
    if grep -q 'KERNELVERSION.*scm_version' "$f"; then
      sed -i "s|echo \"\${KERNELVERSION}.*scm_version}\"|echo \"\${KERNELVERSION}-${KANDROID_VERSION}-${USE_SUFFIX}\"|" "$f"
    elif grep -q 'echo "\$res"' "$f"; then
      if [ "$FAST_BUILD" = "true" ]; then
        sed -i "s/^res=.*/res=\"-${KANDROID_VERSION}-${USE_SUFFIX}\"/" "$f"
      else
        tac "$f" | sed "0,/echo \"\\\$res\"/s//res=\\\$(echo \\\$res | cut -d- -f1-2)-${USE_SUFFIX}; echo \"\\\$res\";/" | tac > "$f.tmp" && mv "$f.tmp" "$f"
      fi
    else
      echo "echo \"\$res-${USE_SUFFIX}\"" >> "$f"
    fi
    chmod +x "$f"
  done
}

step_resolve_manager() {
  case "$MANAGER_SOURCE" in
    MD3)         MANAGER_BRANCH="old";  MANAGER_ARTIFACT="manager" ;;
    MD3_SPOOF)   MANAGER_BRANCH="old";  MANAGER_ARTIFACT="Spoofed-Manager" ;;
    MIUIX_SPOOF) MANAGER_BRANCH="main"; MANAGER_ARTIFACT="Spoofed-Manager" ;;
    MIUIX|*)     MANAGER_BRANCH="main"; MANAGER_ARTIFACT="manager" ;;
  esac
  log "管理器分支: $MANAGER_BRANCH, 产物: $MANAGER_ARTIFACT"
}

# 本地重复构建时，KernelSU 旧符号链接可能与 drivers/kernelsu 形成回环，导致 Bazel 报错
fix_kernelsu_symlinks() {
  local KP="$KERNEL_WORKSPACE/kernel_platform"
  local KSU_DIR="$KP/KernelSU"
  local KSU_KERNEL="$KSU_DIR/kernel"
  local DRIVER_KSU="$KP/common/drivers/kernelsu"

  [ -L "$DRIVER_KSU" ] && rm -f "$DRIVER_KSU" && warn "已移除旧的 common/drivers/kernelsu 符号链接"

  [ ! -e "$KSU_DIR" ] && return 0

  if [ ! -d "$KSU_DIR/.git" ]; then
    warn "KernelSU 目录异常(非 git 仓库)，将删除后重新集成"
    rm -rf "$KSU_DIR"
    return 0
  fi

  # 移除 kernel/kernel 回环 symlink (Bazel: infinite symlink expansion)
  if [ -L "$KSU_KERNEL/kernel" ]; then
    rm -f "$KSU_KERNEL/kernel"
    warn "已移除 KernelSU/kernel/kernel 回环符号链接"
  fi

  # KernelSU/kernel 必须是 git 中的真实目录，不能是 symlink
  if [ -L "$KSU_KERNEL" ]; then
    warn "KernelSU/kernel 为符号链接(会导致 Bazel 回环)，正在从 git 恢复..."
    rm -f "$KSU_KERNEL"
    if ! git -C "$KSU_DIR" checkout HEAD -- kernel 2>/dev/null && \
       ! git -C "$KSU_DIR" restore --source=HEAD --staged --worktree kernel 2>/dev/null; then
      warn "无法恢复 KernelSU/kernel，将删除 KernelSU 目录后重新 clone"
      rm -rf "$KSU_DIR"
    fi
  fi
}

verify_kernelsu_layout() {
  local KSU_KERNEL="$KERNEL_WORKSPACE/kernel_platform/KernelSU/kernel"
  if [ -L "$KSU_KERNEL" ]; then
    err "KernelSU/kernel 仍为符号链接，Bazel 构建会失败。请删除 kernel_workspace 后重试"; exit 15
  fi
  if [ ! -f "$KSU_KERNEL/Makefile" ]; then
    err "KernelSU/kernel/Makefile 缺失，KernelSU 集成不完整"; exit 15
  fi
  if [ -L "$KSU_KERNEL/kernel" ]; then
    rm -f "$KSU_KERNEL/kernel"
    warn "setup 后仍检测到 kernel/kernel 回环链接，已移除"
  fi
}

step_add_sukisu() {
  group "添加 SukiSU Ultra"
  cd "$KERNEL_WORKSPACE/kernel_platform"
  if [[ "$(grep -o '/' <<< "$KSU_META" | wc -l)" -lt 2 ]]; then
    err "KSU_META 缺少必要分隔符 '/'，格式: 分支名/自定义标识/提交hash"; exit 10
  fi
  local BRANCH_NAME CUSTOM_TAG MANUAL_HASH
  IFS='/' read -r BRANCH_NAME CUSTOM_TAG MANUAL_HASH <<< "$KSU_META"
  log "分支名: $BRANCH_NAME | 标识: ${CUSTOM_TAG:-无} | hash: ${MANUAL_HASH:-无}"

  fix_kernelsu_symlinks
  curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/${MANAGER_BRANCH}/kernel/setup.sh" | bash -s "$BRANCH_NAME"
  verify_kernelsu_layout
  cd ./KernelSU

  local SHORT_HASH=""
  if [[ -n "$MANUAL_HASH" ]]; then
    git fetch origin "$BRANCH_NAME" --depth=50
    git checkout "$MANUAL_HASH"
    SHORT_HASH=${MANUAL_HASH:0:8}
  fi

  KSU_VERSION_TAG=$(gh_api "https://api.github.com/repos/SukiSU-Ultra/SukiSU-Ultra/releases/latest" \
    | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' | head -n1 || true)
  if [[ -z "$KSU_VERSION_TAG" || "$(printf '%s\n' "$KSU_VERSION_TAG" "3.1.7" | sort -V | head -n1)" != "3.1.7" ]]; then
    [ -z "$KSU_VERSION_TAG" ] && warn "获取 SukiSU 最新版本失败(可能是 GitHub API 限流/403)，回退使用 3.1.7"
    KSU_VERSION_TAG="3.1.7"
  fi
  log "KSU_VERSION_TAG=$KSU_VERSION_TAG"

  local GIT_HASH USE_HASH VERSION_FULL
  GIT_HASH=$(git rev-parse --short HEAD)
  if [[ -n "$MANUAL_HASH" ]]; then USE_HASH="$SHORT_HASH"; else USE_HASH="$GIT_HASH"; fi
  if [[ -z "$CUSTOM_TAG" ]]; then
    VERSION_FULL="v$KSU_VERSION_TAG-$USE_HASH@$BRANCH_NAME"
  else
    VERSION_FULL="v$KSU_VERSION_TAG-$CUSTOM_TAG@$BRANCH_NAME[$USE_HASH]"
  fi

  local ESC_VERSION_FULL ESC_KSU_VERSION_TAG
  ESC_VERSION_FULL=$(printf '%s' "$VERSION_FULL" | sed 's/[&|\\/]/\\&/g')
  ESC_KSU_VERSION_TAG=$(printf '%s' "$KSU_VERSION_TAG" | sed 's/[&|\\/]/\\&/g')

  if grep -q '^KSU_VERSION_FULL := ' kernel/Makefile; then
    sed -i "s|^KSU_VERSION_FULL := .*|KSU_VERSION_FULL := $ESC_VERSION_FULL|" kernel/Makefile
  else
    awk -v full="$VERSION_FULL" '
      /^REPO_OWNER :=/ && !done { print; print ""; print "KSU_VERSION_FULL := " full; done=1; next }
      { print }' kernel/Makefile > kernel/Makefile.tmp && mv kernel/Makefile.tmp kernel/Makefile
  fi
  if grep -q '^KSU_VERSION_API := ' kernel/Makefile; then
    sed -i "s|^KSU_VERSION_API := .*|KSU_VERSION_API := $ESC_KSU_VERSION_TAG|" kernel/Makefile
  fi

  KSUVER=$(expr "$(git rev-list --count "$MANAGER_BRANCH" 2>/dev/null || echo 13000)" + 37185)
  log "KSUVER=$KSUVER"
}

step_apply_patches_susfs() {
  group "应用 SukiSU/SUSFS 补丁"
  cd "$KERNEL_WORKSPACE"
  if [ "$SUSFS_META" != "-1" ]; then
    git clone https://gitlab.com/simonpunk/susfs4ksu.git \
      -b "gki-${KANDROID_VERSION}-${KERNEL_VERSION}$([ "$SUSFS_DEV" = "true" ] && echo "-dev" || echo "")"
    if [ -n "$SUSFS_META" ]; then
      cd susfs4ksu
      if [[ "$SUSFS_META" =~ ^[0-9]+$ ]]; then git checkout "HEAD~$SUSFS_META"; else git checkout "$SUSFS_META"; fi
      cd ..
    fi
  fi
  [ "$RE_KERNEL" = "true" ] && git clone https://github.com/Sakion-Team/Re-Kernel.git
  [ "$LZ4_UPDATE" = "true" ] && git clone https://github.com/Numbersf/lz4_oplus.git
  git clone https://github.com/ShirkNeko/SukiSU_patch.git

  cd kernel_platform
  if [ "$SUSFS_META" != "-1" ]; then
    log "拉取 susfs 补丁"
    cp "../susfs4ksu/kernel_patches/50_add_susfs_in_gki-${KANDROID_VERSION}-${KERNEL_VERSION}.patch" ./common/
    cp ../susfs4ksu/kernel_patches/fs/* ./common/fs/
    cp ../susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
  fi
  if [[ "$ZRAM" == 1* ]]; then
    log "拉取 zram 补丁"
    cp -r ../SukiSU_patch/other/zram/lz4k/include/linux/* ./common/include/linux/
    cp -r ../SukiSU_patch/other/zram/lz4k/lib/* ./common/lib/
    cp -r ../SukiSU_patch/other/zram/lz4k/crypto/* ./common/crypto/
    cp -r ../SukiSU_patch/other/zram/lz4k_oplus ./common/lib/
  fi

  cd ./common
  local SUBLEVEL_CUR
  SUBLEVEL_CUR=$(grep '^SUBLEVEL *=' Makefile | head -n1 | cut -d= -f2 | tr -d ' ')

  if [ "$KMI" == "android13-5.15" ] && [ "$SUBLEVEL_CUR" -lt 123 ]; then
    log "修复 5.15.0~5.15.123 旧版 C 库 bug"
    cp "$ACTION_BUILD_DIR/patches/fix_5.15.legacy" ./fix_5.15.legacy.patch
    patch -p1 < fix_5.15.legacy.patch
  fi

  if [[ "$KV2" == "66" && "$KV3" -le 6630 && "$SUSFS_META" != "-1" ]]; then
    local TRUSTY_EXISTS="false"
    grep -q 'common-modules/trusty' "$MANIFEST_FALLBACK/${FILE}.xml" && TRUSTY_EXISTS="true"
    if [[ "$TRUSTY_EXISTS" == "false" ]]; then
      log "修复 6.6.0~6.6.30 缺失 TrustyOS 的 susfs 报错"
      sed -i 's/-32,12 +32,38/-32,11 +32,37/g' "50_add_susfs_in_gki-${KANDROID_VERSION}-${KERNEL_VERSION}.patch"
      sed -i '/#include <trace\/hooks\/fs.h>/d' "50_add_susfs_in_gki-${KANDROID_VERSION}-${KERNEL_VERSION}.patch"
    fi
  fi

  if [ "$SUSFS_META" != "-1" ]; then
    local fake_patched=0 fake_patched_dist=0 fake_patched_swap=0 fake_patched_ns=0 fake_patched_expand=0
    if [ "$KMI" = "android15-6.6" ]; then
      if ! grep -qxF $'\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' ./fs/proc/task_mmu.c; then
        sed -i -e '/int ret = 0, copied = 0;/a \\tunsigned int nr_subpages \= __PAGE_SIZE \/ PAGE_SIZE;' -e '/int ret = 0, copied = 0;/a \\tpagemap_entry_t \*res = NULL;' ./fs/proc/task_mmu.c
        fake_patched=1
      fi
      grep -qxF '#include <linux/dma-buf.h>' ./fs/proc/base.c || sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux\/dma-buf.h>' ./fs/proc/base.c
      if ! grep -qxF '#include <linux/zswap.h>' ./mm/memory.c; then
        sed -i '/#include <linux\/sched\/sysctl\.h>/a #include <linux\/zswap.h>' ./mm/memory.c; fake_patched_swap=1
      fi
      if ! grep -qxF '#include <trace/hooks/fs.h>' ./fs/namespace.c && ! grep -qxF 'susfs_def.h' ./fs/namespace.c; then
        sed -i '/#include <trace\/hooks\/blk\.h>/a #include <trace\/hooks\/fs.h>' ./fs/namespace.c; fake_patched_ns=1
      fi
      if grep -qF 'if (vma->vm_end > last_vma_end)' ./fs/proc/task_mmu.c && ! grep -qF 'if (vma->vm_end > last_vma_end) {' ./fs/proc/task_mmu.c; then
        perl -i -0pe 's/\t\t\tif \(vma->vm_end > last_vma_end\)\n\t\t\t\tsmap_gather_stats\(vma, &mss, last_vma_end\);/\t\t\tif (vma->vm_end > last_vma_end) {\n\t\t\t\tsmap_gather_stats(vma, \&mss, last_vma_end);\n\t\t\t\tlast_vma_end = vma->vm_end;\n\t\t\t}/' ./fs/proc/task_mmu.c
        fake_patched_expand=1
      fi
    fi
    if [ "$KMI" = "android14-6.1" ]; then
      grep -qxF $'\tif (!vma_pages(vma))' ./fs/proc/task_mmu.c || fake_patched=1
      grep -qxF '#include <linux/dma-buf.h>' ./fs/proc/base.c || sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux\/dma-buf.h>' ./fs/proc/base.c
    fi
    if [ "$KMI" = "android12-5.10" ] || [ "$KMI" = "android13-5.15" ]; then
      grep -qxF $'\tif (!vma_pages(vma))' ./fs/proc/task_mmu.c || fake_patched=1
    fi
    if [ "$KMI" = "android13-5.15" ]; then
      if grep -qxF '#include <linux/swap_slots.h>' ./mm/memory.c && ! grep -qxF '#include <linux/susfs_def.h>' ./mm/memory.c; then
        sed -i '/#include <linux\/swap_slots\.h>/d' ./mm/memory.c; fake_patched_dist=1
      fi
    fi

    log "打 susfs 补丁"
    patch -p1 < "50_add_susfs_in_gki-${KANDROID_VERSION}-${KERNEL_VERSION}.patch" || true

    if [ "$fake_patched" = 1 ]; then
      if [ "$KMI" = "android15-6.6" ]; then
        grep -qxF $'\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' ./fs/proc/task_mmu.c && \
          sed -i -e '/unsigned int nr_subpages \= __PAGE_SIZE \/ PAGE_SIZE;/d' -e '/pagemap_entry_t \*res = NULL;/d' ./fs/proc/task_mmu.c
      fi
      if [ "$KMI" = "android12-5.10" ] || [ "$KMI" = "android13-5.15" ] || [ "$KMI" = "android14-6.1" ]; then
        grep -q 'goto[[:space:]]\+show_pad;' ./fs/proc/task_mmu.c && sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
      fi
    fi
    if [ "$fake_patched_dist" = 1 ] && [ "$KMI" = "android13-5.15" ]; then
      grep -qxF '#include <linux/swap_slots.h>' ./mm/memory.c || sed -i '/#ifdef CONFIG_KSU_SUSFS_SUS_MAP/i #include <linux/swap_slots.h>' ./mm/memory.c
    fi
    if [ "$fake_patched_swap" = 1 ] && [ "$KMI" = "android15-6.6" ]; then
      grep -qxF '#include <linux/zswap.h>' ./mm/memory.c && sed -i '/#include <linux\/zswap\.h>/d' ./mm/memory.c
    fi
    if [ "$fake_patched_ns" = 1 ]; then
      if grep -qxF '#include <trace/hooks/fs.h>' ./fs/namespace.c && ! grep -qxF 'susfs_def.h' ./fs/namespace.c; then
        sed -i '/#include <trace\/hooks\/fs\.h>/d' ./fs/namespace.c
      fi
    fi
    if [ "$fake_patched_expand" = 1 ] && [ "$KMI" = "android15-6.6" ]; then
      grep -qF 'if (vma->vm_end > last_vma_end) {' ./fs/proc/task_mmu.c && \
        perl -i -0pe 's/\t\t\tif \(vma->vm_end > last_vma_end\) \{\n\t\t\t\tsmap_gather_stats\(vma, &mss, last_vma_end\);\n\t\t\t\tlast_vma_end = vma->vm_end;\n\t\t\t\}/\t\t\tif (vma->vm_end > last_vma_end)\n\t\t\t\tsmap_gather_stats(vma, \&mss, last_vma_end);/' ./fs/proc/task_mmu.c
    fi
  fi

  source "$REJ_CHECKER"; check_rejects .
}

step_apply_hmbird_convert() {
  [[ "$KV1" -ge 6 && "$KV2" -ge 66 && "$SCHED_HMBIRD" = "false" ]] || return
  group "OGKI 转换 GKI (HMBIRD)"
  local PATCH_DIR="$ACTION_BUILD_DIR/patches"
  cd "$KERNEL_WORKSPACE/kernel_platform/common"
  local p
  for p in ./kernel/sched/hmbird* ./vendor/oplus/kernel/cpu/sched_ext/hmbird*; do
    [ -d "$p" ] && { log "源码已含风驰代码，跳过"; return; }
  done
  sed -i '1iobj-y += hmbird_patch.o' drivers/Makefile
  patch -p1 -F 3 < "${PATCH_DIR}/hmbird_patch.patch" || true
  source "$REJ_CHECKER"; check_rejects .
}

step_apply_unicode_bypass() {
  [ "$UNICODE_BYPASS" = "true" ] || return
  group "应用 UNICODE_BYPASS"
  local PATCH_DIR="$ACTION_BUILD_DIR/patches"
  cd "$KERNEL_WORKSPACE/kernel_platform/common"
  if [ "$KV1" -lt 6 ]; then
    patch -p1 --forward < "${PATCH_DIR}/unicode_bypass_fix_6.1-.patch" || true
  else
    patch -p1 --forward < "${PATCH_DIR}/unicode_bypass_fix_6.1+.patch" || true
  fi
  source "$REJ_CHECKER"; check_rejects .
}

step_apply_re_kernel() {
  [ "$RE_KERNEL" = "true" ] || return
  group "应用 RE_KERNEL"
  local RE_DIR="$KERNEL_WORKSPACE/Re-Kernel/LKM-Source"
  cd "$KERNEL_WORKSPACE/kernel_platform/common"
  sed -i '/endmenu/i source "drivers/rekernel/Kconfig"' drivers/Kconfig
  sed -i '$a \#Re-Kernel Support\nobj-$(CONFIG_REKERNEL) += rekernel/' drivers/Makefile
  mkdir -p drivers/rekernel
  cp "$RE_DIR/rekernel.c" "$RE_DIR/rekernel.h" "$RE_DIR/Makefile" "$RE_DIR/Kconfig" drivers/rekernel/
  sed -i "s|^\s*//\s*#define KERNEL_${KERNEL_SHORT_PATCH_VERSION}|\#define KERNEL_${KERNEL_SHORT_PATCH_VERSION}|" drivers/rekernel/rekernel.h
}

step_apply_droid_spaces() {
  [ "$DROID_SPACES" = "true" ] || return
  group "应用 DROID_SPACES"
  local PATCH_DIR="$ACTION_BUILD_DIR/patches"
  cd "$KERNEL_WORKSPACE/kernel_platform/common"
  sed -i 's/^\(\t\)struct sysv_sem\b.*sysvsem;/\1\/\/ struct sysv_sem\t\t\tsysvsem;/' include/linux/sched.h
  sed -i 's/^\(\t\)struct sysv_shm\b.*sysvshm;/\1\/\/ struct sysv_shm\t\t\tsysvshm;/' include/linux/sched.h

  if [ "$KMI" = "android12-5.10" ]; then
    sed -i '/^\tconst struct sched_class\t\*sched_class;/a \\n#ifndef __GENKSYMS__\n\tstruct sysv_sem\t\t\tsysvsem;\n\tstruct sysv_shm\t\t\tsysvshm;\n#endif\n' include/linux/sched.h
    sed -i 's/^\tunsigned long mq_bytes;\t\/\* How many bytes can be allocated to mqueue[?] \*\//\t\/\/unsigned long mq_bytes;\t\/* How many bytes can be allocated to mqueue? *\//' include/linux/sched/user.h
    sed -i '/struct ratelimit_state ratelimit;/,/ANDROID_OEM_DATA_ARRAY(1, 2);/{/^\tANDROID_KABI_RESERVE(1);/{N;N;s/^\tANDROID_KABI_RESERVE(1);\n\tANDROID_KABI_RESERVE(2);\n\tANDROID_OEM_DATA_ARRAY(1, 2);/#if defined(CONFIG_POSIX_MQUEUE)\n\tANDROID_KABI_USE(1, unsigned long mq_bytes);\n\tANDROID_KABI_RESERVE(2);\n\tANDROID_OEM_DATA_ARRAY(1, 2);\n#else\n\tANDROID_KABI_RESERVE(1);\n\tANDROID_KABI_RESERVE(2);\n\tANDROID_OEM_DATA_ARRAY(1, 2);\n#endif/}}' include/linux/sched/user.h
  elif grep -q "sched_dl_entity.*\*dl_server" include/linux/sched.h; then
    sed -i 's|\tstruct sched_entity\t\tse;|#ifdef CONFIG_SYSVIPC\n\tunion {\n\t\tchar __kabi_ignored_0;\n\t\tstruct sysv_sem\t\t\tsysvsem;\n\t}__attribute__((packed));\n\tunion {\n\t\tchar __kabi_ignored_1;\n\t\tstruct sysv_shm\t\t\tsysvshm;\n\t}__attribute__((packed));\n#endif\n\n\tstruct sched_entity\t\tse;|' include/linux/sched.h
  elif grep -q "ANDROID_KABI_USE(1," include/linux/sched.h; then
    sed -i -e '/ANDROID_KABI_RESERVE(6);/{N;N;s|\tANDROID_KABI_RESERVE(6);\n\tANDROID_KABI_RESERVE(7);\n\tANDROID_KABI_RESERVE(8);|#ifdef CONFIG_SYSVIPC\n\tANDROID_KABI_USE(6, struct sysv_sem sysvsem);\n\t_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(7); ANDROID_KABI_RESERVE(8), struct sysv_shm sysvshm);\n#else\n\tANDROID_KABI_RESERVE(6);\n\tANDROID_KABI_RESERVE(7);\n\tANDROID_KABI_RESERVE(8);\n#endif|;}' include/linux/sched.h
  elif grep -q "ANDROID_KABI_RESERVE(1);" include/linux/sched.h; then
    sed -i -e '/ANDROID_KABI_RESERVE(1);/{N;N;N;N;N;N;N;s|\tANDROID_KABI_RESERVE(1);\n\tANDROID_KABI_RESERVE(2);\n\tANDROID_KABI_RESERVE(3);\n\tANDROID_KABI_RESERVE(4);\n\tANDROID_KABI_RESERVE(5);\n\tANDROID_KABI_RESERVE(6);\n\tANDROID_KABI_RESERVE(7);\n\tANDROID_KABI_RESERVE(8);|#ifdef CONFIG_SYSVIPC\n\tANDROID_KABI_USE(1, struct sysv_sem sysvsem);\n\t_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(2); ANDROID_KABI_RESERVE(3), struct sysv_shm sysvshm);\n#else\n\tANDROID_KABI_RESERVE(1);\n\tANDROID_KABI_RESERVE(2);\n\tANDROID_KABI_RESERVE(3);\n#endif\n\tANDROID_KABI_RESERVE(4);\n\tANDROID_KABI_RESERVE(5);\n\tANDROID_KABI_RESERVE(6);\n\tANDROID_KABI_RESERVE(7);\n\tANDROID_KABI_RESERVE(8);|;}' include/linux/sched.h
  elif grep -q "ANDROID_KABI_RESERVE(3);" include/linux/sched.h; then
    sed -i -e '/ANDROID_KABI_RESERVE(3);/{N;N;N;s|\tANDROID_KABI_RESERVE(3);\n\tANDROID_KABI_RESERVE(4);\n\tANDROID_KABI_RESERVE(5);\n\tANDROID_KABI_RESERVE(6);|#ifdef CONFIG_SYSVIPC\n\tANDROID_KABI_USE(3, struct sysv_sem sysvsem);\n\t_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(4); ANDROID_KABI_RESERVE(5), struct sysv_shm sysvshm);\n#else\n\tANDROID_KABI_RESERVE(3);\n\tANDROID_KABI_RESERVE(4);\n\tANDROID_KABI_RESERVE(5);\n#endif\n\tANDROID_KABI_RESERVE(6);|;}' include/linux/sched.h
  else
    err "无法精准匹配 KABI 槽位或指针"; exit 9
  fi

  patch -p1 --forward < "${PATCH_DIR}/ghost-task-for-midas.patch" || true

  if [ "$KMI" = "android16-6.12" ]; then
    rm -f include/uapi/linux/ntsync.h drivers/misc/ntsync.c
    grep -q 'EXPORT_SYMBOL.*put_ipc_ns' ./ipc/namespace.c || printf '\nEXPORT_SYMBOL_GPL(put_ipc_ns);\n' >> ./ipc/namespace.c
    grep -q 'EXPORT_SYMBOL.*init_ipc_ns' ./ipc/msgutil.c  || printf '\nEXPORT_SYMBOL_GPL(init_ipc_ns);\n' >> ./ipc/msgutil.c
  fi
  patch -p1 --forward < "${PATCH_DIR}/ntsync/ntsync_base.patch" || true
  if [[ "$FILE" == oneplus_10r* ]]; then
    patch -p1 --forward < "${PATCH_DIR}/ntsync/ntsync_compat_android12-5.10_14.patch" || true
  else
    local compat="${KMI}"
    [ -f "${PATCH_DIR}/ntsync/ntsync_compat_${KMI}_${ANDROID_SHORT_VERSION}.patch" ] && compat="${KMI}_${ANDROID_SHORT_VERSION}"
    patch -p1 --forward < "${PATCH_DIR}/ntsync/ntsync_compat_${compat}.patch" || true
  fi
  source "$REJ_CHECKER"; check_rejects .
}

step_apply_lz4_dev() {
  [ "$LZ4_UPDATE" = "true" ] || return
  group "应用 LZ4_DEV"
  local LZ4_REPO="$KERNEL_WORKSPACE/lz4_oplus"
  cd "$KERNEL_WORKSPACE/kernel_platform/common"
  source "${LZ4_REPO}/apply_lz4_oplus.sh"
}

step_apply_zram() {
  [[ "$ZRAM" == 1/* ]] || return
  group "应用 ZRAM"
  if [[ "$(grep -o '/' <<< "$ZRAM" | wc -l)" -lt 2 ]]; then
    err "ZRAM 参数缺少分隔符 '/'，格式: 开关/算法名/大小"; exit 10
  fi
  IFS='/' read -r _ ZRAM_ALGO ZRAM_SIZE <<< "$ZRAM"
  ZRAM_ALGO_U="${ZRAM_ALGO^^}"
  local PATCH_DIR="$KERNEL_WORKSPACE/SukiSU_patch/other/zram/zram_patch/${KERNEL_VERSION}"
  cd "$KERNEL_WORKSPACE/kernel_platform/common"
  if [[ "$KERNEL_VERSION" == "5.10" && "${CPU}" == mt* ]]; then
    sed -i 's/select CRYPTO_LZO/depends on CRYPTO_LZO/' ./mm/oplus_mm/hybridswap_zram/Kconfig
  fi
  patch -p1 -F 3 < "${PATCH_DIR}/lz4kd.patch" || true
  patch -p1 -F 3 < "${PATCH_DIR}/lz4k_oplus.patch" || true
  source "$REJ_CHECKER"; check_rejects .
}

step_apply_sched_hmbird() {
  [ "$SCHED_HMBIRD" = "true" ] || return
  group "应用 SCHED_HMBIRD (风驰)"
  cd "$KERNEL_WORKSPACE/kernel_platform/common"
  local CLEAN_FILE="${FILE//_bak/}" p
  for p in ./kernel/sched/hmbird* ./vendor/oplus/kernel/cpu/sched_ext/hmbird*; do
    [ -d "$p" ] && { log "源码已含风驰代码，跳过"; return; }
  done
  git clone https://github.com/Numbersf/SCHED_PATCH.git -b "$CPU" || { err "CPU 分支不存在，风驰未支持此机型"; exit 11; }
  cp "./SCHED_PATCH/fengchi_${CLEAN_FILE}.patch" ./
  if [[ -f "fengchi_${CLEAN_FILE}.patch" ]]; then
    dos2unix "fengchi_${CLEAN_FILE}.patch"
    patch -p1 -F 3 < "fengchi_${CLEAN_FILE}.patch"
    source "$REJ_CHECKER"; check_rejects .
  else
    err "未匹配到风驰补丁"; exit 12
  fi
}

step_apply_lsm_bbg() {
  [ "$LSM_BBG" = "true" ] || return
  group "应用 LSM_BBG (基带保护)"
  cd "$KERNEL_WORKSPACE/kernel_platform/common"
  curl -LSs https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh | bash
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' ./security/Kconfig
}

step_add_config() {
  group "添加配置项 (defconfig)"
  cd "$KERNEL_WORKSPACE/kernel_platform/common"
  local CONFIG_FILE=./arch/arm64/configs/gki_defconfig

  set_config() {
    local val="$1" key="${1%%=*}"
    if grep -qF "${key}=" "$CONFIG_FILE" || grep -qF "# ${key} is not set" "$CONFIG_FILE"; then
      VAL="$val" awk -v key="$key" '
        $0 == "# " key " is not set" || index($0, key "=") == 1 { print ENVIRON["VAL"]; next }
        { print }' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE" || rm -f "${CONFIG_FILE}.tmp"
    else
      printf '%s\n' "$val" >> "$CONFIG_FILE"
    fi
  }

  set_config "CONFIG_KSU=y"

  if [ "$KPM" = "KPM" ] || [ "$KPM" = "N/A" ]; then set_config "CONFIG_KPM=y"; fi
  if [ "$KPM" = "KPN" ]; then set_config "CONFIG_KPM=n"; fi

  if [ "$SUSFS_META" != "-1" ]; then
    set_config "CONFIG_KSU_SUSFS=y"
    set_config "CONFIG_KSU_SUSFS_SUS_PATH=y"
    set_config "CONFIG_KSU_SUSFS_SUS_MAP=y"
    set_config "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
    set_config "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
    set_config "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
    set_config "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
    set_config "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
    set_config "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
    set_config "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
  else
    set_config "CONFIG_KSU_SUSFS=n"
  fi

  set_config "CONFIG_TMPFS_XATTR=y"
  set_config "CONFIG_TMPFS_POSIX_ACL=y"

  if [ "$CCM" = "true" ]; then
    set_config "CONFIG_TCP_CONG_ADVANCED=y"
    set_config "CONFIG_TCP_CONG_BBR=y"
    set_config "CONFIG_NET_SCH_FQ=y"
    set_config "CONFIG_TCP_CONG_BIC=n"
    set_config "CONFIG_TCP_CONG_WESTWOOD=n"
    set_config "CONFIG_TCP_CONG_HTCP=n"
    set_config "CONFIG_IP_ECN=y"
    set_config "CONFIG_TCP_ECN=y"
    set_config "CONFIG_IPV6_ECN=y"
    set_config "CONFIG_IP_NF_TARGET_ECN=y"
  fi

  if [ "$RE_KERNEL" = "true" ]; then
    set_config "CONFIG_REKERNEL=y"
    set_config "CONFIG_REKERNEL_NETWORK=y"
  fi

  if [[ "$ZRAM" == 1* ]]; then
    set_config "CONFIG_CRYPTO_LZ4HC=y"
    set_config "CONFIG_CRYPTO_LZ4K=y"
    set_config "CONFIG_CRYPTO_LZ4KD=y"
    set_config "CONFIG_CRYPTO_842=y"
    set_config "CONFIG_CRYPTO_LZ4K_OPLUS=y"
    set_config "CONFIG_ZRAM_WRITEBACK=y"
  fi

  if [ "$LSM_BBG" = "true" ]; then set_config "CONFIG_BBG=y"; fi

  if [ "$DROID_SPACES" = "true" ]; then
    set_config "CONFIG_NTSYNC=y"
    set_config "CONFIG_SYSVIPC=y"
    set_config "CONFIG_DEVTMPFS=y"
    set_config "CONFIG_PID_NS=y"
    set_config "CONFIG_IPC_NS=y"
    set_config "CONFIG_NAMESPACES=y"
    set_config "CONFIG_POSIX_MQUEUE=y"
    set_config "CONFIG_NETFILTER_XT_TARGET_REJECT=y"
    set_config "CONFIG_NETFILTER_XT_TARGET_LOG=y"
    set_config "CONFIG_NETFILTER_XT_MATCH_RECENT=y"
  fi

  if [ "$NETFILTER" = "true" ]; then
    if [[ "$KERNEL_VERSION" != "6.12" && "${CPU}" != mt* ]]; then
      set_config "CONFIG_BPF_STREAM_PARSER=y"
    fi
    set_config "CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y"
    set_config "CONFIG_NETFILTER_XT_SET=y"
    set_config "CONFIG_IP_SET=y"
    set_config "CONFIG_IP_SET_MAX=65534"
    set_config "CONFIG_IP_SET_BITMAP_IP=y"
    set_config "CONFIG_IP_SET_BITMAP_IPMAC=y"
    set_config "CONFIG_IP_SET_BITMAP_PORT=y"
    set_config "CONFIG_IP_SET_HASH_IP=y"
    set_config "CONFIG_IP_SET_HASH_IPMARK=y"
    set_config "CONFIG_IP_SET_HASH_IPPORT=y"
    set_config "CONFIG_IP_SET_HASH_IPPORTIP=y"
    set_config "CONFIG_IP_SET_HASH_IPPORTNET=y"
    set_config "CONFIG_IP_SET_HASH_IPMAC=y"
    set_config "CONFIG_IP_SET_HASH_MAC=y"
    set_config "CONFIG_IP_SET_HASH_NETPORTNET=y"
    set_config "CONFIG_IP_SET_HASH_NET=y"
    set_config "CONFIG_IP_SET_HASH_NETNET=y"
    set_config "CONFIG_IP_SET_HASH_NETPORT=y"
    set_config "CONFIG_IP_SET_HASH_NETIFACE=y"
    set_config "CONFIG_IP_SET_LIST_SET=y"
    set_config "CONFIG_IP6_NF_NAT=y"
    set_config "CONFIG_IP6_NF_TARGET_MASQUERADE=y"
  fi

  if [[ "$ENABLE_RUST" == "true" ]]; then
    set_config "CONFIG_RUST=y"
    set_config "CONFIG_ANDROID_BINDER_IPC_RUST=m"
  fi
}

step_fix_ipv6_nat() {
  [ "$NETFILTER" = "true" ] || return
  group "修复 IPv6_NAT"
  local PATCH_DIR="$ACTION_BUILD_DIR/patches"
  cd "$KERNEL_WORKSPACE/kernel_platform/common"
  if [[ "${CPU}" == sm* ]]; then
    patch -p1 -F 3 < "${PATCH_DIR}/IPv6_NAT_FIX.patch"
  else
    log "设备不支持 IPv6 NAT，跳过"
  fi
}

step_custom_build_time() {
  [ "$BUILD_TIME" != "-1" ] || { log "已关闭自定义构建时间"; return; }
  group "自定义构建时间"
  local DATESTR
  if [[ -n "$BUILD_TIME" && "$BUILD_TIME" != "F" ]]; then
    DATESTR="$BUILD_TIME"
  else
    DATESTR="$(TZ='UTC' date +'%a %b %d %T %Z %Y')"
  fi
  export KBUILD_BUILD_TIMESTAMP="$DATESTR"
  export KBUILD_BUILD_VERSION=1
  cd "$KERNEL_WORKSPACE/kernel_platform/"
  local f
  for f in ./common/scripts/mkcompile_h "./$KERNEL_REPOS/scripts/mkcompile_h"; do
    [ -f "$f" ] || continue
    if grep -q 'UTS_VERSION=' "$f"; then
      perl -pi -e "s{UTS_VERSION=\"\\\$\\(.*?\\)\"}{UTS_VERSION=\"#1 SMP PREEMPT $DATESTR\"}" "$f"
    else
      perl -0777 -pi -e "s{cat <<EOF}{cat <<EOF\n#undef UTS_VERSION\n#define UTS_VERSION \"#1 SMP PREEMPT $DATESTR\" } unless /UTS_VERSION/" "$f"
    fi
  done
}

step_disable_gpueb() {
  [[ "$KERNEL_VERSION" == "5.10" && "$CPU" == mt* ]] || return
  group "禁用 GPUEB (MTK 5.10)"
  sed -i '/obj-y.*gpueb/d' "$KERNEL_WORKSPACE/kernel-5.10/drivers/gpu/mediatek/Makefile"
}

step_build_fast() {
  group "极速构建内核 (make)"
  FAST_FALLBACK=false
  cd "$KERNEL_WORKSPACE/kernel_platform"

  local USE_LLVM_IAS
  if [[ -f ./common/build.config.arm ]] && grep -q '^LLVM_IAS=1' ./common/build.config.arm; then
    USE_LLVM_IAS=true; else USE_LLVM_IAS=false; fi

  local CLANG_PREBUILT_NAME KERNEL_BUILD_TOOLS_PREBUILT_NAME RUST_TOOLS_PREBUILT_NAME
  CLANG_PREBUILT_NAME=$(find "$KERNEL_WORKSPACE/kernel_platform" -maxdepth 1 -type d -name 'prebuilts*' -exec test -d '{}/clang/host/linux-x86' \; -print | head -1)
  CLANG_PREBUILT_NAME=$(basename "${CLANG_PREBUILT_NAME:-}")
  KERNEL_BUILD_TOOLS_PREBUILT_NAME=$(find "$KERNEL_WORKSPACE/kernel_platform" -maxdepth 1 -type d -name 'prebuilts*' -exec test -d '{}/kernel-build-tools' \; -print | head -1)
  KERNEL_BUILD_TOOLS_PREBUILT_NAME=$(basename "${KERNEL_BUILD_TOOLS_PREBUILT_NAME:-}")
  if [[ "$ENABLE_RUST" == "true" ]]; then
    RUST_TOOLS_PREBUILT_NAME=$(find "$KERNEL_WORKSPACE/kernel_platform" -maxdepth 1 -type d -name 'prebuilts*' -exec test -d '{}/rust' \; -print | head -1)
    RUST_TOOLS_PREBUILT_NAME=$(basename "${RUST_TOOLS_PREBUILT_NAME:-}")
  fi

  local CLANG_PREBUILT_BIN=""
  if [[ -f ./common/build.config.common ]]; then
    CLANG_PREBUILT_BIN=$(grep '^CLANG_PREBUILT_BIN=' ./common/build.config.common | cut -d'=' -f2-)
  fi
  [[ -z "$CLANG_PREBUILT_BIN" ]] && CLANG_PREBUILT_BIN="${CLANG_PREBUILT_NAME}/clang/host/linux-x86/clang-zakozako/bin"

  local CLANG_VERSION=""
  if [[ "$CLANG_PREBUILT_BIN" =~ clang-(r[0-9a-z]+) ]]; then
    CLANG_VERSION="${BASH_REMATCH[1]}"
  elif [[ -f ./common/build.config.constants ]]; then
    CLANG_VERSION=$(grep '^CLANG_VERSION=' ./common/build.config.constants | cut -d'=' -f2 || true)
  fi
  if [[ -z "$CLANG_VERSION" ]]; then
    warn "未能获取 Clang 版本，回退至官方构建脚本"
    FAST_FALLBACK=true; return
  fi

  CLANG_PREBUILT_BIN="${CLANG_PREBUILT_BIN/\$\{CLANG_VERSION\}/$CLANG_VERSION}"
  CLANG_PREBUILT_BIN="${CLANG_PREBUILT_BIN/clang-zakozako/clang-${CLANG_VERSION}}"
  log "CLANG_PREBUILT_BIN=$CLANG_PREBUILT_BIN  CLANG_VERSION=$CLANG_VERSION  USE_LLVM_IAS=$USE_LLVM_IAS"

  set +u
  source "$KERNEL_WORKSPACE/kernel_platform/build/kernel/_setup_env.sh" 2>/dev/null || true
  set -u

  export PATH="$KERNEL_WORKSPACE/kernel_platform/$CLANG_PREBUILT_BIN:$PATH"
  local CLANG_LIB_PATH="${CLANG_PREBUILT_BIN%/bin}"
  if [[ -d "$KERNEL_WORKSPACE/kernel_platform/$CLANG_LIB_PATH/lib" ]]; then
    export LIBCLANG_PATH="$KERNEL_WORKSPACE/kernel_platform/$CLANG_LIB_PATH/lib"
  elif [[ -d "$KERNEL_WORKSPACE/kernel_platform/clang-${CLANG_VERSION}/lib" ]]; then
    export LIBCLANG_PATH="$KERNEL_WORKSPACE/kernel_platform/clang-${CLANG_VERSION}/lib"
  else
    export LIBCLANG_PATH="$(clang --print-resource-dir 2>/dev/null | sed 's|/lib/clang/.*||')/lib"
    warn "LIBCLANG_PATH fallback to system: $LIBCLANG_PATH"
  fi
  export PATH="/usr/lib/ccache:$PATH"

  local BINDGEN_BIN=""
  if [[ "$ENABLE_RUST" == "true" ]]; then
    BINDGEN_BIN="$KERNEL_WORKSPACE/kernel_platform/$CLANG_PREBUILT_NAME/clang-tools/linux-x86/bin/bindgen"
    if [ -x "$BINDGEN_BIN" ]; then
      export BINDGEN="$BINDGEN_BIN"
    else
      warn "prebuilts bindgen 未找到，cargo 安装 bindgen 0.69.5"
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
      source "$HOME/.cargo/env"
      cargo install bindgen-cli --version 0.69.5
      BINDGEN_BIN=$(which bindgen); export BINDGEN="$BINDGEN_BIN"
    fi
  fi

  local PAHOLE_BIN="$KERNEL_WORKSPACE/kernel_platform/$KERNEL_BUILD_TOOLS_PREBUILT_NAME/kernel-build-tools/linux-x86/bin/pahole"
  if [ ! -x "$PAHOLE_BIN" ]; then
    PAHOLE_BIN="$(find "$KERNEL_WORKSPACE" -type f -path '*/kernel-build-tools/linux-x86/bin/pahole' 2>/dev/null | head -n1)"
  fi
  [ -x "$PAHOLE_BIN" ] || PAHOLE_BIN="$(which pahole 2>/dev/null || true)"
  if [ ! -x "$PAHOLE_BIN" ]; then err "pahole 缺失，终止构建"; exit 13; fi
  log "pahole: $PAHOLE_BIN"

  local RUSTC_BIN=""
  if [[ "$ENABLE_RUST" == "true" ]]; then
    RUSTC_BIN="$KERNEL_WORKSPACE/kernel_platform/$RUST_TOOLS_PREBUILT_NAME/rust/linux-x86/$RUSTC_VERSION/bin/rustc"
    [ -x "$RUSTC_BIN" ] || RUSTC_BIN="$(which rustc 2>/dev/null || true)"
    if [ -x "$RUSTC_BIN" ]; then export RUSTC="$RUSTC_BIN"; else err "rustc 缺失"; exit 13; fi
  fi

  local LD_WRAPPER=""
  if [ "$BUILD_NOCACHE" = "false" ] && [[ "$KERNEL_VERSION" == 5.* ]]; then
    local LDCACHE_DIR="$KERNEL_WORKSPACE/.thinlto-cache" LLD_BIN
    mkdir -p "$LDCACHE_DIR"
    LD_WRAPPER="$KERNEL_WORKSPACE/ld-wrapper"
    LLD_BIN="$(command -v ld.lld || true)"
    [ -z "$LLD_BIN" ] && warn "ld.lld 未找到"
    printf '#!/bin/bash\nexec "%s" "$@" --thinlto-cache-dir="%s" --thinlto-cache-policy=cache_size_bytes=3g --thinlto-jobs=%s\n' "$LLD_BIN" "$LDCACHE_DIR" "$(nproc --all)" > "$LD_WRAPPER"
    chmod +x "$LD_WRAPPER"
  fi

  local REAL_CLANG_BIN="$KERNEL_WORKSPACE/kernel_platform/$CLANG_PREBUILT_BIN/clang"
  local CC_WRAPPER="$KERNEL_WORKSPACE/cc-wrapper"
  printf '#!/bin/bash\nexec ccache "%s" "$@"\n' "$REAL_CLANG_BIN" > "$CC_WRAPPER"
  chmod +x "$CC_WRAPPER"

  cd ./common
  local COMMON_REAL_PATH PLATFORM_REAL_PATH ROOT_REAL_PATH MAP MPMAP FPMAP
  COMMON_REAL_PATH=$(pwd -P)
  PLATFORM_REAL_PATH=$(dirname "$COMMON_REAL_PATH")
  ROOT_REAL_PATH=$(dirname "$PLATFORM_REAL_PATH")
  MAP="-fdebug-prefix-map=$ROOT_REAL_PATH=."
  MPMAP="-fmacro-prefix-map=$ROOT_REAL_PATH=."
  FPMAP="-ffile-prefix-map=$ROOT_REAL_PATH=."
  local KCFLAGS="$MAP $FPMAP -no-canonical-prefixes -O2 -pipe -Wno-error -fno-stack-protector -D__ANDROID_COMMON_KERNEL__"
  local KCPPFLAGS="$MPMAP"

  local MAKE_ARGS=(
    LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
    CC="$CC_WRAPPER" HOSTCC="$CC_WRAPPER" HOSTLD=ld.lld
    PAHOLE="$PAHOLE_BIN" KCFLAGS="$KCFLAGS" KCPPFLAGS="$KCPPFLAGS"
  )
  if [[ -n "$LD_WRAPPER" ]]; then MAKE_ARGS+=(LD="$LD_WRAPPER"); else MAKE_ARGS+=(LD=ld.lld); fi
  [[ "$USE_LLVM_IAS" == "true" ]] && MAKE_ARGS+=(LLVM_IAS=1)
  if [[ "$ENABLE_RUST" == "true" ]]; then MAKE_ARGS+=(RUSTC="$RUSTC_BIN" BINDGEN="$BINDGEN_BIN"); fi

  make O=out "${MAKE_ARGS[@]}" gki_defconfig --no-print-directory
  if [[ "$KERNEL_VERSION" == 5.* ]]; then
    scripts/config --file out/.config -e LTO_CLANG -e LTO_CLANG_THIN -d LTO_CLANG_NONE -d LTO_CLANG_FULL
  fi
  make O=out "${MAKE_ARGS[@]}" olddefconfig --no-print-directory
  make -j"$(nproc --all)" O=out "${MAKE_ARGS[@]}"
  ccache -s || true
}

step_build_official() {
  group "官方脚本/Bazel 构建内核"
  cd "$KERNEL_WORKSPACE"
  # 官方脚本用 #!/usr/bin/env python，若系统只有 python3 则临时补一个 python 软链接
  if ! command -v python >/dev/null 2>&1; then
    if command -v python3 >/dev/null 2>&1; then
      mkdir -p "$WORKROOT/pybin"
      ln -sf "$(command -v python3)" "$WORKROOT/pybin/python"
      export PATH="$WORKROOT/pybin:$PATH"
      warn "系统缺少 python 命令，已临时映射 python -> python3"
    else
      err "未找到 python/python3，无法运行官方构建脚本"; exit 14
    fi
  fi
  if [ -f ./kernel_platform/build_with_bazel.py ]; then
    ./kernel_platform/oplus/bazel/oplus_modules_variant.sh "$CPUD" "$BUILD_METHOD"
    ./kernel_platform/build_with_bazel.py -t "$CPUD" "$BUILD_METHOD"
  else
    LTO=thin SYSTEM_DLKM_RE_SIGN=0 BUILD_SYSTEM_DLKM=0 KMI_SYMBOL_LIST_STRICT_MODE=0 \
      ./kernel_platform/oplus/build/oplus_build_kernel.sh "$CPUD" "$BUILD_METHOD"
  fi
}

step_build() {
  if [ "$FAST_BUILD" = "true" ]; then
    step_build_fast
    if [ "${FAST_FALLBACK:-false}" = "true" ]; then step_build_official; fi
  else
    step_build_official
  fi
}

step_make_anykernel() {
  group "制作 AnyKernel3"
  cd "$WORKROOT"
  [ -d "$WORKROOT/AnyKernel3" ] && rm -rf "$WORKROOT/AnyKernel3"
  git clone https://github.com/tycykp/AnyKernel3 --depth=1 "$WORKROOT/AnyKernel3"
  rm -rf "$WORKROOT/AnyKernel3/.git"
  mkdir -p "$KERNEL_WORKSPACE/kernel_platform/out/Final-Image-Find/"

  local image_path=""
  if [ -d "$KERNEL_WORKSPACE/kernel_platform/common/out/" ]; then
    image_path=$(find "$KERNEL_WORKSPACE/kernel_platform/common/out/" -name "Image" | head -n 1)
  fi
  if [ -z "$image_path" ] && [ -d "$KERNEL_WORKSPACE/kernel_platform/out/" ]; then
    image_path=$(find "$KERNEL_WORKSPACE/kernel_platform/out/" -name "Image" | head -n 1)
  fi
  if [ -z "$image_path" ]; then err "未找到 Image 文件，构建失败"; exit 1; fi
  log "✅ Image 位于: $image_path"
  cp "$image_path" "$WORKROOT/AnyKernel3/Image"
  cp "$image_path" "$KERNEL_WORKSPACE/kernel_platform/out/Final-Image-Find/Image"
}

step_apply_kpm() {
  [ "$KPM" != "N/A" ] || return
  group "应用 KPM/KPN 并替换 Image"
  local KPM_DIR="$KERNEL_WORKSPACE/SukiSU_patch/kpm"
  local KPN_DIR="$ACTION_BUILD_DIR/patches/kpn"
  local OUT_DIR="$KERNEL_WORKSPACE/kernel_platform/out/Final-Image-Find"
  cd "$OUT_DIR"
  if [ "$KPM" = "KPM" ]; then
    cp "${KPM_DIR}/patch_linux" .
    chmod +x patch_linux
    ./patch_linux
  else
    cp "${KPN_DIR}/kptools-linux" "${KPN_DIR}/kpimg-linux" .
    chmod +x ./kptools-linux
    ./kptools-linux -p -i ./Image -k ./kpimg-linux -o ./oImage
  fi
  mv -f oImage Image
  cp Image "$WORKROOT/AnyKernel3/Image"
}

step_download_susfs_module() {
  if [ "$SUSFS_CI" = "CI" ] && [ "$SUSFS_META" != "-1" ]; then
    group "下载 SUSFS 模块 (CI)"
    if [ -z "$GITHUB_TOKEN" ]; then
      warn "下载 CI artifact 需要 GITHUB_TOKEN，未设置则跳过(可改用 SUSFS_CI=Release)"
      return 0
    fi
    local LATEST_RUN_ID ARTIFACT_URL
    LATEST_RUN_ID=$(gh_api "https://api.github.com/repos/sidex15/susfs4ksu-module/actions/runs?status=success" | jq -r '.workflow_runs[] | select(.head_branch == "v1.5.2+") | .id' 2>/dev/null | head -n 1 || true)
    if [ -n "$LATEST_RUN_ID" ] && [ "$LATEST_RUN_ID" != "null" ]; then
      ARTIFACT_URL=$(gh_api "https://api.github.com/repos/sidex15/susfs4ksu-module/actions/runs/$LATEST_RUN_ID/artifacts" | jq -r '.artifacts[0].archive_download_url' 2>/dev/null || true)
      if [ -n "$ARTIFACT_URL" ] && [ "$ARTIFACT_URL" != "null" ]; then
        curl -L -H "Authorization: Bearer $GITHUB_TOKEN" -o "$WORKROOT/AnyKernel3/ksu_module_susfs_1.5.2+_CI.zip" "$ARTIFACT_URL" || warn "CI 模块下载失败"
      else
        warn "未获取到 artifact 下载地址"
      fi
    else
      warn "未找到 v1.5.2+ 成功构建"
    fi
  elif [ "$SUSFS_CI" = "Release" ] && [ "$SUSFS_META" != "-1" ]; then
    group "下载 SUSFS 模块 (Release)"
    wget -O "$WORKROOT/AnyKernel3/ksu_module_susfs_1.5.2+_Release.zip" \
      https://github.com/sidex15/ksu_module_susfs/releases/latest/download/ksu_module_susfs_1.5.2+.zip || warn "下载失败"
  fi
}

step_package() {
  group "打包产物"
  local SUFFIX_TAG=""
  [ -n "${ZRAM_ALGO_U:-}" ] && SUFFIX_TAG="${SUFFIX_TAG}_${ZRAM_ALGO_U}"
  [ "$KPM" = "KPM" ] && SUFFIX_TAG="${SUFFIX_TAG}_KPM"
  [ "$KPM" = "KPN" ] && SUFFIX_TAG="${SUFFIX_TAG}_KPN"
  [ "$LSM_BBG" = "true" ] && SUFFIX_TAG="${SUFFIX_TAG}_BBG"
  SUFFIX_TAG="${SUFFIX_TAG}_ILH"
  [ "$SCHED_HMBIRD" = "true" ] && SUFFIX_TAG="${SUFFIX_TAG}_HMBIRD"
  [ "$DROID_SPACES" = "true" ] && SUFFIX_TAG="${SUFFIX_TAG}_DS"
  [ "$RE_KERNEL" = "true" ] && SUFFIX_TAG="${SUFFIX_TAG}_REKER"
  [ "$LZ4_UPDATE" = "true" ] && SUFFIX_TAG="${SUFFIX_TAG}_LZ4UPD"

  local NAME="AnyKernel3_SukiSUUltra_${KSUVER}_${INFO_VALUE}(${TKERNEL_VERSION})${SUFFIX_TAG}"
  local ZIP_PATH="$WORKROOT/${NAME}.zip"
  ( cd "$WORKROOT/AnyKernel3" && zip -r9 "$ZIP_PATH" ./* )
  log "✅ 已打包: $ZIP_PATH"
  echo
  log "===== 构建完成 ====="
  log "产物目录: $WORKROOT/AnyKernel3"
  log "刷机包:   $ZIP_PATH"
}

###############################################################################
# 四点五、交互式选择(无参数运行或 -i 时启用)
###############################################################################

# 从编号列表中选择(严格)：输入序号→对应项；回车→默认；非法→默认
_choose() {
  local prompt="$1" def="$2"; shift 2
  local opts=("$@") i ans
  echo -e "\033[1;36m$prompt\033[0m" >&2
  for i in "${!opts[@]}"; do
    if [ "${opts[$i]}" = "$def" ]; then
      printf "  \033[1;32m%2d) %s  (默认)\033[0m\n" $((i+1)) "${opts[$i]}" >&2
    else
      printf "  %2d) %s\n" $((i+1)) "${opts[$i]}" >&2
    fi
  done
  read -r -p "请输入序号 [回车=默认]: " ans </dev/tty
  if [[ -z "$ans" ]]; then echo "$def"; return; fi
  if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans>=1 && ans<=${#opts[@]} )); then
    echo "${opts[$((ans-1))]}"
  else
    echo "$def"
  fi
}

# 机型选择：支持输入序号，或直接输入机型名(便于在长列表中快速指定)
_choose_file() {
  local def="$1"; shift
  local opts=("$@") i ans
  echo -e "\033[1;36m选择机型 (FILE)：可输入序号，或直接键入机型名\033[0m" >&2
  for i in "${!opts[@]}"; do
    if [ "${opts[$i]}" = "$def" ]; then
      printf "  \033[1;32m%2d) %s  (默认)\033[0m\n" $((i+1)) "${opts[$i]}" >&2
    else
      printf "  %2d) %s\n" $((i+1)) "${opts[$i]}" >&2
    fi
  done
  read -r -p "请输入序号或机型名 [回车=默认]: " ans </dev/tty
  if [[ -z "$ans" ]]; then echo "$def"; return; fi
  if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans>=1 && ans<=${#opts[@]} )); then
    echo "${opts[$((ans-1))]}"
  else
    echo "$ans"
  fi
}

# 是/否选择
_ask_bool() {
  local prompt="$1" def="$2" ans hint
  if [ "$def" = "true" ]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "$(echo -e "\033[1;36m$prompt\033[0m") ($hint) [回车=默认:$def]: " ans </dev/tty
  case "$ans" in
    y|Y|yes|YES) echo true ;;
    n|N|no|NO)   echo false ;;
    *)           echo "$def" ;;
  esac
}

# 文本输入
_ask_text() {
  local prompt="$1" def="$2" ans
  read -r -p "$(echo -e "\033[1;36m$prompt\033[0m") [回车=默认:${def:-(空)}]: " ans </dev/tty
  echo "${ans:-$def}"
}

interactive_config() {
  group "交互式参数选择 (回车均使用默认值)"

  local FILE_OPTIONS=(
    oneplus_nord_n30_se_5g_v oneplus_10r_v oneplus_nord_3_v oneplus_ace_v oneplus_ace_race_v
    oneplus_10_pro_b oneplus_10t_v oneplus_11r_b oneplus_ace2_b oneplus_pad_lite_b
    oneplus_pad_lite_Canary_b oneplus_pad_mt6983_b oneplus_ace_2v_b oneplus_ace_pro_v oneplus_11_b
    oneplus_12r_b oneplus_ace2_pro_b oneplus_ace3_b oneplus_open_b oneplus_nord_ce4_b
    oneplus_12_b oneplus_pad_go_2_b oneplus_nord_ce4_lite_5g_b oneplus_nord_ce6_lite_b oneplus_turbo_6v
    oneplus_nord_4_b oneplus_ace_3v_b oneplus_pad_mt6897_b oneplus_13r_b oneplus_ace3_pro_b
    oneplus_ace5_b oneplus_pad_pro_b oneplus_pad2_b oneplus_nord_ce5_b oneplus_nord_5_b
    oneplus_ace5_pro_b oneplus_13_b oneplus_13t_b oneplus_13s_b oneplus_pad_2_pro_b
    oneplus_pad_3_b oneplus_ace5_race_b oneplus_ace5_ultra_b oneplus_pad2_mt6991_b oneplus_ace_6
    oneplus_turbo_6 oneplus_nord_6 oneplus_ace_6t oneplus_ace_6t_Canary oneplus_15r
    oneplus_15r_Canary oneplus_15 oneplus_15_Canary oneplus_15t oneplus_15t_Canary
    oneplus_pad_3_pro oneplus_pad_3_pro_Canary oneplus_pad_4 oneplus_pad_4_Canary oneplus_ace6_ultra
    oneplus_ace6_ultra_Canary
  )

  BUILD_ALL=$(_choose "构建范围 (BUILD_ALL): Off=单机型, All/MTK/Qualcomm=批量" "$BUILD_ALL" Off All MTK Qualcomm)
  if [ "$BUILD_ALL" = "Off" ]; then
    FILE=$(_choose_file "$FILE" "${FILE_OPTIONS[@]}")
  else
    warn "批量模式下将忽略单个 FILE，按范围 [$BUILD_ALL] 自动选择机型"
  fi
  MANAGER_SOURCE=$(_choose "选择管理器调用方向 (MANAGER_SOURCE)" "$MANAGER_SOURCE" MIUIX MIUIX_SPOOF MD3 MD3_SPOOF)
  KPM=$(_choose "选择内核模块实现方式 (KPM)" "$KPM" KPM KPN N/A)
  SUSFS_CI=$(_choose "选择 SUSFS 模块下载方向 (SUSFS_CI)" "$SUSFS_CI" CI Release N/A)
  FAST_BUILD=$(_ask_bool "是否启用极速构建 (FAST_BUILD)？" "$FAST_BUILD")
  LSM_BBG=$(_ask_bool "是否启用关键分区写入保护 (LSM_BBG)？" "$LSM_BBG")
  NETFILTER=$(_ask_bool "是否启用网络功能拓展 (NETFILTER)？" "$NETFILTER")
  CCM=$(_ask_bool "是否启用网络拥塞控制 BBR+ECN (CCM)？" "$CCM")
  UNICODE_BYPASS=$(_ask_bool "是否添加 Unicode 绕过修复 (UNICODE_BYPASS)？" "$UNICODE_BYPASS")
  SCHED_HMBIRD=$(_ask_bool "是否添加风驰驱动 (SCHED_HMBIRD)？" "$SCHED_HMBIRD")
  DROID_SPACES=$(_ask_bool "是否添加 DroidSpaces 容器支持？" "$DROID_SPACES")
  RE_KERNEL=$(_ask_bool "是否添加 Re-Kernel？" "$RE_KERNEL")
  LZ4_UPDATE=$(_ask_bool "是否升级 LZ4 到上游最新 (LZ4_UPDATE)？" "$LZ4_UPDATE")
  SUSFS_DEV=$(_ask_bool "是否拉取 SUSFS-DEV 分支？" "$SUSFS_DEV")

  ZRAM=$(_ask_text "ZRAM 配置 (开关0/1 / 算法名 / 大小)" "$ZRAM")
  KSU_META=$(_ask_text "KSU_META (分支名/标识/回退hash，须含两个 /)" "$KSU_META")
  SUSFS_META=$(_ask_text "回退 SUSFS (哈希/次数/-1关闭，留空=最新)" "$SUSFS_META")
  SUFFIX=$(_ask_text "自定义内核后缀 (留空=随机, -1=关闭)" "$SUFFIX")
  SUBLEVEL=$(_ask_text "自定义内核等级 SUBLEVEL (留空=默认)" "$SUBLEVEL")
  BUILD_TIME=$(_ask_text "自定义构建时间 (F=UTC, -1=关闭)" "$BUILD_TIME")
  DYNAMIC_REPO=$(_ask_text "动态清单仓库所有者 (DYNAMIC_REPO)" "$DYNAMIC_REPO")

  # 本地构建相关
  INSTALL_DEPS=$(_ask_bool "开始前自动安装 apt 依赖？" "$INSTALL_DEPS")
  CREATE_SWAP=$(_ask_bool "内存不足时自动创建 3G swap？" "$CREATE_SWAP")
  BUILD_NOCACHE=$(_ask_bool "停用本次缓存 (ccache/thinlto)？" "$BUILD_NOCACHE")
  WORKROOT=$(_ask_text "工作目录 WORKROOT" "$WORKROOT")

  group "已选择的配置确认"
  cat >&2 <<EOF
  BUILD_ALL      = $BUILD_ALL
  FILE           = $([ "$BUILD_ALL" = "Off" ] && echo "$FILE" || echo "(批量模式忽略)")
  MANAGER_SOURCE = $MANAGER_SOURCE
  KPM            = $KPM
  SUSFS_CI       = $SUSFS_CI
  FAST_BUILD     = $FAST_BUILD
  LSM_BBG        = $LSM_BBG
  NETFILTER      = $NETFILTER
  CCM            = $CCM
  UNICODE_BYPASS = $UNICODE_BYPASS
  SCHED_HMBIRD   = $SCHED_HMBIRD
  DROID_SPACES   = $DROID_SPACES
  RE_KERNEL      = $RE_KERNEL
  LZ4_UPDATE     = $LZ4_UPDATE
  SUSFS_DEV      = $SUSFS_DEV
  ZRAM           = $ZRAM
  KSU_META       = $KSU_META
  SUSFS_META     = ${SUSFS_META:-(空)}
  SUFFIX         = ${SUFFIX:-(空)}
  SUBLEVEL       = ${SUBLEVEL:-(默认)}
  BUILD_TIME     = $BUILD_TIME
  DYNAMIC_REPO   = $DYNAMIC_REPO
  INSTALL_DEPS   = $INSTALL_DEPS
  CREATE_SWAP    = $CREATE_SWAP
  BUILD_NOCACHE  = $BUILD_NOCACHE
  WORKROOT       = $WORKROOT
EOF
  local go
  read -r -p "$(echo -e "\033[1;33m确认以上配置并开始构建？(Y/n): \033[0m")" go </dev/tty
  case "$go" in
    n|N|no|NO) echo "已取消。" >&2; exit 0 ;;
  esac
}

###############################################################################
# 五、批量构建支持(对应工作流 prepare job)
###############################################################################

# 可批量构建的全部机型清单(与上方 FILE 选项保持一致)
ALL_FILES=(
  oneplus_nord_n30_se_5g_v oneplus_10r_v oneplus_nord_3_v oneplus_ace_v oneplus_ace_race_v
  oneplus_10_pro_b oneplus_10t_v oneplus_11r_b oneplus_ace2_b oneplus_pad_lite_b
  oneplus_pad_lite_Canary_b oneplus_pad_mt6983_b oneplus_ace_2v_b oneplus_ace_pro_v oneplus_11_b
  oneplus_12r_b oneplus_ace2_pro_b oneplus_ace3_b oneplus_open_b oneplus_nord_ce4_b
  oneplus_12_b oneplus_pad_go_2_b oneplus_nord_ce4_lite_5g_b oneplus_nord_ce6_lite_b oneplus_turbo_6v
  oneplus_nord_4_b oneplus_ace_3v_b oneplus_pad_mt6897_b oneplus_13r_b oneplus_ace3_pro_b
  oneplus_ace5_b oneplus_pad_pro_b oneplus_pad2_b oneplus_nord_ce5_b oneplus_nord_5_b
  oneplus_ace5_pro_b oneplus_13_b oneplus_13t_b oneplus_13s_b oneplus_pad_2_pro_b
  oneplus_pad_3_b oneplus_ace5_race_b oneplus_ace5_ultra_b oneplus_pad2_mt6991_b oneplus_ace_6
  oneplus_turbo_6 oneplus_nord_6 oneplus_ace_6t oneplus_ace_6t_Canary oneplus_15r
  oneplus_15r_Canary oneplus_15 oneplus_15_Canary oneplus_15t oneplus_15t_Canary
  oneplus_pad_3_pro oneplus_pad_3_pro_Canary oneplus_pad_4 oneplus_pad_4_Canary oneplus_ace6_ultra
  oneplus_ace6_ultra_Canary
)

# 解析某机型清单的 CPU(用于区分 MTK / 高通)，成功输出 CPU，失败输出空
declare -A _BRANCHES_CACHE
resolve_cpu() {
  local F="$1" ENTRY OWNER REPO_NAME BRANCHES BRANCH XML_URL REVISION CPU
  local REPO_LIST=(
    "OnePlusOSS|kernel_manifest"
    "${DYNAMIC_REPO}|kernel_manifest"
    "Numbersf|Kernel_Manifest_Appendix"
  )
  for ENTRY in "${REPO_LIST[@]}"; do
    OWNER="${ENTRY%%|*}"; REPO_NAME="${ENTRY##*|}"
    [[ -z "$OWNER" ]] && continue
    if [[ -z "${_BRANCHES_CACHE[$OWNER/$REPO_NAME]+x}" ]]; then
      _BRANCHES_CACHE[$OWNER/$REPO_NAME]=$(git ls-remote --heads "https://github.com/${OWNER}/${REPO_NAME}.git" 2>/dev/null | sed 's|.*refs/heads/||')
    fi
    BRANCHES="${_BRANCHES_CACHE[$OWNER/$REPO_NAME]}"
    [[ -z "$BRANCHES" ]] && continue
    for BRANCH in $BRANCHES; do
      XML_URL="https://raw.githubusercontent.com/${OWNER}/${REPO_NAME}/${BRANCH}/${F}.xml"
      REVISION=$(curl -sf "$XML_URL" 2>/dev/null | grep -oP '<project[^>]+revision="\K[^"]+' | head -n1 || true)
      if [[ -n "$REVISION" ]]; then
        CPU=$(echo "$REVISION" | sed -E 's#^(oneplus|realme|oppo)/([^_]+).*#\2#')
        echo "$CPU"; return 0
      fi
    done
  done
  echo ""; return 0
}

# 根据 BUILD_ALL 计算要构建的机型列表，结果写入全局数组 SELECTED_FILES
generate_file_list() {
  SELECTED_FILES=()
  if [ "$BUILD_ALL" = "Off" ]; then
    log "🎯 单机型构建模式: $FILE"
    SELECTED_FILES=("$FILE")
    return
  fi
  if [ "$BUILD_ALL" = "All" ]; then
    log "🌐 批量构建模式: 全部 ${#ALL_FILES[@]} 个机型"
    SELECTED_FILES=("${ALL_FILES[@]}")
    return
  fi
  # MTK / Qualcomm：解析各机型 CPU 后筛选
  log "🌐 批量构建模式: 按厂商筛选 ($BUILD_ALL)，正在解析各机型 CPU..."
  local f CPU VENDOR
  for f in "${ALL_FILES[@]}"; do
    CPU=$(resolve_cpu "$f")
    if [[ -z "$CPU" ]]; then warn "无法解析 $f 的 CPU，已跳过"; continue; fi
    if [[ "$CPU" == mt* ]]; then VENDOR="MTK"; else VENDOR="Qualcomm"; fi
    if [ "$VENDOR" = "$BUILD_ALL" ]; then
      log "✅ $f (CPU=$CPU) -> $VENDOR [选中]"
      SELECTED_FILES+=("$f")
    else
      echo "  ➖ $f (CPU=$CPU) -> $VENDOR [跳过]"
    fi
  done
  if [ "${#SELECTED_FILES[@]}" -eq 0 ]; then
    err "按范围 $BUILD_ALL 筛选后没有任何机型可构建"; exit 1
  fi
  log "本次将构建 ${#SELECTED_FILES[@]} 个机型: ${SELECTED_FILES[*]}"
}

###############################################################################
# 六、主流程
###############################################################################

# 构建单个机型(对应工作流 build job 的全部 per-device 步骤)
build_one() {
  FILE="$1"
  setup_paths_for_file
  # 重置可能在机型间残留的状态变量
  ZRAM_ALGO_U=""; KERNEL_REPOS=""; ENABLE_RUST=false; FAST_FALLBACK=false

  group "===== 开始构建机型: $FILE ====="
  step_extract_info
  step_mtk_compat
  step_configure_git_clone_actionbuild
  step_install_ccache_ecs
  step_init_ccache
  step_repo_sync
  step_kernel_version
  step_rust_version
  step_fix_btf_pahole
  step_kernel_suffix
  step_resolve_manager
  step_add_sukisu
  step_apply_patches_susfs
  step_apply_hmbird_convert
  step_apply_unicode_bypass
  step_apply_re_kernel
  step_apply_droid_spaces
  step_apply_lz4_dev
  step_apply_zram
  step_apply_sched_hmbird
  step_apply_lsm_bbg
  step_add_config
  step_fix_ipv6_nat
  step_custom_build_time
  step_disable_gpueb
  step_build
  step_make_anykernel
  step_apply_kpm
  step_download_susfs_module
  step_package
}

main() {
  [ "$INTERACTIVE" = "true" ] && interactive_config

  group "OnePlus Kernel 本地构建开始"
  if [ "$BUILD_ALL" = "Off" ]; then
    log "机型: $FILE | 管理器: $MANAGER_SOURCE | KPM: $KPM | FAST_BUILD: $FAST_BUILD"
  else
    log "批量范围: $BUILD_ALL | 管理器: $MANAGER_SOURCE | KPM: $KPM | FAST_BUILD: $FAST_BUILD"
  fi
  log "工作目录: $WORKROOT"
  mkdir -p "$WORKROOT"
  write_reject_checker

  # 全局一次性步骤
  step_install_deps
  step_create_swap
  step_install_repo_tool

  # 计算待构建机型列表
  generate_file_list

  local SUCCEEDED=() FAILED=() dev
  for dev in "${SELECTED_FILES[@]}"; do
    if build_one "$dev"; then
      SUCCEEDED+=("$dev")
    else
      warn "❌ 机型 $dev 构建失败，继续下一个"
      FAILED+=("$dev")
    fi
  done

  group "全部构建任务结束"
  log "成功 (${#SUCCEEDED[@]}): ${SUCCEEDED[*]:-无}"
  [ "${#FAILED[@]}" -gt 0 ] && warn "失败 (${#FAILED[@]}): ${FAILED[*]}"
  log "产物目录: $WORKROOT (各机型 zip 已按名称区分)"
  [ "${#FAILED[@]}" -gt 0 ] && return 1 || return 0
}

main "$@"
