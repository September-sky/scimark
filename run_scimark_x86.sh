#!/bin/bash

set -o pipefail

usage() {
  cat <<'EOF'
用法: ./art_run_local.sh [脚本选项] [--] [SciMark 参数]

脚本选项:
  --flamegraph               使用 perf+FlameGraph 生成火焰图
  --flamegraph-output PATH   指定 SVG 输出路径 (默认: ./local-perf-result/<时间戳>-<模式...>/scimark-perf.svg)
  --perf-frequency N         perf 采样频率 (默认 1000 Hz)
  --perf-bin PATH            指定 perf 可执行文件
  --perf-mmap-pages N        perf 缓冲区页数 (默认 1024，0 表示不设置)
  --interpreter              强制解释模式 (默认)
  --switch-interpreter       使用 switch-interpreter (等价 -Xint)
  --jit                      启用 JIT（默认关闭，走解释器）
  --jit-on-first-use         激进 JIT，首次调用立即编译
  --debuggable               启用 debuggable 模式（编译器 --debuggable + 运行时 -Xopaque-jni-ids:true）
  -log                       生成结果文件夹并记录日志 (火焰图模式默认开启)
  --log-level LEVEL          设置日志级别。
                             可选值: verbose(v), debug(d), info(i), warning(w),
                             error(e), fatal(f), silent(s)
  -v, --verbose              显示实际执行的完整命令
  -h, --help                 显示此帮助

SciMark 原生参数:
  -large                     使用大规模测试
  <minimum_time>             每个子项最少运行秒数
EOF
}

AOSP="/home/yanxi/loongson/aosp15.la"
AOSP_OUT_HOST="$AOSP/out/host/linux-x86"
FLAMEGRAPH_ROOT="/home/yanxi/loongson/aosp15.la/tmp/Perf/FlameGraph"
PERF_FREQ=1000
PERF_BIN="$(command -v perf 2>/dev/null)"
FLAMEGRAPH_OUTPUT=""
PERF_OUTPUT_ROOT="./local-perf-result"
ENABLE_FLAMEGRAPH=0
ENABLE_LOG=0
LOG_LEVEL=""
VERBOSE=0
JIT_MODE="interpreter"
PERF_MMAP_PAGES=1024
DEBUGGABLE=0

SCIMARK_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flamegraph)
      ENABLE_FLAMEGRAPH=1
      shift
      ;;
    --flamegraph-output)
      if [[ -z "${2:-}" ]]; then
        echo "[错误] --flamegraph-output 需要参数" >&2
        exit 1
      fi
      FLAMEGRAPH_OUTPUT="$2"
      shift 2
      ;;
    --perf-frequency)
      if [[ -z "${2:-}" ]]; then
        echo "[错误] --perf-frequency 需要参数" >&2
        exit 1
      fi
      PERF_FREQ="$2"
      shift 2
      ;;
    --perf-bin)
      if [[ -z "${2:-}" ]]; then
        echo "[错误] --perf-bin 需要参数" >&2
        exit 1
      fi
      PERF_BIN="$2"
      shift 2
      ;;
    --perf-mmap-pages)
      if [[ -z "${2:-}" ]]; then
        echo "[错误] --perf-mmap-pages 需要参数" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "[错误] --perf-mmap-pages 只能是非负整数" >&2
        exit 1
      fi
      PERF_MMAP_PAGES="$2"
      shift 2
      ;;
    --interpreter)
      JIT_MODE="interpreter"
      shift
      ;;
    --switch-interpreter)
      if [[ "${JIT_MODE}" == "jit" || "${JIT_MODE}" == "jit-first" ]]; then
        echo "[错误] --switch-interpreter 不能与 --jit 或 --jit-on-first-use 同时使用" >&2
        exit 1
      fi
      JIT_MODE="switch"
      shift
      ;;
    --jit)
      if [[ "${JIT_MODE}" == "switch" ]]; then
        echo "[错误] --jit 不能与 --switch-interpreter 同时使用" >&2
        exit 1
      fi
      JIT_MODE="jit"
      shift
      ;;
    --jit-on-first-use)
      if [[ "${JIT_MODE}" == "switch" ]]; then
        echo "[错误] --jit-on-first-use 不能与 --switch-interpreter 同时使用" >&2
        exit 1
      fi
      JIT_MODE="jit-first"
      shift
      ;;
    --debuggable)
      DEBUGGABLE=1
      shift
      ;;
    -log)
      ENABLE_LOG=1
      shift
      ;;
    --log-level)
      if [[ -z "${2:-}" ]]; then
        echo "[错误] --log-level 需要参数" >&2
        exit 1
      fi
      LOG_LEVEL="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      SCIMARK_ARGS+=("$@")
      break
      ;;
    *)
      SCIMARK_ARGS+=("$1")
      shift
      ;;
  esac
done

BOOTCLASSPATH="${AOSP_OUT_HOST}/apex/com.android.art/javalib/core-oj.jar:${AOSP_OUT_HOST}/apex/com.android.art/javalib/core-libart.jar:${AOSP_OUT_HOST}/apex/com.android.art/javalib/okhttp.jar:${AOSP_OUT_HOST}/apex/com.android.art/javalib/bouncycastle.jar:${AOSP_OUT_HOST}/apex/com.android.art/javalib/apache-xml.jar:${AOSP_OUT_HOST}/apex/com.android.i18n/javalib/core-icu4j.jar:${AOSP_OUT_HOST}/apex/com.android.conscrypt/javalib/conscrypt.jar"

export ANDROID_BUILD_TOP="${AOSP}"
export ANDROID_HOST_OUT="${AOSP_OUT_HOST}"
export ANDROID_ROOT="${AOSP_OUT_HOST}"
export ANDROID_ART_ROOT="${AOSP_OUT_HOST}/apex/com.android.art"
export ANDROID_I18N_ROOT="${AOSP_OUT_HOST}/com.android.i18n"
export ANDROID_TZDATA_ROOT="${AOSP_OUT_HOST}/com.android.tzdata"
export ANDROID_DATA="${AOSP_OUT_HOST}/tmpdata"
export ICU_DATA_PATH="${ANDROID_I18N_ROOT}/etc/icu"
export LD_LIBRARY_PATH="${AOSP_OUT_HOST}/lib64:${AOSP_OUT_HOST}/lib"
export LD_USE_LOAD_BIAS=1
export PATH="${AOSP_OUT_HOST}/bin:${PATH}"

if [[ -n "${LOG_LEVEL:-}" ]]; then
  case "${LOG_LEVEL}" in
    verbose|v) l="v" ;;
    debug|d)   l="d" ;;
    info|i)    l="i" ;;
    warning|w) l="w" ;;
    error|e)   l="e" ;;
    fatal|f)   l="f" ;;
    silent|s)  l="s" ;;
    *)         l="${LOG_LEVEL}" ;;
  esac
  export ANDROID_LOG_TAGS="*:${l}"
fi

mkdir -p "${ANDROID_DATA}"/dalvik-cache/x86_64

jit_flags=()
case "${JIT_MODE}" in
  interpreter)
    jit_flags+=("-Xusejit:false")
    ;;
  switch)
    jit_flags+=("-Xint" "-Xusejit:false")
    ;;
  jit)
    jit_flags+=("-Xusejit:true")
    ;;
  jit-first)
    jit_flags+=("-Xusejit:true" "-Xjitthreshold:0")
    ;;
esac

dalvik_cmd=(
  "${AOSP_OUT_HOST}/bin/dalvikvm64"
  "-Xbootclasspath:${BOOTCLASSPATH}"
  "-Xbootclasspath-locations:${BOOTCLASSPATH}"
)

if [[ ${#jit_flags[@]} -gt 0 ]]; then
  dalvik_cmd+=("${jit_flags[@]}")
fi

if [[ ${DEBUGGABLE} -eq 1 ]]; then
  # -Xcompiler-option --debuggable 传给 dex2oat 编译器
  # -Xopaque-jni-ids:true 传给运行时（启用不透明 JNI ID）
  dalvik_cmd+=("-Xcompiler-option" "--debuggable" "-Xopaque-jni-ids:true")
fi

dalvik_cmd+=(
  -cp
  scimark-dex.jar
  jnt.scimark2.commandline
)

if [[ ${#SCIMARK_ARGS[@]} -gt 0 ]]; then
  dalvik_cmd+=("${SCIMARK_ARGS[@]}")
fi

if [[ ${ENABLE_FLAMEGRAPH} -eq 1 ]]; then
  if [[ -z "${PERF_BIN}" || ! -x "${PERF_BIN}" ]]; then
    echo "[错误] 找不到可执行的 perf，请安装或通过 --perf-bin 指定" >&2
    exit 1
  fi
  if ! command -v perl >/dev/null 2>&1; then
    echo "[错误] 生成火焰图需要 perl" >&2
    exit 1
  fi

  STACK_COLLAPSE="${FLAMEGRAPH_ROOT}/stackcollapse-perf.pl"
  FLAMEGRAPH_PL="${FLAMEGRAPH_ROOT}/flamegraph.pl"

  if [[ ! -f "${STACK_COLLAPSE}" || ! -f "${FLAMEGRAPH_PL}" ]]; then
    echo "[错误] 未找到 FlameGraph 脚本，请确认目录 ${FLAMEGRAPH_ROOT}" >&2
    exit 1
  fi
fi

if [[ ${ENABLE_FLAMEGRAPH} -eq 1 || ${ENABLE_LOG} -eq 1 ]]; then
  mode_name="interpreter"
  case "${JIT_MODE}" in
    interpreter)
      mode_name="interpreter"
      ;;
    switch)
      mode_name="switch-interpreter"
      ;;
    jit)
      mode_name="jit"
      ;;
    jit-first)
      mode_name="jit-on-first-use"
      ;;
  esac

  if [[ ${DEBUGGABLE} -eq 1 ]]; then
    mode_name="${mode_name}-debuggable"
  fi

  arg_suffix=""
  if [[ ${#SCIMARK_ARGS[@]} -gt 0 ]]; then
    arg_suffix="$(printf -- "-%s" "${SCIMARK_ARGS[@]}")"
    arg_suffix="${arg_suffix// /_}"
    arg_suffix="${arg_suffix//$'\n'/_}"
    arg_suffix="${arg_suffix//[^A-Za-z0-9_.-]/_}"
  fi

  timestamp="$(date +%Y%m%d-%H%M%S)"
  run_dir="${PERF_OUTPUT_ROOT}/${timestamp}-${mode_name}${arg_suffix}"
  mkdir -p "${run_dir}"

  log_file="${run_dir}/scimark-run.log"

  echo "[信息] 日志输出: ${log_file}" >&2
  exec > "${log_file}" 2>&1
fi

if [[ ${ENABLE_FLAMEGRAPH} -eq 1 ]]; then
  perf_data="${run_dir}/scimark-perf.data"
  folded_txt="${run_dir}/scimark-perf.folded"

  if [[ -z "${FLAMEGRAPH_OUTPUT}" ]]; then
    FLAMEGRAPH_OUTPUT="${run_dir}/scimark-perf.svg"
  else
    mkdir -p "$(dirname "${FLAMEGRAPH_OUTPUT}")"
  fi

  echo "[信息] 使用 perf 采样，输出 ${perf_data}" >&2
  perf_record_cmd=("${PERF_BIN}" record --call-graph dwarf -F "${PERF_FREQ}" -o "${perf_data}")
  if [[ -n "${PERF_MMAP_PAGES}" && "${PERF_MMAP_PAGES}" != "0" ]]; then
    perf_record_cmd+=(--mmap-pages "${PERF_MMAP_PAGES}")
  fi
  perf_record_cmd+=(-- "${dalvik_cmd[@]}")
  if [[ ${VERBOSE} -eq 1 ]]; then
    echo "[执行命令] ${perf_record_cmd[*]}" >&2
  fi
  "${perf_record_cmd[@]}"

  echo "[信息] 生成折叠栈文件 ${folded_txt}" >&2
  "${PERF_BIN}" script -i "${perf_data}" | perl "${STACK_COLLAPSE}" > "${folded_txt}"

  echo "[信息] 生成火焰图 ${FLAMEGRAPH_OUTPUT}" >&2
  perl "${FLAMEGRAPH_PL}" "${folded_txt}" > "${FLAMEGRAPH_OUTPUT}"

  echo "[完成] 火焰图已生成: ${FLAMEGRAPH_OUTPUT}" >&2
else
  if [[ ${VERBOSE} -eq 1 ]]; then
    echo "[执行命令] ${dalvik_cmd[*]}" >&2
  fi
  "${dalvik_cmd[@]}"
fi