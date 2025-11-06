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
    
    with open(input_file, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.rstrip()
            
            if line.startswith('sample:'):
                # 保存前一个样本
                if current_sample and callchain:
                    samples.append((current_sample, list(reversed(callchain))))
                
                # 开始新样本
                current_sample = {}
                callchain = []
                
            elif line.startswith('  event_count:'):
                match = re.search(r'event_count:\s*(\d+)', line)
                if match:
                    current_sample['count'] = int(match.group(1))
                    
            elif line.startswith('  thread_name:'):
                match = re.search(r'thread_name:\s*(.+)', line)
                if match:
                    current_sample['thread'] = match.group(1).strip()
                    
            elif line.startswith('  symbol:'):
                match = re.search(r'symbol:\s*(.+)', line)
                if match:
                    symbol = match.group(1).strip()
                    if not current_sample.get('main_symbol'):
                        current_sample['main_symbol'] = symbol
                        
            elif line.startswith('    symbol:'):
                # 调用栈中的符号
                match = re.search(r'symbol:\s*(.+)', line)
                if match:
                    symbol = match.group(1).strip()
                    callchain.append(symbol)
        
        # 保存最后一个样本
        if current_sample and callchain:
            samples.append((current_sample, list(reversed(callchain))))
    
    return samples

def convert_to_folded(samples):
    """转换为折叠格式"""
    folded_stacks = {}
    
    for sample, callchain in samples:
        if not callchain:
            continue
            
        # 添加主符号到调用栈
        if 'main_symbol' in sample:
            full_stack = callchain + [sample['main_symbol']]
        else:
            full_stack = callchain
        
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
    print(f"解析了 {len(samples)} 个样本", file=sys.stderr)
    
    # 转换为折叠格式
    folded = convert_to_folded(samples)
    print(f"生成了 {len(folded)} 个唯一调用栈", file=sys.stderr)
    
    # 输出折叠格式
    for stack, count in sorted(folded.items(), key=lambda x: x[1], reverse=True):
        print(f"{stack} {count}")

if __name__ == '__main__':
    main()
