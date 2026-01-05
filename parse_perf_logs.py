#!/usr/bin/env python3
"""
Parse perftest JSON logs and calculate performance statistics.

Usage:
    python3 parse_perf_logs.py <log_directory>
    
Example:
    python3 parse_perf_logs.py /tmp/atomic_logs_20260105_163149
"""

import json
import sys
import os
import glob
from pathlib import Path


def parse_json_file(filepath):
    """Extract the last BW_average and MsgRate from a JSON file."""
    try:
        with open(filepath, 'r') as f:
            content = f.read()
            
        # Find all occurrences of BW_average and MsgRate
        bw_values = []
        msgrate_values = []
        
        # Parse line by line to handle multiple JSON objects
        for line in content.split('\n'):
            line = line.strip()
            if not line:
                continue
                
            try:
                data = json.loads(line)
                if 'BW_average' in data:
                    bw_values.append(float(data['BW_average']))
                if 'MsgRate' in data:
                    msgrate_values.append(float(data['MsgRate']))
            except json.JSONDecodeError:
                # Try to extract values using string search as fallback
                if '"BW_average"' in line:
                    try:
                        bw_str = line.split('"BW_average"')[1].split(':')[1].split(',')[0].strip()
                        bw_values.append(float(bw_str))
                    except:
                        pass
                if '"MsgRate"' in line:
                    try:
                        msgrate_str = line.split('"MsgRate"')[1].split(':')[1].split(',')[0].split('}')[0].strip()
                        msgrate_values.append(float(msgrate_str))
                    except:
                        pass
        
        # Return the last values found
        if bw_values and msgrate_values:
            return bw_values[-1], msgrate_values[-1]
        
    except Exception as e:
        print(f"Warning: Error parsing {filepath}: {e}", file=sys.stderr)
    
    return None, None


def parse_log_directory(log_dir):
    """Parse all JSON files in the log directory."""
    log_path = Path(log_dir)
    
    if not log_path.exists():
        print(f"Error: Directory '{log_dir}' does not exist", file=sys.stderr)
        sys.exit(1)
    
    if not log_path.is_dir():
        print(f"Error: '{log_dir}' is not a directory", file=sys.stderr)
        sys.exit(1)
    
    # Find all JSON files
    json_files = sorted(glob.glob(os.path.join(log_dir, "*.json")))
    
    if not json_files:
        print(f"Error: No JSON files found in '{log_dir}'", file=sys.stderr)
        sys.exit(1)
    
    results = []
    
    for json_file in json_files:
        filename = os.path.basename(json_file)
        bw, msgrate = parse_json_file(json_file)
        
        if bw is not None and msgrate is not None:
            results.append({
                'filename': filename,
                'bw': bw,
                'msgrate': msgrate
            })
    
    return results


def print_summary(results, log_dir):
    """Print performance summary statistics."""
    if not results:
        print("No valid performance data found in JSON files")
        return
    
    print()
    print("=" * 60)
    print("Performance Summary")
    print("=" * 60)
    print(f"Log Directory: {log_dir}")
    print(f"Files analyzed: {len(results)}")
    print()
    
    # Calculate totals
    total_bw = sum(r['bw'] for r in results)
    total_msgrate = sum(r['msgrate'] for r in results)
    
    # Calculate averages
    avg_bw = total_bw / len(results)
    avg_msgrate = total_msgrate / len(results)
    
    # Print per-file results
    print("Per-Process Results:")
    print("-" * 60)
    for i, result in enumerate(results):
        print(f"  {result['filename']:30s}  "
              f"BW: {result['bw']:8.2f} MB/s  "
              f"MsgRate: {result['msgrate']:10.6f} Mpps")
    
    print()
    print("-" * 60)
    print(f"Total Bandwidth:          {total_bw:10.2f} MB/s")
    print(f"Total Message Rate:       {total_msgrate:10.6f} Mpps")
    print()
    print(f"Average Bandwidth:        {avg_bw:10.2f} MB/s")
    print(f"Average Message Rate:     {avg_msgrate:10.6f} Mpps")
    print("-" * 60)
    print(f"Number of Processes:      {len(results)}")
    print("=" * 60)
    print()


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 parse_perf_logs.py <log_directory>")
        print()
        print("Example:")
        print("  python3 parse_perf_logs.py /tmp/atomic_logs_20260105_163149")
        sys.exit(1)
    
    log_dir = sys.argv[1]
    
    # Parse all JSON files in the directory
    results = parse_log_directory(log_dir)
    
    # Print summary
    print_summary(results, log_dir)


if __name__ == "__main__":
    main()
