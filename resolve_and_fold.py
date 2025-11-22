#!/usr/bin/env python3
"""
解析 simpleperf report-sample 输出，并在主机端解析符号，最后生成折叠堆栈
"""
import sys
import re
import os
import subprocess
from collections import defaultdict

# 配置
LLVM_SYMBOLIZER_PATH = "/home/yanxi/loongson/aosp15.la/prebuilts/clang/host/linux-x86/clang-r530567b/bin/llvm-symbolizer"
SYMBOLS_DIR = "/home/yanxi/loongson/aosp15.la/out/target/product/loongson_3a5000/symbols"

def parse_simpleperf_output(input_file):
    """解析 simpleperf report-sample 的输出"""
    samples = []
    current_sample = None
    callchain = []
    in_callchain = False
    
    # 统计
    total_lines = 0
    
    with open(input_file, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            total_lines += 1
            line_stripped = line.strip()
            
            if line.startswith('sample:'):
                # 保存前一个样本
                if current_sample:
                    # 如果 callchain 为空，尝试使用 main_symbol
                    if not callchain and current_sample.get('main_frame'):
                        callchain = [current_sample['main_frame']]
                    
                    if callchain:
                        # simpleperf callchain 是 leaf -> root (通常)
                        # 但 report-sample 输出的顺序是从顶到底?
                        # 让我们检查一下 raw output.
                        # sample:
                        #   symbol: leaf
                        #   callchain:
                        #     symbol: caller (root-ward)
                        # 所以是 leaf -> root.
                        # FlameGraph 需要 root -> leaf.
                        stack = list(reversed(callchain))
                        samples.append({'count': current_sample.get('count', 1), 'stack': stack})
                
                # 开始新样本
                current_sample = {}
                callchain = []
                in_callchain = False
                
            elif line_stripped.startswith('event_count:'):
                match = re.search(r'event_count:\s*(\d+)', line)
                if match:
                    current_sample['count'] = int(match.group(1))
            
            elif line_stripped.startswith('callchain:'):
                in_callchain = True
                
            elif line_stripped.startswith('vaddr_in_file:'):
                # 这是一个新的 frame (在 callchain 中或 main symbol)
                # 我们需要收集 vaddr, file, symbol
                # 但是 report-sample 的输出格式是多行的:
                # vaddr_in_file: ...
                # file: ...
                # symbol: ...
                # 我们需要一个临时对象来保存当前 frame
                pass

            # 简单的状态机来解析 frame
            # 假设 vaddr_in_file, file, symbol 总是按顺序出现
            
    # 重新实现解析逻辑，因为多行属性比较麻烦
    return parse_simpleperf_output_v2(input_file)

def parse_simpleperf_output_v2(input_file):
    samples = []
    current_sample = {}
    current_stack = [] # list of frames
    
    # Frame 属性
    current_frame = {}
    
    in_callchain = False
    
    with open(input_file, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line_stripped = line.strip()
            
            if line.startswith('sample:'):
                # 保存旧样本
                if current_sample:
                    # 如果没有 callchain，把 main frame 放入 stack
                    if not current_stack and current_frame:
                         current_stack.append(current_frame)
                    
                    if current_stack:
                        # 翻转 stack: leaf->root => root->leaf
                        samples.append({'count': current_sample.get('count', 1), 'stack': list(reversed(current_stack))})
                
                # 重置
                current_sample = {'count': 1}
                current_stack = []
                current_frame = {}
                in_callchain = False
                
            elif line_stripped.startswith('event_count:'):
                match = re.search(r'event_count:\s*(\d+)', line)
                if match:
                    current_sample['count'] = int(match.group(1))
            
            elif line_stripped.startswith('callchain:'):
                in_callchain = True
                # 如果之前有 main frame (在 callchain 之前解析的)，加入 stack
                if current_frame:
                    current_stack.append(current_frame)
                    current_frame = {}

            elif line_stripped.startswith('vaddr_in_file:'):
                # 新 frame 开始 (或者 main frame 的属性)
                # 如果 current_frame 已经有数据(比如上一个 frame 完成)，先保存
                if current_frame.get('vaddr'): 
                    current_stack.append(current_frame)
                    current_frame = {}
                
                match = re.search(r'vaddr_in_file:\s*([0-9a-fA-F]+)', line)
                if match:
                    current_frame['vaddr'] = match.group(1)

            elif line_stripped.startswith('file:'):
                match = re.search(r'file:\s*(.+)', line)
                if match:
                    current_frame['file'] = match.group(1).strip()

            elif line_stripped.startswith('symbol:'):
                match = re.search(r'symbol:\s*(.+)', line)
                if match:
                    current_frame['symbol'] = match.group(1).strip()
        
        # 最后一个样本
        if current_sample:
             if current_frame:
                 current_stack.append(current_frame)
             if current_stack:
                 samples.append({'count': current_sample.get('count', 1), 'stack': list(reversed(current_stack))})

    print(f"解析了 {len(samples)} 个样本", file=sys.stderr)
    return samples

def resolve_symbols(samples):
    to_resolve = defaultdict(set)
    for sample in samples:
        for frame in sample['stack']:
            f = frame.get('file')
            v = frame.get('vaddr')
            if f and v and f.startswith('/') and 'lib' in f:
                to_resolve[f].add(v)
    
    print(f"需要解析的文件数: {len(to_resolve)}", file=sys.stderr)
    
    resolved_cache = {}
    
    for file_path, vaddrs in to_resolve.items():
        # 映射路径
        rel_path = file_path
        if rel_path.startswith('/'):
            rel_path = rel_path[1:]
        
        local_path = os.path.join(SYMBOLS_DIR, rel_path)
        
        if not os.path.exists(local_path):
            # 尝试搜索文件
            filename = os.path.basename(file_path)
            found = False
            # 简单的启发式搜索：在 SYMBOLS_DIR 下查找同名文件
            # 优先匹配路径末尾部分
            candidates = []
            for root, dirs, files in os.walk(SYMBOLS_DIR):
                if filename in files:
                    candidates.append(os.path.join(root, filename))
            
            if candidates:
                # 找一个最像的 (路径后缀匹配最长)
                # 这里简单取第一个，或者如果有 com.android.art.testing 且原路径是 com.android.art，则匹配
                # 实际上，只要找到一个 unstripped 的通常就行
                local_path = candidates[0]
                print(f"使用替代路径: {local_path} (原: {file_path})", file=sys.stderr)
                found = True
            
            if not found:
                print(f"跳过(未找到): {local_path}", file=sys.stderr)
                continue
            
        print(f"解析符号: {os.path.basename(local_path)} ({len(vaddrs)} addrs)", file=sys.stderr)
        
        vaddr_list = sorted(list(vaddrs))
        # 转换为 hex 字符串列表 (带 0x)
        input_str = '\n'.join(['0x' + v for v in vaddr_list])
        
        try:
            # 使用 --inlining=false 保持 1对1 (或者接近)
            cmd = [LLVM_SYMBOLIZER_PATH, '--obj=' + local_path, '--inlining=false', '--functions=linkage', '--demangle']
            process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            stdout, stderr = process.communicate(input=input_str)
            
            lines = stdout.strip().split('\n')
            # 每两个一行: Function, File:Line
            
            # 建立映射
            # 注意：如果 llvm-symbolizer 输出行数不匹配，可能会错位。
            # 通常它是可靠的。
            if len(lines) >= len(vaddr_list) * 2:
                for i, vaddr in enumerate(vaddr_list):
                    func_name = lines[i*2]
                    if func_name != '??':
                        resolved_cache[(file_path, vaddr)] = func_name
                        
        except Exception as e:
            print(f"执行 llvm-symbolizer 失败: {e}", file=sys.stderr)
            
    return resolved_cache

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <raw_output_file>", file=sys.stderr)
        sys.exit(1)
        
    input_file = sys.argv[1]
    samples = parse_simpleperf_output_v2(input_file)
    resolved = resolve_symbols(samples)
    
    folded = defaultdict(int)
    for sample in samples:
        stack_syms = []
        for frame in sample['stack']:
            key = (frame.get('file'), frame.get('vaddr'))
            if key in resolved:
                stack_syms.append(resolved[key])
            else:
                # Fallback
                sym = frame.get('symbol', 'unknown')
                if sym == 'unknown' and frame.get('file'):
                     # 尝试用文件名+偏移
                     sym = f"{os.path.basename(frame['file'])}[+{frame.get('vaddr')}]"
                stack_syms.append(sym)
        
        if stack_syms:
            stack_str = ';'.join(stack_syms)
            folded[stack_str] += sample['count']
            
    for stack, count in sorted(folded.items(), key=lambda x: x[1], reverse=True):
        print(f"{stack} {count}")

if __name__ == '__main__':
    main()
