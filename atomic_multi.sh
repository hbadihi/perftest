#!/bin/bash
# Script to run multiple atomic processes with different ports
# Automatically calculates qp_start_offset per process to avoid NIC lock contention
# Usage: 
#   Server: ./atomic_multi.sh --queue_num <num> [--start_port <port>] [--num_processes <num>] [--qp_offset <offset>] [--device <device>] [--numa_node <0|1>]
#   Client: ./atomic_multi.sh --queue_num <num> --server_host <host> [--start_port <port>] [--num_processes <num>] [--qp_offset <offset>] [--device <device>] [--numa_node <0|1>]
#
# Note: When --qp_offset is specified, each process automatically gets a unique qp_start_offset
#       calculated as: process_index * queue_num * qp_offset
#       This prevents NIC page-offset lock contention between processes.

# Default values
QUEUE_NUM=""
START_PORT=4444
NUM_PROCESSES=4
SERVER_HOST=""
QP_OFFSET=""
DEVICE=""
NUMA_NODE=0

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --queue_num|-q)
            QUEUE_NUM="$2"
            shift 2
            ;;
        --start_port|-p)
            START_PORT="$2"
            shift 2
            ;;
        --num_processes|-n)
            NUM_PROCESSES="$2"
            shift 2
            ;;
        --server_host|-s)
            SERVER_HOST="$2"
            shift 2
            ;;
        --qp_offset)
            QP_OFFSET="$2"
            shift 2
            ;;
        --device|-d)
            DEVICE="$2"
            shift 2
            ;;
        --numa_node)
            NUMA_NODE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage:"
            echo "  Server: $0 --queue_num <num> [--start_port <port>] [--num_processes <num>] [--qp_offset <offset>] [--device <device>] [--numa_node <0|1>]"
            echo "  Client: $0 --queue_num <num> --server_host <host> [--start_port <port>] [--num_processes <num>] [--qp_offset <offset>] [--device <device>] [--numa_node <0|1>]"
            echo ""
            echo "Options:"
            echo "  --queue_num, -q         Number of queues (required)"
            echo "  --start_port, -p        Starting port number (default: 4444)"
            echo "  --num_processes, -n     Number of processes to spawn (default: 4)"
            echo "  --server_host, -s       Server hostname (client mode only)"
            echo "  --qp_offset             QP offset in bytes (optional, min: 8, default: page_size)"
            echo "  --device, -d            IB device to use (e.g., mlx5_0)"
            echo "  --numa_node             NUMA node to use: 0 (CPUs 0-31,64-95) or 1 (CPUs 32-63,96-127) (default: 0)"
            echo "  --help, -h              Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$QUEUE_NUM" ]; then
    echo "Error: --queue_num is required"
    echo "Use --help for usage information"
    exit 1
fi

# Generate timestamped log directory in /tmp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/atomic_logs_${TIMESTAMP}"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"
echo "Log directory: $LOG_DIR"

# Arrays to store PIDs and CPU assignments
PIDS=()
CPUS=()

# Determine if running as server or client
if [ -z "$SERVER_HOST" ]; then
    MODE="SERVER"
    echo "Running as SERVER - waiting for connections"
else
    MODE="CLIENT"
    echo "Running as CLIENT - connecting to $SERVER_HOST"
fi

echo "Starting $NUM_PROCESSES atomic processes with ports starting from $START_PORT"

# Start multiple processes with different ports
for i in $(seq 0 $((NUM_PROCESSES - 1))); do
    PORT=$((START_PORT + i))
    
    # CPU assignment based on NUMA node
    # NUMA 0: 0-31, 64-95
    # NUMA 1: 32-63, 96-127
    if [ "$NUMA_NODE" -eq 0 ]; then
        # NUMA node 0
        if [ $i -lt 32 ]; then
            CPU=$i
        else
            CPU=$((i + 32))
        fi
    else
        # NUMA node 1
        if [ $i -lt 32 ]; then
            CPU=$((i + 32))
        else
            CPU=$((i + 64))
        fi
    fi
    
    LOG_FILE="$LOG_DIR/atomic_p${PORT}.log"
    JSON_FILE="$LOG_DIR/atomic_p${PORT}.json"
    
    # Build QP offset parameter if specified
    QP_OFFSET_PARAM=""
    QP_START_OFFSET_PARAM=""
    
    if [ -n "$QP_OFFSET" ]; then
        # Validate QP offset is at least 8 bytes
        if [ "$QP_OFFSET" -lt 8 ]; then
            echo "Error: --qp_offset must be at least 8 bytes"
            exit 1
        fi
        QP_OFFSET_PARAM="--qp_offset=$QP_OFFSET"
        
        # Calculate start offset for this process to avoid NIC lock contention
        # Each process starts at: process_index * queue_num * qp_offset
        QP_START_OFFSET=$((i * QUEUE_NUM * QP_OFFSET))
        QP_START_OFFSET_PARAM="--qp_start_offset=$QP_START_OFFSET"
        
        echo "Starting process $i on port $PORT with QP offset $QP_OFFSET, start offset $QP_START_OFFSET on CPU $CPU"
    else
        echo "Starting process $i on port $PORT on CPU $CPU"
    fi
    
    # Build device parameter if specified
    DEVICE_PARAM=""
    if [ -n "$DEVICE" ]; then
        DEVICE_PARAM="-d $DEVICE"
    fi
    
    echo "  Log file: $LOG_FILE"
    echo "  JSON file: $JSON_FILE"
    
    if [ "$MODE" = "CLIENT" ]; then
        # Client mode: connect to server
        CMD="taskset -c $CPU ./ib_atomic_bw -q $QUEUE_NUM $DEVICE_PARAM $QP_OFFSET_PARAM $QP_START_OFFSET_PARAM -p $PORT -t 1 --run_infinitely --out_json --out_json_file=$JSON_FILE $SERVER_HOST"
        echo "Command: $CMD" > "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        taskset -c $CPU ./ib_atomic_bw -q $QUEUE_NUM $DEVICE_PARAM $QP_OFFSET_PARAM $QP_START_OFFSET_PARAM -p $PORT \
            -t 1 --run_infinitely --out_json --out_json_file="$JSON_FILE" \
            $SERVER_HOST >> "$LOG_FILE" 2>&1 &
    else
        # Server mode: wait for connections
        CMD="taskset -c $CPU ./ib_atomic_bw -q $QUEUE_NUM $DEVICE_PARAM $QP_OFFSET_PARAM $QP_START_OFFSET_PARAM -p $PORT -t 1 --run_infinitely --out_json --out_json_file=$JSON_FILE"
        echo "Command: $CMD" > "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        taskset -c $CPU ./ib_atomic_bw -q $QUEUE_NUM $DEVICE_PARAM $QP_OFFSET_PARAM $QP_START_OFFSET_PARAM -p $PORT \
            -t 1 --run_infinitely --out_json --out_json_file="$JSON_FILE" \
            >> "$LOG_FILE" 2>&1 &
    fi
    PIDS+=($!)
    CPUS+=($CPU)
done

echo "Started ${#PIDS[@]} processes with PIDs: ${PIDS[@]}"
echo ""
echo "CPU Assignments (taskset -c):"
for i in $(seq 0 $((NUM_PROCESSES - 1))); do
    echo "  PID ${PIDS[$i]} -> CPU ${CPUS[$i]}"
done

# Function to handle cleanup on exit
cleanup() {
    echo "Stopping all processes..."
    for pid in "${PIDS[@]}"; do
        kill $pid 2>/dev/null
    done
    exit 0
}

# Trap Ctrl+C and other termination signals
trap cleanup SIGINT SIGTERM

# Wait for all background processes
wait
