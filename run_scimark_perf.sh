#!/bin/bash
# SciMark 2.0 性能分析脚本 - 使用 simpleperf 生成火焰图
# 在 LoongArch64 Android 设备上进行性能分析

set -e

# 默认参数
OUTPUT_DIR="/data/tmp/scimark-perf"
LOCAL_OUTPUT_DIR="./perf-results"
PERF_FREQUENCY=1000
USE_JIT=false
NO_UNWIND=false
FLAMEGRAPH=false
FLAMEGRAPH_DIR="/home/yanxi/loongson/aosp15.la/tmp/Perf/FlameGraph"

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

SciMark 2.0 性能分析脚本 - 使用 simpleperf 采集性能数据并生成火焰图

选项:
    -f, --frequency <频率>     采样频率 (默认: 1000 Hz)
    -o, --output <目录>        本地输出目录 (默认: ./perf-results)
    --jit                      启用 JIT 编译器 (默认: 禁用)
    --no-unwind                禁用调用栈展开 (默认: 启用展开)
    --flamegraph               生成 FlameGraph 火焰图 (默认: 禁用)
    -h, --help                 显示此帮助信息

示例:
    $0                         # 使用默认参数运行 (禁用 JIT，启用调用栈展开)
    $0 --jit                   # 启用 JIT 编译器
    $0 -f 2000                 # 使用 2000Hz 采样频率
    $0 --jit -f 2000           # 启用 JIT，使用 2000Hz 采样
    $0 --no-unwind             # 禁用调用栈展开（更快但信息较少）
    $0 --flamegraph            # 生成 FlameGraph 火焰图
    $0 --jit --flamegraph      # 启用 JIT 并生成火焰图
    $0 -o ./my-perf            # 指定输出目录

输出文件:
    - perf.data                原始性能数据
    - perf-report.txt          性能报告文本
    - flamegraph.svg           火焰图

EOF
    exit 0
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--frequency)
            PERF_FREQUENCY="$2"
            shift 2
            ;;
        -o|--output)
            LOCAL_OUTPUT_DIR="$2"
            shift 2
            ;;
        --jit)
            USE_JIT=true
            shift
            ;;
        --no-unwind)
            NO_UNWIND=true
            shift
            ;;
        --flamegraph)
            FLAMEGRAPH=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "错误: 未知选项 '$1'"
            echo "使用 '$0 --help' 查看帮助信息"
            exit 1
            ;;
    esac
done

# 验证采样频率
if ! [[ "$PERF_FREQUENCY" =~ ^[0-9]+$ ]] || [ "$PERF_FREQUENCY" -lt 1 ]; then
    echo "错误: 采样频率必须是正整数"
    exit 1
fi

# 设置工作目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd /home/yanxi/loongson/aosp15.la
source init.sh && source adb.sh
cd "$SCRIPT_DIR"

echo "═══════════════════════════════════════════════════════════"
echo "     SciMark 2.0 性能分析 (simpleperf)"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "测试日期: $(date)"
echo "采样频率: ${PERF_FREQUENCY} Hz"
echo "JIT 状态: $([ "$USE_JIT" = true ] && echo "启用" || echo "禁用")"
echo "调用栈展开: $([ "$NO_UNWIND" = true ] && echo "禁用" || echo "启用")"
echo "生成火焰图: $([ "$FLAMEGRAPH" = true ] && echo "是" || echo "否")"
echo "输出目录: ${LOCAL_OUTPUT_DIR}"
echo ""

# 检查设备上的文件
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. 环境准备"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 检查 scimark-dex.jar
if adb shell "test -f /data/tmp/scimark-dex.jar && echo exists" 2>/dev/null | grep -q "exists"; then
    echo "✅ 设备上已有 scimark-dex.jar"
else
    echo "⚠️  设备上没有文件，正在推送..."
    if [ ! -f "scimark-dex.jar" ]; then
        echo "❌ 本地找不到 scimark-dex.jar"
        exit 1
    fi
    adb push scimark-dex.jar /data/tmp/scimark-dex.jar
    echo "✅ 推送完成"
fi

# 创建输出目录
echo "创建输出目录..."
adb shell "mkdir -p ${OUTPUT_DIR}" 2>/dev/null || true
mkdir -p "${LOCAL_OUTPUT_DIR}"
echo "✅ 输出目录创建完成"
echo ""

# 构建 dalvikvm 命令参数
JIT_FLAG=$([ "$USE_JIT" = true ] && echo "-Xusejit:true" || echo "-Xusejit:false")
JIT_DESC=$([ "$USE_JIT" = true ] && echo "JIT" || echo "nterp")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. 运行性能分析 (${JIT_DESC})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 构建完整的 dalvikvm 命令
DALVIKVM_CMD="chroot /data/local/art-test-chroot /apex/com.android.art/bin/dalvikvm64 \
-Xbootclasspath:/apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/apex/com.android.i18n/javalib/core-icu4j.jar:/apex/com.android.conscrypt/javalib/conscrypt.jar \
-Xbootclasspath-locations:/apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/apex/com.android.i18n/javalib/core-icu4j.jar:/apex/com.android.conscrypt/javalib/conscrypt.jar \
-Ximage:/apex/com.android.art/javalib/boot.art \
${JIT_FLAG} \
-Xmx256m \
-cp /data/tmp/scimark-dex.jar \
jnt.scimark2.commandline"

# 运行 simpleperf
echo "开始采集性能数据..."
UNWIND_FLAG=$([ "$NO_UNWIND" = true ] && echo "--no-unwind" || echo "")
echo "命令: simpleperf record -g -f ${PERF_FREQUENCY} ${UNWIND_FLAG} ..."
echo ""

adb shell "/system/bin/simpleperf record \
-g \
-f ${PERF_FREQUENCY} \
-o ${OUTPUT_DIR}/perf.data \
${UNWIND_FLAG} \
${DALVIKVM_CMD}" 2>&1 | tee /tmp/perf-output.txt | grep -E "Composite Score:|FFT|SOR|Monte|Sparse|LU"

echo ""
echo "✅ 性能数据采集完成"
echo ""

# 生成性能报告
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. 生成性能报告"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "生成符号报告（按符号排序）..."
adb shell "/system/bin/simpleperf report \
-i ${OUTPUT_DIR}/perf.data \
--sort symbol \
--percent-limit 0.01" > "${LOCAL_OUTPUT_DIR}/perf-report-${JIT_DESC}.txt"

echo "✅ 符号报告已保存: ${LOCAL_OUTPUT_DIR}/perf-report-${JIT_DESC}.txt"

echo "生成调用图报告（包含调用栈）..."
adb shell "/system/bin/simpleperf report \
-i ${OUTPUT_DIR}/perf.data \
-g \
--percent-limit 0.01" > "${LOCAL_OUTPUT_DIR}/perf-report-${JIT_DESC}-callgraph.txt"

echo "✅ 调用图报告已保存: ${LOCAL_OUTPUT_DIR}/perf-report-${JIT_DESC}-callgraph.txt"

# 检查报告前几行
echo ""
echo "符号报告摘要 (前 30 行):"
head -30 "${LOCAL_OUTPUT_DIR}/perf-report-${JIT_DESC}.txt"
echo ""

# 拉取原始数据
echo "拉取原始性能数据..."
adb pull ${OUTPUT_DIR}/perf.data "${LOCAL_OUTPUT_DIR}/perf-${JIT_DESC}.data"
echo "✅ 原始数据已保存: ${LOCAL_OUTPUT_DIR}/perf-${JIT_DESC}.data"
echo ""

# 尝试生成火焰图 (如果支持)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. 生成火焰图"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FLAMEGRAPH" = true ]; then
    echo "使用 FlameGraph 工具生成火焰图..."
    
    # 检查 FlameGraph 工具是否存在
    if [ ! -f "${FLAMEGRAPH_DIR}/flamegraph.pl" ]; then
        echo "❌ 找不到 FlameGraph 工具: ${FLAMEGRAPH_DIR}/flamegraph.pl"
        echo "   请确认 FlameGraph 目录路径正确"
    else
        # 检查转换脚本是否存在
        CONVERT_SCRIPT="${LOCAL_OUTPUT_DIR}/convert_simpleperf_to_folded.py"
        if [ ! -f "${CONVERT_SCRIPT}" ]; then
            echo "⚠️  转换脚本不存在，正在创建..."
            cp /home/yanxi/loongson/aosp15.la/tmp/MyBenchMark/scimark/convert_simpleperf_to_folded.py "${CONVERT_SCRIPT}"
            chmod +x "${CONVERT_SCRIPT}"
            echo "✅ 转换脚本创建完成"
        fi
        
        # 步骤1: 从设备导出 simpleperf 原始数据
        echo "步骤 1/3: 导出调用栈数据 (设备端)..."
        
        # 使用设备端 simpleperf 导出原始数据 (包含 vaddr)
        adb shell "/system/bin/simpleperf report-sample -i ${OUTPUT_DIR}/perf.data --show-callchain" > "${LOCAL_OUTPUT_DIR}/perf-${JIT_DESC}-raw.txt" 2>&1
        
        if [ -s "${LOCAL_OUTPUT_DIR}/perf-${JIT_DESC}-raw.txt" ]; then
            echo "✅ 调用栈数据导出完成"
            
            # 步骤2: 解析符号并转换为折叠格式
            echo "步骤 2/3: 解析符号并转换为折叠格式..."
            RESOLVE_SCRIPT="${SCRIPT_DIR}/resolve_and_fold.py"
            if [ ! -f "${RESOLVE_SCRIPT}" ]; then
                 echo "❌ 找不到解析脚本: ${RESOLVE_SCRIPT}"
                 exit 1
            fi
            
            python3 "${RESOLVE_SCRIPT}" "${LOCAL_OUTPUT_DIR}/perf-${JIT_DESC}-raw.txt" > "${LOCAL_OUTPUT_DIR}/perf-${JIT_DESC}.folded" 2>&1
            
            # 步骤3: 生成火焰图
            echo "步骤 3/3: 生成火焰图 SVG..."
            tail -n +3 "${LOCAL_OUTPUT_DIR}/perf-${JIT_DESC}.folded" | \
                "${FLAMEGRAPH_DIR}/flamegraph.pl" \
                --title "SciMark 2.0 Performance - ${JIT_DESC}" \
                --colors java \
                --width 1800 \
                > "${LOCAL_OUTPUT_DIR}/flamegraph-${JIT_DESC}.svg"
            
            if [ -f "${LOCAL_OUTPUT_DIR}/flamegraph-${JIT_DESC}.svg" ]; then
                echo "✅ 火焰图已生成: ${LOCAL_OUTPUT_DIR}/flamegraph-${JIT_DESC}.svg"
                echo "   可以使用浏览器打开查看"
            else
                echo "❌ 火焰图生成失败"
            fi
        else
            echo "❌ 调用栈数据导出失败"
        fi
    fi
else
    echo "⚠️  未启用 FlameGraph 生成，使用 --flamegraph 选项启用"
fi

# 检查设备上是否有 report_html.py (simpleperf 内置火焰图)
if [ "$FLAMEGRAPH" = false ]; then
    if adb shell "test -f /system/bin/report_html.py && echo exists" 2>/dev/null | grep -q "exists"; then
        echo ""
        echo "提示: 设备支持 simpleperf 内置火焰图，可以使用 --flamegraph 选项生成"
    fi
fi
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "     性能分析完成"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "输出文件位置: ${LOCAL_OUTPUT_DIR}/"
echo "  - perf-${JIT_DESC}.data                    原始性能数据"
echo "  - perf-report-${JIT_DESC}.txt              符号报告（按符号排序）"
echo "  - perf-report-${JIT_DESC}-callgraph.txt    调用图报告（含调用栈）"
if [ -f "${LOCAL_OUTPUT_DIR}/flamegraph-${JIT_DESC}.svg" ]; then
    echo "  - flamegraph-${JIT_DESC}.svg               FlameGraph 火焰图"
fi
if [ -f "${LOCAL_OUTPUT_DIR}/flamegraph-${JIT_DESC}.html" ]; then
    echo "  - flamegraph-${JIT_DESC}.html              火焰图"
fi
echo ""
echo "提示: 可以使用以下命令查看详细报告:"
echo "  less ${LOCAL_OUTPUT_DIR}/perf-report-${JIT_DESC}.txt             # 查看符号报告"
echo "  less ${LOCAL_OUTPUT_DIR}/perf-report-${JIT_DESC}-callgraph.txt   # 查看调用栈"
if [ -f "${LOCAL_OUTPUT_DIR}/flamegraph-${JIT_DESC}.svg" ]; then
    echo "  firefox ${LOCAL_OUTPUT_DIR}/flamegraph-${JIT_DESC}.svg          # 浏览器查看 FlameGraph 火焰图"
fi
if [ -f "${LOCAL_OUTPUT_DIR}/flamegraph-${JIT_DESC}.html" ]; then
    echo "  firefox ${LOCAL_OUTPUT_DIR}/flamegraph-${JIT_DESC}.html"
fi
echo ""
