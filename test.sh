#!/bin/bash
./run_scimark_x86.sh --interpreter --flamegraph --perf-mmap-pages 4096
./run_scimark_x86.sh --switch-interpreter --flamegraph --perf-mmap-pages 4096
./run_scimark_x86.sh --jit --flamegraph --perf-mmap-pages 8192
