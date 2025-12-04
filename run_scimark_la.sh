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
POST_UNWIND=false
KEEP_FAILED_UNWIND=false
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
  --fp                       Use frame pointer unwinding (recommended for chroot/interpreter)
  --no-unwind                Disable stack unwinding in Simpleperf (faster, but flame graph will be flat)
  --post-unwind              Unwind call stacks after recording (may improve success rate)
  --keep-failed-unwind       Keep failed unwinding debug info for diagnosis
  
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
        --fp)
            USE_FP=true
            shift
            ;;
        --no-unwind)
            NO_UNWIND=true
            shift
            ;;
        --post-unwind)
            POST_UNWIND=true
            shift
            ;;
        --keep-failed-unwind)
            KEEP_FAILED_UNWIND=true
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
        
        if [ "$USE_FP" = true ]; then
            CALL_GRAPH_OPTION="--call-graph fp"
        else
            CALL_GRAPH_OPTION="--call-graph dwarf"
        fi

        EXTRA_PERF_OPTIONS=""
        
        if [ "$NO_UNWIND" = true ]; then
            log "WARNING: --no-unwind will disable call stack unwinding."
            log "         Flame graph will only show flat profile without call chains."
            log "         Remove --no-unwind to see full call stacks."
            CALL_GRAPH_OPTION="--no-unwind"
        fi
        
        if [ "$POST_UNWIND" = true ]; then
            log "Using post-unwind mode (unwinding after recording)..."
            EXTRA_PERF_OPTIONS="$EXTRA_PERF_OPTIONS --post-unwind=yes"
        fi
        
        if [ "$KEEP_FAILED_UNWIND" = true ]; then
            log "Keeping failed unwinding debug info..."
            EXTRA_PERF_OPTIONS="$EXTRA_PERF_OPTIONS --keep-failed-unwinding-result --keep-failed-unwinding-debug-info"
        fi
        
        if [ "$NO_UNWIND" = true ]; then
            CG_MODE="disabled"
        elif [ "$USE_FP" = true ]; then
            CG_MODE="fp"
        else
            CG_MODE="dwarf"
        fi
        log "Running with Simpleperf (call-graph: $CG_MODE)..."
    
        
        # Run simpleperf on device (using system simpleperf outside chroot)
        # --call-graph dwarf: Use DWARF debug info for stack unwinding (more reliable than frame pointer)
        adb shell "/system/bin/simpleperf record \
            $CALL_GRAPH_OPTION $EXTRA_PERF_OPTIONS -f $PERF_FREQUENCY -o $DEVICE_CHROOT$PERF_DATA_DEVICE \
            chroot $DEVICE_CHROOT $DALVIK_CMD"
            
        log "Pulling perf data..."
        adb pull "$DEVICE_CHROOT$PERF_DATA_DEVICE" "$OUTPUT_DIR/perf.data"
        
        # Pull JIT profile maps (perf-*.map)
        # ART usually writes these to /data/local/tmp or /tmp
        # Since we are in chroot, check chroot's tmp locations
        log "Pulling JIT maps..."
        # Try to find map files in common locations
        MAP_FILES=$(adb shell "find $DEVICE_CHROOT/data/local/tmp $DEVICE_CHROOT/tmp -name 'perf-*.map' 2>/dev/null")
        if [ -n "$MAP_FILES" ]; then
            for map_file in $MAP_FILES; do
                log "Pulling map file: $map_file"
                adb pull "$map_file" "$OUTPUT_DIR/"
            done
        else
            log "Warning: No perf-*.map files found. JIT symbols might be missing."
        fi

        # Generate Reports
        log "Generating text reports..."
        adb shell "/system/bin/simpleperf report -i $DEVICE_CHROOT$PERF_DATA_DEVICE --sort symbol --percent-limit 0.01" > "$OUTPUT_DIR/report_symbol.txt"
        adb shell "/system/bin/simpleperf report -i $DEVICE_CHROOT$PERF_DATA_DEVICE -g --percent-limit 0.01" > "$OUTPUT_DIR/report_callgraph.txt"
        
        # FlameGraph generation
        SIMPLEPERF_SCRIPTS_DIR="${AOSP_ROOT}/system/extras/simpleperf/scripts"
        STACKCOLLAPSE_PY="${SIMPLEPERF_SCRIPTS_DIR}/stackcollapse.py"
        BINARY_CACHE_BUILDER="${SIMPLEPERF_SCRIPTS_DIR}/binary_cache_builder.py"
        FLAMEGRAPH_SCRIPT="${FLAMEGRAPH_DIR}/flamegraph.pl"

        if [ -f "$FLAMEGRAPH_SCRIPT" ] && [ -f "$STACKCOLLAPSE_PY" ]; then
             log "Generating FlameGraph..."
             
             # Set PYTHONPATH to find simpleperf dependencies
             export PYTHONPATH="$SIMPLEPERF_SCRIPTS_DIR:$PYTHONPATH"
             
             # 0. Build binary_cache (Pull symbols from device)
             if [ -f "$BINARY_CACHE_BUILDER" ]; then
                 log "Building binary_cache (pulling symbols)..."
                 
                 # Try to find local symbols
                 LOCAL_LIB_ARGS=()
                 # Detect product output directory (assuming only one product or taking the first one)
                 PRODUCT_OUT_DIRS=("$AOSP_ROOT/out/target/product/"*)
                 if [ ${#PRODUCT_OUT_DIRS[@]} -gt 0 ] && [ -d "${PRODUCT_OUT_DIRS[0]}" ]; then
                     PRODUCT_OUT="${PRODUCT_OUT_DIRS[0]}"
                     SYMBOLS_DIR="$PRODUCT_OUT/symbols"
                     OBJ_LIB_DIR="$PRODUCT_OUT/obj/SHARED_LIBRARIES"
                     
                     if [ -d "$SYMBOLS_DIR" ]; then
                         log "Found local symbols dir: $SYMBOLS_DIR"
                         LOCAL_LIB_ARGS+=("-lib" "$SYMBOLS_DIR")
                     fi
                     if [ -d "$OBJ_LIB_DIR" ]; then
                         log "Found local obj libs dir: $OBJ_LIB_DIR"
                         LOCAL_LIB_ARGS+=("-lib" "$OBJ_LIB_DIR")
                     fi
                 fi

                 # binary_cache_builder.py in AOSP doesn't support -o, it uses binary_cache in current dir by default
                 # We need to cd to OUTPUT_DIR to make it work cleanly
                 
                 pushd "$OUTPUT_DIR" > /dev/null
                 python3 "$BINARY_CACHE_BUILDER" -i "perf.data" "${LOCAL_LIB_ARGS[@]}" >/dev/null 2>&1
                 popd > /dev/null

                 # Force overwrite with local symbols (User Request)
                 if [ -n "$SYMBOLS_DIR" ] || [ -n "$OBJ_LIB_DIR" ]; then
                     log "Forcing local symbols for ART libraries..."
                     for lib_name in "libart.so" "libartd.so" "dalvikvm64" "libc.so"; do
                         # Find local file (Prefer unstripped)
                         LOCAL_FILE=""
                         
                         # Helper function to find unstripped file in a directory
                         find_unstripped() {
                             local dir="$1"
                             local name="$2"
                             if [ -d "$dir" ]; then
                                 find "$dir" -name "$name" | while read -r cand; do
                                     if file "$cand" | grep -q "not stripped"; then
                                         echo "$cand"
                                         break
                                     fi
                                 done
                             fi
                         }
                         
                         # Try SYMBOLS_DIR first
                         if [ -n "$SYMBOLS_DIR" ]; then
                             LOCAL_FILE=$(find_unstripped "$SYMBOLS_DIR" "$lib_name" | head -n 1)
                         fi
                         
                         # Try OBJ_LIB_DIR if not found
                         if [ -z "$LOCAL_FILE" ] && [ -n "$OBJ_LIB_DIR" ]; then
                             LOCAL_FILE=$(find_unstripped "$OBJ_LIB_DIR" "$lib_name" | head -n 1)
                         fi
                         
                         if [ -f "$LOCAL_FILE" ]; then
                             log "Found local unstripped $lib_name: $LOCAL_FILE"
                             # Find in binary_cache
                             CACHE_FILES=$(find "$OUTPUT_DIR/binary_cache" -name "$lib_name")
                             if [ -n "$CACHE_FILES" ]; then
                                 for cache_file in $CACHE_FILES; do
                                     log "Overwriting cache file: $cache_file"
                                     cp -f "$LOCAL_FILE" "$cache_file"
                                 done
                             else
                                 log "Warning: $lib_name not found in binary_cache, cannot overwrite."
                             fi
                         else
                             log "Warning: Could not find local unstripped $lib_name"
                         fi
                     done
                 fi
                 
                 # Copy JIT maps to binary_cache if they exist
                 if ls "$OUTPUT_DIR"/perf-*.map 1> /dev/null 2>&1; then
                     mkdir -p "$OUTPUT_DIR/binary_cache"
                     cp "$OUTPUT_DIR"/perf-*.map "$OUTPUT_DIR/binary_cache/"
                 fi
                 
                 # Use binary_cache for stackcollapse
                 SYMBOLS_DIR="$OUTPUT_DIR/binary_cache"
             else
                 log "Warning: binary_cache_builder.py not found. Symbols might be missing."
                 SYMBOLS_DIR="$OUTPUT_DIR"
             fi
             
             # 1. Create proper symfs directory structure for report_sample.py
             # binary_cache uses build-id directories, but report_sample.py expects path-based structure
             log "Creating symfs directory with proper paths..."
             SYMFS_DIR="$OUTPUT_DIR/symfs"
             mkdir -p "$SYMFS_DIR"
             
             # Method 1: Copy apex, system, data directories from binary_cache if they exist
             for dir in apex system data; do
                 if [ -d "$OUTPUT_DIR/binary_cache/$dir" ]; then
                     log "Copying $dir directory to symfs..."
                     cp -rL "$OUTPUT_DIR/binary_cache/$dir" "$SYMFS_DIR/" 2>/dev/null || true
                 fi
             done
             
             # Method 2: For build-id based files, simpleperf report can use them directly
             # We'll use a different approach - use simpleperf report with proper symbol paths
             # Instead of relying on symfs, we'll use the device's simpleperf report which has symbols
             
             # Alternative: If symfs is still empty, create manual links for known libraries
             if [ ! -d "$SYMFS_DIR/apex" ]; then
                 log "Creating manual symfs structure from binary_cache..."
                 
                 # Create standard Android paths and link files
                 mkdir -p "$SYMFS_DIR/apex/com.android.art/lib64"
                 mkdir -p "$SYMFS_DIR/system/lib64"
                 mkdir -p "$SYMFS_DIR/system/bin"
                 
                 # Link libartd.so (use absolute paths)
                 artd_file="$OUTPUT_DIR/binary_cache/7d1434719005f63c6a0d5ef1b3a4ae5d00000000/libartd.so"
                 if [ -f "$artd_file" ]; then
                     ln -sf "$(cd "$(dirname "$artd_file")" && pwd)/$(basename "$artd_file")" \
                            "$SYMFS_DIR/apex/com.android.art/lib64/libartd.so"
                     log "Linked libartd.so"
                 fi
                 
                 # Link libc.so (use absolute paths)
                 libc_file="$OUTPUT_DIR/binary_cache/a313b85c01ef6d63309869fa1ec9bfed00000000/libc.so"
                 if [ -f "$libc_file" ]; then
                     ln -sf "$(cd "$(dirname "$libc_file")" && pwd)/$(basename "$libc_file")" \
                            "$SYMFS_DIR/system/lib64/libc.so"
                     log "Linked libc.so"
                 fi
                 
                 # Link other common libraries based on build_id_list
                 if [ -f "$OUTPUT_DIR/binary_cache/build_id_list" ]; then
                     while IFS= read -r line; do
                         # Format: 0xBUILD_ID=relative_path (e.g., 0x7d14...=7d14.../libartd.so)
                         if [[ "$line" =~ 0x([0-9a-f]+)=([^/]+)/([^/]+)$ ]]; then
                             build_id="${BASH_REMATCH[1]}"
                             build_id_dir="${BASH_REMATCH[2]}"
                             filename="${BASH_REMATCH[3]}"
                             
                             actual_file="$OUTPUT_DIR/binary_cache/$build_id_dir/$filename"
                             
                             if [ -f "$actual_file" ]; then
                                 # Determine target path based on filename
                                 case "$filename" in
                                     libartd.so|libart.so|libdexfiled.so|libartbased.so)
                                         target="$SYMFS_DIR/apex/com.android.art/lib64/$filename"
                                         ;;
                                     dalvikvm64)
                                         target="$SYMFS_DIR/apex/com.android.art/bin/$filename"
                                         mkdir -p "$SYMFS_DIR/apex/com.android.art/bin"
                                         ;;
                                     libc.so|libm.so|libdl.so)
                                         target="$SYMFS_DIR/system/lib64/$filename"
                                         ;;
                                     linker64)
                                         target="$SYMFS_DIR/system/bin/$filename"
                                         ;;
                                     *)
                                         target="$SYMFS_DIR/system/lib64/$filename"
                                         ;;
                                 esac
                                 
                                 if [ ! -e "$target" ]; then
                                     # Use absolute path for symlink
                                     abs_path="$(cd "$(dirname "$actual_file")" && pwd)/$(basename "$actual_file")"
                                     ln -sf "$abs_path" "$target"
                                 fi
                             fi
                         fi
                     done < "$OUTPUT_DIR/binary_cache/build_id_list"
                 fi
             fi
             
             # 2. Generate perf script format using report_sample.py with proper symfs
             REPORT_SAMPLE_SCRIPT="${SIMPLEPERF_SCRIPTS_DIR}/report_sample.py"
             
             if [ -f "$REPORT_SAMPLE_SCRIPT" ]; then
                 log "Generating perf script output with symbols..."
                 
                 # Use binary_cache directly as symfs - simpleperf knows how to handle build-id directories
                 # Also provide the manually created symfs as a fallback
                 python3 "$REPORT_SAMPLE_SCRIPT" \
                    -i "$OUTPUT_DIR/perf.data" \
                    --symfs "$OUTPUT_DIR/binary_cache" \
                    > "$OUTPUT_DIR/out.perf" 2>/dev/null
                 
                 # Check if symbols were resolved
                 UNRESOLVED_COUNT=$(grep -c '\[+[0-9a-f]\+\]' "$OUTPUT_DIR/out.perf" 2>/dev/null || echo 0)
                 RESOLVED_COUNT=$(grep -cE 'art::|nterp_|_Z[0-9]+' "$OUTPUT_DIR/out.perf" 2>/dev/null || echo 0)
                 
                 log "Symbol resolution: $RESOLVED_COUNT resolved, $UNRESOLVED_COUNT unresolved"
                 
                 # If many symbols are still unresolved, try with the manual symfs structure
                 if [ "$UNRESOLVED_COUNT" -gt 1000 ] && [ -d "$SYMFS_DIR/apex" ]; then
                     log "Trying alternative symfs structure..."
                     python3 "$REPORT_SAMPLE_SCRIPT" \
                        -i "$OUTPUT_DIR/perf.data" \
                        --symfs "$SYMFS_DIR" \
                        > "$OUTPUT_DIR/out.perf.alt" 2>/dev/null
                     
                     ALT_UNRESOLVED=$(grep -c '\[+[0-9a-f]\+\]' "$OUTPUT_DIR/out.perf.alt" 2>/dev/null || echo 0)
                     if [ "$ALT_UNRESOLVED" -lt "$UNRESOLVED_COUNT" ]; then
                         log "Alternative symfs produced better results, using it"
                         mv "$OUTPUT_DIR/out.perf.alt" "$OUTPUT_DIR/out.perf"
                     else
                         rm -f "$OUTPUT_DIR/out.perf.alt"
                     fi
                 fi
                 
                 # 3. Fold stacks using Brendan Gregg's stackcollapse-perf.pl
                 log "Folding stacks..."
                 "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" "$OUTPUT_DIR/out.perf" > "$OUTPUT_DIR/out.folded.raw"
                 
                 # 4. Post-process to resolve remaining unresolved symbols using addr2line
                 log "Post-processing unresolved symbols..."
                 python3 - <<'PYEOF' "$OUTPUT_DIR/out.folded.raw" "$OUTPUT_DIR/out.folded" "$OUTPUT_DIR/binary_cache"
import sys
import re
import subprocess
from pathlib import Path

input_file = sys.argv[1]
output_file = sys.argv[2]
binary_cache = sys.argv[3]

# Find libartd.so in binary_cache
libartd_path = None
for p in Path(binary_cache).rglob("libartd.so"):
    libartd_path = str(p)
    break

if not libartd_path:
    # No libartd.so found, just copy the file
    with open(input_file, 'r') as f_in, open(output_file, 'w') as f_out:
        f_out.write(f_in.read())
    sys.exit(0)

# Cache for addr2line results
addr_cache = {}

def resolve_address(addr_hex):
    if addr_hex in addr_cache:
        return addr_cache[addr_hex]
    
    try:
        # Use addr2line to get function name
        result = subprocess.run(
            ['addr2line', '-e', libartd_path, '-f', '-C', addr_hex],
            capture_output=True, text=True, timeout=1
        )
        lines = result.stdout.strip().split('\n')
        if len(lines) >= 1 and lines[0] != '??':
            func_name = lines[0]
            # Clean up function name
            func_name = re.sub(r'\s*\[clone.*?\]$', '', func_name)
            addr_cache[addr_hex] = func_name
            return func_name
    except:
        pass
    
    addr_cache[addr_hex] = None
    return None

# Process folded stacks
with open(input_file, 'r') as f_in, open(output_file, 'w') as f_out:
    for line in f_in:
        line = line.rstrip()
        if not line:
            continue
        
        # Check if line contains unresolved libartd.so symbols
        if 'libartd.so[+' in line:
            # Extract all unresolved addresses
            def replace_unresolved(match):
                addr = match.group(1)
                resolved = resolve_address(addr)
                if resolved:
                    return resolved
                return match.group(0)  # Keep original if resolution fails
            
            line = re.sub(r'libartd\.so\[\+([0-9a-f]+)\]', replace_unresolved, line)
        
        f_out.write(line + '\n')
PYEOF
                 
                 # Check resolution improvement
                 RAW_UNRESOLVED=$(grep -c 'libartd\.so\[+' "$OUTPUT_DIR/out.folded.raw" 2>/dev/null || echo 0)
                 FINAL_UNRESOLVED=$(grep -c 'libartd\.so\[+' "$OUTPUT_DIR/out.folded" 2>/dev/null || echo 0)
                 RESOLVED_COUNT=$((RAW_UNRESOLVED - FINAL_UNRESOLVED))
                 
                 if [ "$RESOLVED_COUNT" -gt 0 ]; then
                     log "addr2line resolved $RESOLVED_COUNT additional symbols"
                 fi
                 
                 # 4. Generate SVG
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
                 log "Error: report_sample.py not found."
             fi
        else
             log "Warning: FlameGraph tools not found."
             if [ ! -f "$STACKCOLLAPSE_PY" ]; then log "  Missing: $STACKCOLLAPSE_PY"; fi
             if [ ! -f "$FLAMEGRAPH_SCRIPT" ]; then log "  Missing: $FLAMEGRAPH_SCRIPT (Please clone https://github.com/brendangregg/FlameGraph to $FLAMEGRAPH_DIR)"; fi
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