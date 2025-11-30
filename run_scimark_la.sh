#!/bin/bash
# SciMark 2.0 Unified Device Runner for LoongArch64 Android
# Combines benchmarking and profiling capabilities

set -e
set -o pipefail

# --- Configuration ---
# Try to detect AOSP root if not set
if [ -z "$AOSP_ROOT" ]; then
    # Assuming script is in tmp/MyBenchMark/scimark, go up 4 levels
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Check if we are in the expected structure
    if [ -f "$SCRIPT_DIR/../../../build/envsetup.sh" ]; then
        AOSP_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    else
        # Fallback to 4 levels up as per original script
        AOSP_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
    fi
fi

SCIMARK_DIR="${AOSP_ROOT}/tmp/MyBenchMark/scimark"
DEVICE_CHROOT="/data/local/art-test-chroot"
DEVICE_TMP="/data/tmp"
DEFAULT_OUTPUT_DIR="./device-perf-result"
FLAMEGRAPH_DIR="${AOSP_ROOT}/tmp/Perf/FlameGraph"

# Defaults
ITERATIONS=1
JIT_MODE="interpreter"
ENABLE_FLAMEGRAPH=false
PERF_FREQUENCY=1000
NO_UNWIND=false
VERBOSE=false
ENABLE_LOG=false
LOG_LEVEL=""
FLAMEGRAPH_OUTPUT=""
SCIMARK_ARGS=()
GDB_MODE=false
GDB_ARGS=()

# --- Helper Functions ---

usage() {
    cat <<EOF
Usage: $0 [options] [--] [SciMark args]

Unified SciMark 2.0 Runner for LoongArch64 Android Device.
Supports standard benchmarking and Simpleperf profiling.

Options:
  -n, --iterations <N>       Number of iterations (default: 1)
  --jit                      Disable JIT (default)
  --interpreter              Force interpreter mode (-Xusejit:false) (default)
  --switch-interpreter       Use switch interpreter (-Xint)
  --jit-on-first-use         Aggressive JIT (-Xjitthreshold:0)
  
  --flamegraph               Enable Simpleperf profiling and generate FlameGraph
  --flamegraph-output <path> Path to save the SVG flamegraph
  --perf-frequency <Hz>      Sampling frequency for profiling (default: 1000)
  --no-unwind                Disable stack unwinding in Simpleperf (faster)
  
  --gdb                      Run under gdbserver64 (port :5039)
  --gdb-arg <arg>            Pass option to dalvikvm (can be used multiple times)

  -o, --output <dir>         Local directory for results (default: ./results)
  -log                       Enable logging to file
  --log-level <level>        Log level (verbose, debug, info, etc.)
  -v, --verbose              Show verbose output
  -h, --help                 Show this help

SciMark Args:
  -large                     Use large dataset
  <min_time>                 Minimum time per test

Examples:
  $0                         # Run 1 iteration with JIT
  $0 --interpreter -n 5      # Run 5 iterations in interpreter mode
  $0 --flamegraph -- -large  # Run profiling with large dataset
EOF
    exit 0
}

log() {
    echo "[$(date +'%H:%M:%S')] $1"
}

# --- Argument Parsing ---

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--iterations)
            ITERATIONS="$2"
            shift 2
            ;;
        --jit)
            JIT_MODE="jit"
            shift
            ;;
        --interpreter)
            JIT_MODE="interpreter"
            shift
            ;;
        --switch-interpreter)
            JIT_MODE="switch"
            shift
            ;;
        --jit-on-first-use)
            JIT_MODE="jit-first"
            shift
            ;;
        --flamegraph)
            ENABLE_FLAMEGRAPH=true
            ITERATIONS=1 # Profiling usually only needs one run
            shift
            ;;
        --flamegraph-output)
            FLAMEGRAPH_OUTPUT="$2"
            shift 2
            ;;
        --perf-frequency)
            PERF_FREQUENCY="$2"
            shift 2
            ;;
        --no-unwind)
            NO_UNWIND=true
            shift
            ;;
        --gdb)
            GDB_MODE=true
            ITERATIONS=1
            shift
            ;;
        --gdb-arg)
            GDB_ARGS+=("$2")
            shift 2
            ;;
        -o|--output)
            DEFAULT_OUTPUT_DIR="$2"
            shift 2
            ;;
        -log)
            ENABLE_LOG=true
            shift
            ;;
        --log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
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

# --- Environment Setup ---

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}/${TIMESTAMP}-${JIT_MODE}"

if [ "$ENABLE_LOG" = true ] || [ "$ENABLE_FLAMEGRAPH" = true ]; then
    mkdir -p "$OUTPUT_DIR"
    LOG_FILE="$OUTPUT_DIR/run.log"
    log "Logging to $LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Results will be saved to: $OUTPUT_DIR"
fi

# Ensure we have ADB
if ! command -v adb &> /dev/null; then
    if [ -f "$AOSP_ROOT/init.sh" ]; then
        log "Sourcing AOSP environment..."
        source "$AOSP_ROOT/init.sh"
        source "$AOSP_ROOT/adb.sh"
    else
        echo "Error: adb not found and AOSP root not detected at $AOSP_ROOT."
        exit 1
    fi
fi

# --- Device Preparation ---

log "Checking Device Environment..."

# Check/Push Jar
if ! adb shell "test -f $DEVICE_CHROOT$DEVICE_TMP/scimark-dex.jar"; then
    log "Pushing scimark-dex.jar to device..."
    if [ ! -f "scimark-dex.jar" ]; then
        # Try to find it or build it
        if [ -f "scimark2lib.jar" ]; then
             log "Building dex from scimark2lib.jar..."
             d8 --min-api 26 --output scimark-dex.jar scimark2lib.jar
        else
             echo "Error: scimark-dex.jar and scimark2lib.jar not found locally."
             exit 1
        fi
    fi
    adb push scimark-dex.jar "$DEVICE_CHROOT$DEVICE_TMP/scimark-dex.jar"
fi

# --- Command Construction ---

# Bootclasspath (Standard for ART chroot)
BCP="/apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/apex/com.android.i18n/javalib/core-icu4j.jar:/apex/com.android.conscrypt/javalib/conscrypt.jar"

# JIT Flags
case "$JIT_MODE" in
    interpreter)
        JIT_FLAGS="-Xusejit:false"
        ;;
    switch)
        JIT_FLAGS="-Xint -Xusejit:false"
        ;;
    jit)
        JIT_FLAGS="-Xusejit:true"
        ;;
    jit-first)
        JIT_FLAGS="-Xusejit:true -Xjitthreshold:0"
        ;;
esac

# GDB Setup
GDB_PREFIX=""
if [ "$GDB_MODE" = true ]; then
    GDB_PREFIX="gdbserver64 --no-startup-with-shell 127.0.0.1:5039"
    echo "GDB Enabled. Please run: adb forward tcp:5039 tcp:5039"
    adb forward tcp:5039 tcp:5039
fi

# Base Dalvik Command
DALVIK_CMD="$GDB_PREFIX /apex/com.android.art/bin/dalvikvm64 \
    ${GDB_ARGS[*]} \
    -Xbootclasspath:$BCP \
    -Xbootclasspath-locations:$BCP \
    -Ximage:/apex/com.android.art/javalib/boot.art \
    $JIT_FLAGS \
    -Xmx256m \
    -cp $DEVICE_TMP/scimark-dex.jar \
    jnt.scimark2.commandline \
    ${SCIMARK_ARGS[*]}"

# --- Execution ---

log "Starting Benchmark (Mode: $JIT_MODE, Iterations: $ITERATIONS)..."
if [ ${#SCIMARK_ARGS[@]} -gt 0 ]; then
    log "SciMark Args: ${SCIMARK_ARGS[*]}"
fi

for i in $(seq 1 $ITERATIONS); do
    echo "--- Iteration $i/$ITERATIONS ---"
    
    if [ "$ENABLE_FLAMEGRAPH" = true ]; then
        # Profiling Mode
        PERF_DATA_DEVICE="$DEVICE_TMP/perf.data"
        UNWIND_FLAG=""
        if [ "$NO_UNWIND" = true ]; then UNWIND_FLAG="--no-unwind"; fi
        
        log "Running with Simpleperf..."
        
        # Run simpleperf on device
        adb shell "chroot $DEVICE_CHROOT /system/bin/simpleperf record \
            -g -f $PERF_FREQUENCY $UNWIND_FLAG -o $PERF_DATA_DEVICE \
            $DALVIK_CMD"
            
        log "Pulling perf data..."
        adb pull "$DEVICE_CHROOT$PERF_DATA_DEVICE" "$OUTPUT_DIR/perf.data"
        
        # Generate Reports
        log "Generating text reports..."
        adb shell "chroot $DEVICE_CHROOT /system/bin/simpleperf report -i $PERF_DATA_DEVICE --sort symbol --percent-limit 0.01" > "$OUTPUT_DIR/report_symbol.txt"
        adb shell "chroot $DEVICE_CHROOT /system/bin/simpleperf report -i $PERF_DATA_DEVICE -g --percent-limit 0.01" > "$OUTPUT_DIR/report_callgraph.txt"
        
        # FlameGraph generation
        SIMPLEPERF_SCRIPTS_DIR="${AOSP_ROOT}/system/extras/simpleperf/scripts"
        REPORT_SAMPLE_SCRIPT="${SIMPLEPERF_SCRIPTS_DIR}/report_sample.py"
        STACKCOLLAPSE_SCRIPT="${FLAMEGRAPH_DIR}/stackcollapse-perf.pl"
        FLAMEGRAPH_SCRIPT="${FLAMEGRAPH_DIR}/flamegraph.pl"

        if [ -f "$FLAMEGRAPH_SCRIPT" ] && [ -f "$STACKCOLLAPSE_SCRIPT" ]; then
             log "Generating FlameGraph..."
             
             if [ -f "$REPORT_SAMPLE_SCRIPT" ]; then
                 # 1. Generate perf script format using report_sample.py
                 # Set PYTHONPATH to find simpleperf dependencies
                 export PYTHONPATH="$SIMPLEPERF_SCRIPTS_DIR:$PYTHONPATH"
                 python3 "$REPORT_SAMPLE_SCRIPT" -i "$OUTPUT_DIR/perf.data" > "$OUTPUT_DIR/out.perf" 2>/dev/null
                 
                 # 2. Fold stacks
                 "$STACKCOLLAPSE_SCRIPT" "$OUTPUT_DIR/out.perf" > "$OUTPUT_DIR/out.folded"
                 
                 # 3. Generate SVG
                 FINAL_SVG="$OUTPUT_DIR/flamegraph.svg"
                 if [ -n "$FLAMEGRAPH_OUTPUT" ]; then
                     FINAL_SVG="$FLAMEGRAPH_OUTPUT"
                     mkdir -p "$(dirname "$FINAL_SVG")"
                 fi
                 
                 "$FLAMEGRAPH_SCRIPT" \
                    --title "SciMark 2.0 - $JIT_MODE" \
                    --colors java \
                    --width 1800 \
                    "$OUTPUT_DIR/out.folded" > "$FINAL_SVG"
                    
                 log "FlameGraph saved to: $FINAL_SVG"
             else
                 log "Warning: report_sample.py not found at $REPORT_SAMPLE_SCRIPT. Skipping FlameGraph."
             fi
        else
             log "Warning: FlameGraph tools (flamegraph.pl/stackcollapse-perf.pl) not found at $FLAMEGRAPH_DIR"
        fi
        
    else
        # Standard Mode
        if [ "$VERBOSE" = true ]; then
            log "Executing: adb shell \"chroot $DEVICE_CHROOT $DALVIK_CMD\""
        fi
        
        # Clear logcat buffer to capture fresh crash logs
        adb logcat -c
        
        # Temporarily disable set -e to capture exit code
        set +e
        adb shell "chroot $DEVICE_CHROOT $DALVIK_CMD"
        RET=$?
        set -e
        
        if [ $RET -ne 0 ]; then
            echo "Error: Benchmark failed with exit code $RET"
            if [ $RET -eq 134 ]; then
                echo "Tip: Exit code 134 usually indicates a native crash (SIGABRT)."
                echo "     Try running with --interpreter to rule out JIT issues."
                echo "--- CRASH LOG (Last 50 lines) ---"
                adb logcat -d | tail -n 50
                echo "---------------------------------"
            fi
            exit $RET
        fi
    fi
done