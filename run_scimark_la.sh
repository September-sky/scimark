#!/bin/bash
# SciMark 2.0 Unified Device Runner for LoongArch64 Android
# Combines benchmarking and profiling capabilities

set -e

# --- Configuration ---
# Try to detect AOSP root if not set
if [ -z "$AOSP_ROOT" ]; then
    # Assuming script is in tmp/MyBenchMark/scimark, go up 4 levels
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    AOSP_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi

SCIMARK_DIR="${AOSP_ROOT}/tmp/MyBenchMark/scimark"
DEVICE_CHROOT="/data/local/art-test-chroot"
DEVICE_TMP="/data/tmp"
DEFAULT_OUTPUT_DIR="./results"
FLAMEGRAPH_DIR="${AOSP_ROOT}/tmp/Perf/FlameGraph"

# Defaults
ITERATIONS=1
JIT_MODE="jit"
ENABLE_FLAMEGRAPH=false
PERF_FREQUENCY=1000
NO_UNWIND=false
VERBOSE=false
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# --- Helper Functions ---

usage() {
    cat <<EOF
Usage: $0 [options]

Unified SciMark 2.0 Runner for LoongArch64 Android Device.
Supports standard benchmarking and Simpleperf profiling.

Options:
  -n, --iterations <N>       Number of iterations (default: 3)
  --jit                      Enable JIT (default)
  --interpreter              Force interpreter mode (-Xusejit:false)
  --switch-interpreter       Use switch interpreter (-Xint)
  --jit-on-first-use         Aggressive JIT (-Xjitthreshold:0)
  
  --flamegraph               Enable Simpleperf profiling and generate FlameGraph
  --perf-frequency <Hz>      Sampling frequency for profiling (default: 1000)
  --no-unwind                Disable stack unwinding in Simpleperf (faster)
  
  -o, --output <dir>         Local directory for results (default: ./results)
  -v, --verbose              Show verbose output
  -h, --help                 Show this help

Examples:
  $0                         # Run 3 iterations with JIT
  $0 --interpreter -n 5      # Run 5 iterations in interpreter mode
  $0 --flamegraph            # Run once with profiling enabled
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
        --perf-frequency)
            PERF_FREQUENCY="$2"
            shift 2
            ;;
        --no-unwind)
            NO_UNWIND=true
            shift
            ;;
        -o|--output)
            DEFAULT_OUTPUT_DIR="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option '$1'"
            exit 1
            ;;
    esac
done

# --- Environment Setup ---

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

# Prepare Output Directory
OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}/${TIMESTAMP}-${JIT_MODE}"
mkdir -p "$OUTPUT_DIR"
log "Results will be saved to: $OUTPUT_DIR"

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

# Base Dalvik Command
DALVIK_CMD="/apex/com.android.art/bin/dalvikvm64 \
    -Xbootclasspath:$BCP \
    -Xbootclasspath-locations:$BCP \
    -Ximage:/apex/com.android.art/javalib/boot.art \
    $JIT_FLAGS \
    -Xmx256m \
    -cp $DEVICE_TMP/scimark-dex.jar \
    jnt.scimark2.commandline"

# --- Execution ---

log "Starting Benchmark (Mode: $JIT_MODE, Iterations: $ITERATIONS)..."

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
            $DALVIK_CMD" 2>&1 | tee "$OUTPUT_DIR/run.log" | grep -E "Composite Score:|FFT|SOR|Monte|Sparse|LU"
            
        log "Pulling perf data..."
        adb pull "$DEVICE_CHROOT$PERF_DATA_DEVICE" "$OUTPUT_DIR/perf.data"
        
        # Generate Reports
        log "Generating text reports..."
        adb shell "chroot $DEVICE_CHROOT /system/bin/simpleperf report -i $PERF_DATA_DEVICE --sort symbol --percent-limit 0.01" > "$OUTPUT_DIR/report_symbol.txt"
        adb shell "chroot $DEVICE_CHROOT /system/bin/simpleperf report -i $PERF_DATA_DEVICE -g --percent-limit 0.01" > "$OUTPUT_DIR/report_callgraph.txt"
        
        # FlameGraph generation
        if [ -f "$FLAMEGRAPH_DIR/flamegraph.pl" ]; then
             log "Generating FlameGraph..."
             
             # 1. Export raw samples from device
             adb shell "chroot $DEVICE_CHROOT /system/bin/simpleperf report-sample -i $PERF_DATA_DEVICE --show-callchain" > "$OUTPUT_DIR/perf-raw.txt"
             
             # 2. Fold stacks (Check for resolve_and_fold.py or use simple folding)
             RESOLVE_SCRIPT="./resolve_and_fold.py"
             if [ -f "$RESOLVE_SCRIPT" ]; then
                 python3 "$RESOLVE_SCRIPT" "$OUTPUT_DIR/perf-raw.txt" > "$OUTPUT_DIR/perf.folded" 2>/dev/null
                 
                 # 3. Generate SVG
                 "$FLAMEGRAPH_DIR/flamegraph.pl" \
                    --title "SciMark 2.0 - $JIT_MODE" \
                    --colors java \
                    --width 1800 \
                    "$OUTPUT_DIR/perf.folded" > "$OUTPUT_DIR/flamegraph.svg"
                    
                 log "FlameGraph saved to: $OUTPUT_DIR/flamegraph.svg"
             else
                 log "Warning: resolve_and_fold.py not found. Skipping FlameGraph SVG generation."
             fi
        else
             log "Warning: FlameGraph tools not found at $FLAMEGRAPH_DIR"
        fi
        
    else
        # Standard Mode
        adb shell "chroot $DEVICE_CHROOT $DALVIK_CMD" #!/bin/bash
# SciMark 2.0 Unified Device Runner for LoongArch64 Android
# Combines benchmarking and profiling capabilities

set -e

# --- Configuration ---
# Try to detect AOSP root if not set
if [ -z "$AOSP_ROOT" ]; then
    # Assuming script is in tmp/MyBenchMark/scimark, go up 4 levels
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    AOSP_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi

SCIMARK_DIR="${AOSP_ROOT}/tmp/MyBenchMark/scimark"
DEVICE_CHROOT="/data/local/art-test-chroot"
DEVICE_TMP="/data/tmp"
DEFAULT_OUTPUT_DIR="./results"
FLAMEGRAPH_DIR="${AOSP_ROOT}/tmp/Perf/FlameGraph"

# Defaults
ITERATIONS=3
JIT_MODE="jit"
ENABLE_FLAMEGRAPH=false
PERF_FREQUENCY=1000
NO_UNWIND=false
VERBOSE=false
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# --- Helper Functions ---

usage() {
    cat <<EOF
Usage: $0 [options]

Unified SciMark 2.0 Runner for LoongArch64 Android Device.
Supports standard benchmarking and Simpleperf profiling.

Options:
  -n, --iterations <N>       Number of iterations (default: 3)
  --jit                      Enable JIT (default)
  --interpreter              Force interpreter mode (-Xusejit:false)
  --switch-interpreter       Use switch interpreter (-Xint)
  --jit-on-first-use         Aggressive JIT (-Xjitthreshold:0)
  
  --flamegraph               Enable Simpleperf profiling and generate FlameGraph
  --perf-frequency <Hz>      Sampling frequency for profiling (default: 1000)
  --no-unwind                Disable stack unwinding in Simpleperf (faster)
  
  -o, --output <dir>         Local directory for results (default: ./results)
  -v, --verbose              Show verbose output
  -h, --help                 Show this help

Examples:
  $0                         # Run 3 iterations with JIT
  $0 --interpreter -n 5      # Run 5 iterations in interpreter mode
  $0 --flamegraph            # Run once with profiling enabled
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
        --perf-frequency)
            PERF_FREQUENCY="$2"
            shift 2
            ;;
        --no-unwind)
            NO_UNWIND=true
            shift
            ;;
        -o|--output)
            DEFAULT_OUTPUT_DIR="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option '$1'"
            exit 1
            ;;
    esac
done

# --- Environment Setup ---

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

# Prepare Output Directory
OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}/${TIMESTAMP}-${JIT_MODE}"
mkdir -p "$OUTPUT_DIR"
log "Results will be saved to: $OUTPUT_DIR"

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

# Base Dalvik Command
DALVIK_CMD="/apex/com.android.art/bin/dalvikvm64 \
    -Xbootclasspath:$BCP \
    -Xbootclasspath-locations:$BCP \
    -Ximage:/apex/com.android.art/javalib/boot.art \
    $JIT_FLAGS \
    -Xmx256m \
    -cp $DEVICE_TMP/scimark-dex.jar \
    jnt.scimark2.commandline"

# --- Execution ---

log "Starting Benchmark (Mode: $JIT_MODE, Iterations: $ITERATIONS)..."

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
            $DALVIK_CMD" 2>&1 | tee "$OUTPUT_DIR/run.log" | grep -E "Composite Score:|FFT|SOR|Monte|Sparse|LU"
            
        log "Pulling perf data..."
        adb pull "$DEVICE_CHROOT$PERF_DATA_DEVICE" "$OUTPUT_DIR/perf.data"
        
        # Generate Reports
        log "Generating text reports..."
        adb shell "chroot $DEVICE_CHROOT /system/bin/simpleperf report -i $PERF_DATA_DEVICE --sort symbol --percent-limit 0.01" > "$OUTPUT_DIR/report_symbol.txt"
        adb shell "chroot $DEVICE_CHROOT /system/bin/simpleperf report -i $PERF_DATA_DEVICE -g --percent-limit 0.01" > "$OUTPUT_DIR/report_callgraph.txt"
        
        # FlameGraph generation
        if [ -f "$FLAMEGRAPH_DIR/flamegraph.pl" ]; then
             log "Generating FlameGraph..."
             
             # 1. Export raw samples from device
             adb shell "chroot $DEVICE_CHROOT /system/bin/simpleperf report-sample -i $PERF_DATA_DEVICE --show-callchain" > "$OUTPUT_DIR/perf-raw.txt"
             
             # 2. Fold stacks (Check for resolve_and_fold.py or use simple folding)
             RESOLVE_SCRIPT="./resolve_and_fold.py"
             if [ -f "$RESOLVE_SCRIPT" ]; then
                 python3 "$RESOLVE_SCRIPT" "$OUTPUT_DIR/perf-raw.txt" > "$OUTPUT_DIR/perf.folded" 2>/dev/null
                 
                 # 3. Generate SVG
                 "$FLAMEGRAPH_DIR/flamegraph.pl" \
                    --title "SciMark 2.0 - $JIT_MODE" \
                    --colors java \
                    --width 1800 \
                    "$OUTPUT_DIR/perf.folded" > "$OUTPUT_DIR/flamegraph.svg"
                    
                 log "FlameGraph saved to: $OUTPUT_DIR/flamegraph.svg"
             else
                 log "Warning: resolve_and_fold.py not found. Skipping FlameGraph SVG generation."
             fi
        else
             log "Warning: FlameGraph tools not found at $FLAMEGRAPH_DIR"
        fi
        
    else
        # Standard Mode
        adb shell "chroot $DEVICE_CHROOT $DALVIK_CMD" 