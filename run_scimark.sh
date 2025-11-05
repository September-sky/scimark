#!/bin/bash
# SciMark 2.0 性能对比测试脚本
# 本地 x86_64 vs LoongArch64 Android ART

set -e

# 默认参数
ITERATIONS=3
RUN_LOCAL=true
RUN_DEVICE=true

# 显示帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

SciMark 2.0 性能基准测试脚本 - 支持本地和 LoongArch64 Android 设备测试

选项:
    -n, --iterations <次数>    设置迭代次数 (默认: 3)
    -l, --local-only           仅运行本地测试 (x86_64)
    -d, --device-only          仅运行设备测试 (LoongArch64)
    -h, --help                 显示此帮助信息

示例:
    $0                         # 本地和设备各运行 3 次
    $0 -n 5                    # 本地和设备各运行 5 次
    $0 -l -n 10                # 仅本地运行 10 次
    $0 -d -n 1                 # 仅设备运行 1 次
    $0 --local-only            # 仅本地测试，默认 3 次

测试项目:
    - FFT (1024)               快速傅里叶变换
    - SOR (100x100)            连续超松弛迭代
    - Monte Carlo              蒙特卡洛积分
    - Sparse matmult           稀疏矩阵乘法
    - LU (100x100)             LU 分解

EOF
    exit 0
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--iterations)
            ITERATIONS="$2"
            shift 2
            ;;
        -l|--local-only)
            RUN_DEVICE=false
            shift
            ;;
        -d|--device-only)
            RUN_LOCAL=false
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

# 验证迭代次数
if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || [ "$ITERATIONS" -lt 1 ]; then
    echo "错误: 迭代次数必须是正整数"
    exit 1
fi

# 设置 AOSP 环境变量以使用 d8
cd /home/yanxi/loongson/aosp15.la
source init.sh && source adb.sh
cd -

cd /home/yanxi/loongson/aosp15.la/tmp/MyBenchMark/scimark

echo "═══════════════════════════════════════════════════════════"
echo "     SciMark 2.0 性能基准测试对比"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "测试日期: $(date)"
echo "测试项目: FFT, SOR, Monte Carlo, Sparse matmult, LU"
echo "迭代次数: ${ITERATIONS}次"
if [ "$RUN_LOCAL" = true ] && [ "$RUN_DEVICE" = true ]; then
    echo "测试模式: 本地 + 设备"
elif [ "$RUN_LOCAL" = true ]; then
    echo "测试模式: 仅本地 (x86_64)"
else
    echo "测试模式: 仅设备 (LoongArch64)"
fi
echo ""

# 检查本地文件
if [ ! -f "scimark-dex.jar" ]; then
    echo "⚠️  找不到 scimark-dex.jar，开始转换..."
    if [ ! -f "scimark2lib.jar" ]; then
        echo "❌ 找不到 scimark2lib.jar，请先下载"
        echo "   wget https://math.nist.gov/scimark2/scimark2lib.jar"
        exit 1
    fi
    d8 --min-api 26 --output scimark-dex.jar scimark2lib.jar
    echo "✅ DEX 转换完成"
fi

# 检查设备上的文件
echo "检查设备文件..."
if adb shell "chroot /data/local/art-test-chroot test -f /data/tmp/scimark-dex.jar && echo exists" 2>/dev/null | grep -q "exists"; then
    echo "✅ 设备上已有 scimark-dex.jar"
else
    echo "⚠️  设备上没有文件，正在推送..."
    adb push scimark-dex.jar /data/local/art-test-chroot/data/tmp/scimark-dex.jar
    echo "✅ 推送完成"
fi
echo ""

# ============= 本地测试 =============
if [ "$RUN_LOCAL" = true ]; then
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. 本地测试 (x86_64 OpenJDK)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
java -version 2>&1 | head -3
echo ""

for i in $(seq 1 $ITERATIONS); do
    echo "▶ 本地迭代 $i/$ITERATIONS"
    /usr/bin/time -f "   时间: %E (Real: %es, User: %Us, Sys: %Ss, CPU: %P)" \
        java -cp scimark2lib.jar jnt.scimark2.commandline 2>&1 | \
        grep -E "Composite Score:|FFT|SOR|Monte|Sparse|LU|时间:"
    echo ""
done
fi

# ============= 设备测试 =============
if [ "$RUN_DEVICE" = true ]; then
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$RUN_LOCAL" = true ]; then
    echo "2. 设备测试 (LoongArch64 Android ART)"
else
    echo "设备测试 (LoongArch64 Android ART)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
adb shell "chroot /data/local/art-test-chroot /apex/com.android.art/bin/dalvikvm64 -version" 2>&1 | head -1
echo ""

for i in $(seq 1 $ITERATIONS); do
    echo "▶ 设备迭代 $i/$ITERATIONS"
    /usr/bin/time -f "   时间: %E (Real: %es, User: %Us, Sys: %Ss)" \
        adb shell "chroot /data/local/art-test-chroot \
        /apex/com.android.art/bin/dalvikvm64 \
        -Xbootclasspath:/apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/apex/com.android.i18n/javalib/core-icu4j.jar:/apex/com.android.conscrypt/javalib/conscrypt.jar \
        -Xbootclasspath-locations:/apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/apex/com.android.i18n/javalib/core-icu4j.jar:/apex/com.android.conscrypt/javalib/conscrypt.jar \
        -Ximage:/apex/com.android.art/javalib/boot.art \
        -Xusejit:true -Xmx256m \
        -cp /data/tmp/scimark-dex.jar jnt.scimark2.commandline" 2>&1 | \
        grep -E "Composite Score:|FFT|SOR|Monte|Sparse|LU|时间:"
    echo ""
done
fi

echo "═══════════════════════════════════════════════════════════"
echo "     测试完成"
echo "═══════════════════════════════════════════════════════════"
