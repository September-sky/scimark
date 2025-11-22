#!/usr/bin/env python3
"""
将 simpleperf report-sample 的输出转换为 FlameGraph 折叠格式
"""
import sys
import re

def parse_simpleperf_output(input_file):
    """解析 simpleperf report-sample 的输出"""
    samples = []
    current_sample = None
    callchain = []
    in_callchain = False
    
    # 统计信息
    total_lines = 0
    sample_count = 0
    
    with open(input_file, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            total_lines += 1
            line_stripped = line.strip()
            
            if line.startswith('sample:'):
                # 保存前一个样本
                if current_sample:
                    # 如果 callchain 为空，尝试使用 main_symbol
                    if not callchain and current_sample.get('main_symbol'):
                        callchain = [current_sample['main_symbol']]
                    
                    if callchain:
                        # simpleperf callchain 通常是 leaf -> root
                        # FlameGraph 需要 root -> leaf
                        stack = list(reversed(callchain))
                        samples.append((current_sample, stack))
                
                # 开始新样本
                current_sample = {}
                callchain = []
                in_callchain = False
                sample_count += 1
                
            elif line_stripped.startswith('event_count:'):
                match = re.search(r'event_count:\s*(\d+)', line)
                if match:
                    current_sample['count'] = int(match.group(1))
                    
            elif line_stripped.startswith('thread_name:'):
                match = re.search(r'thread_name:\s*(.+)', line)
                if match:
                    current_sample['thread'] = match.group(1).strip()
            
            elif line_stripped.startswith('callchain:'):
                in_callchain = True
                
            elif line_stripped.startswith('symbol:'):
                match = re.search(r'symbol:\s*(.+)', line)
                if match:
                    symbol = match.group(1).strip()
                    if in_callchain:
                        callchain.append(symbol)
                    else:
                        if not current_sample.get('main_symbol'):
                            current_sample['main_symbol'] = symbol
        
        # 保存最后一个样本
        if current_sample:
             if not callchain and current_sample.get('main_symbol'):
                callchain = [current_sample['main_symbol']]
             if callchain:
                stack = list(reversed(callchain))
                samples.append((current_sample, stack))
    
    print(f"处理了 {total_lines} 行", file=sys.stderr)
    print(f"发现 {sample_count} 个样本标记", file=sys.stderr)
    print(f"成功解析 {len(samples)} 个有效样本 (含调用栈)", file=sys.stderr)
    
    return samples

def convert_to_folded(samples):
    """转换为折叠格式"""
    folded_stacks = {}
    
    for sample, full_stack in samples:
        if not full_stack:
            continue
            
        # 检查是否需要添加 main_symbol
        # 如果栈顶不是 main_symbol，且 main_symbol 存在，则添加
        # 注意：full_stack 是 root -> leaf
        if 'main_symbol' in sample:
            main_sym = sample['main_symbol']
            if full_stack[-1] != main_sym:
                # 只有当栈顶不匹配 main_symbol 时才添加，避免重复
                full_stack.append(main_sym)
        
        # 创建折叠的栈字符串
        stack_str = ';'.join(full_stack)
        count = sample.get('count', 1)
        
        # 累加相同栈的计数
        if stack_str in folded_stacks:
            folded_stacks[stack_str] += count
        else:
            folded_stacks[stack_str] = count
    
    return folded_stacks

def main():
    if len(sys.argv) < 2:
        print(f"用法: {sys.argv[0]} <simpleperf-output-file>", file=sys.stderr)
        sys.exit(1)
    
    input_file = sys.argv[1]
    
    # 解析样本
    samples = parse_simpleperf_output(input_file)
    
    # 转换为折叠格式
    folded = convert_to_folded(samples)
    print(f"生成了 {len(folded)} 个唯一调用栈", file=sys.stderr)
    
    # 输出折叠格式
    for stack, count in sorted(folded.items(), key=lambda x: x[1], reverse=True):
        print(f"{stack} {count}")

if __name__ == '__main__':
    main()
