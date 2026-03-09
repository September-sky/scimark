SciMark 使用说明（Loongson Android / ART chroot）

一、SciMark 支持哪些测试（以及用途）
  1) FFT (Fast Fourier Transform)
     用途: 频域变换计算，反映浮点运算与数组访问性能。
  2) SOR (Successive Over-Relaxation)
     用途: 迭代求解类计算，反映规则网格上的数值更新吞吐。
  3) Monte Carlo
     用途: 随机数与统计计算，反映随机数生成与简单浮点运算性能。
  4) Sparse matmult
     用途: 稀疏矩阵乘法，反映内存访问模式与稀疏数据结构处理能力。
  5) LU
     用途: LU 分解，反映线性代数类密集计算能力。
  6) Composite Score
     用途: 上述 5 项的综合分数。

说明:
  - SciMark 命令行原生参数主要是:
    1) -large: 使用更大数据集
    2) <min_time>: 每个子测试最短运行时长（秒），如 1.0、2.0
       处理方式: 不是“整套再跑一遍”，而是每个子测试在内部按 1,2,4,8... 次循环加倍，
       直到该子测试耗时达到 min_time，再用该次结果计分。
       如果要整套重复跑多轮，请使用脚本参数 -n/--iterations。

二、当前目标设备支持情况（实测日期: 2026-03-09）
  1) 已验证可稳定运行（推荐默认）
     - 解释器模式: ./run_scimark_la.sh --interpreter -- 1.0 或 2.0
     - JIT 模式: ./run_scimark_la.sh --jit -- 1.0 或 2.0
     - large 数据集: ./run_scimark_la.sh --jit -- -large 1.0（可运行但耗时明显增加）
  2) FlameGraph 可用性
     - JIT + fp: 可生成且可读性最好（推荐）
     - Interpreter + fp: 可生成，但常见主热点被 dexfile_in_memory 偏移主导，图可读性较弱
     - dwarf 展开: 在当前设备上不稳定，容易出现 "cfa is not set to a register" 报错
  3) 已知限制
     - 当前环境通常找不到 perf-*.map，JIT 相关符号可能不完整
     - 即使开启后处理，仍可能有少量 libartd.so[+offset] 或 unknown 残留

三、目标设备脚本用法
  1) 基本格式
     ./run_scimark_la.sh [脚本参数] -- [SciMark 参数]
  2) 常用脚本参数
     --interpreter              解释器模式（默认）
     --switch-interpreter       switch 解释器模式
     --jit                      JIT 模式
     --jit-baseline             JIT baseline 模式
     --jit-on-first-use         JIT 阈值设为 0
     -n, --iterations N         迭代次数
     --flamegraph               开启 simpleperf + 火焰图
     --flamegraph-output PATH   指定火焰图输出路径
     --perf-frequency HZ        采样频率（默认 1000）
     --fp                       使用 frame pointer 展开（推荐）
     --no-unwind                不做栈展开（仅热点，不看调用链）
     --post-unwind              录制后展开
     --keep-failed-unwind       保留失败展开调试信息
     --max-addr2line N          限制 addr2line 解析数量（默认 300）
     --compiler-debug           打开 cfg/disassemble/verbose-methods 调试输出
     -o, --output DIR           结果目录
     -v, --verbose              打印详细命令

四、已验证可用命令
  1) 快速冒烟（解释器）
     ./run_scimark_la.sh --interpreter -- 1.0
  2) 稳定性能跑分（JIT，推荐）
     ./run_scimark_la.sh --jit -- 2.0
  3) 推荐火焰图（JIT，推荐）
     ./run_scimark_la.sh --jit --flamegraph --fp --perf-frequency 400 -- 2.0
  4) 解释器火焰图（可用但可读性一般）
     ./run_scimark_la.sh --interpreter --flamegraph --fp --perf-frequency 400 -- 1.0
  5) 需要编译器 CFG / 反汇编时
     ./run_scimark_la.sh --jit --compiler-debug --flamegraph --fp -- 2.0

五、结果目录与产物
  1) 默认输出目录
     ./device-perf-result/<时间戳>-<模式>/
  2) 常见文件
     perf.data             原始采样数据
     report_symbol.txt     按符号统计的文本报告
     report_callgraph.txt  调用链文本报告
     out.perf              report_sample 产物
     out.folded            折叠栈（用于火焰图）
     flamegraph.svg        火焰图
     run.log               本次运行日志

六、实测建议
  1) 如果目标是“看业务热点”，优先使用 JIT + fp 火焰图。
  2) 如果目标是“排查解释器路径”，可用 interpreter + fp，但需接受图可读性下降。
  3) 如果火焰图后处理耗时过长，可降低 --max-addr2line（例如 80）。
