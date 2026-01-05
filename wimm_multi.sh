#!/bin/bash
# Script to run multiple write_with_imm processes with different ports
# Usage:
#   Server: ./wimm_multi.sh <queue_num> [start_port] [num_processes] [qp_offset_start]
#   Client: ./wimm_multi.sh <queue_num> <start_port> <num_processes> <server_host> [qp_offset_start]


QUEUE_NUM=$1
START_PORT=${2:-4444}
NUM_PROCESSES=${3:-4}
MSG_SIZE=8  # Fixed message size: 8 bytes
INLINE_SIZE=16  # Inline data size: 16 bytes (minimum required)

# Detect if 4th parameter is a hostname (client mode) or a number
if [ -n "$4" ] && [ "$4" != "${4//[a-zA-Z.-]/}" ]; then
    # Contains letters, dots, or hyphens - likely a hostname
    SERVER_HOST=$4
    QP_OFFSET_START=$5
else
    # Numeric or empty - server mode with optional parameters
    SERVER_HOST=""
    QP_OFFSET_START=$4
fi

# Generate timestamped log directory in /tmp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/tmp/wimm_logs_${TIMESTAMP}"

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

echo "Starting $NUM_PROCESSES write_with_imm processes with ports starting from $START_PORT"

# Start multiple processes with different ports
for i in $(seq 0 $((NUM_PROCESSES - 1))); do
    PORT=$((START_PORT + i))
    CPU=$((i * 2))  # Use even CPU cores: 0, 2, 4, 6, etc.
    LOG_FILE="$LOG_DIR/wimm_p${PORT}.log"
    JSON_FILE="$LOG_DIR/wimm_p${PORT}.json"
    
    # Build QP offset parameter if specified
    QP_OFFSET_PARAM=""
    if [ -n "$QP_OFFSET_START" ]; then
        QP_OFFSET=$((QP_OFFSET_START + i * 16))  # Increment QP offset for each process
        QP_OFFSET_PARAM="--qp_offset=$QP_OFFSET"
        echo "Starting process $i on port $PORT with QP offset $QP_OFFSET, msg size ${MSG_SIZE}B (inline ${INLINE_SIZE}B) on CPU $CPU"
    else
        echo "Starting process $i on port $PORT, msg size ${MSG_SIZE}B (inline ${INLINE_SIZE}B) on CPU $CPU"
    fi
    echo "  Log file: $LOG_FILE"
    echo "  JSON file: $JSON_FILE"
    
    if [ "$MODE" = "CLIENT" ]; then
        # Client mode: connect to server
        CMD="taskset -c $CPU ./ib_write_bw --write_with_imm -I $INLINE_SIZE -q $QUEUE_NUM -s $MSG_SIZE $QP_OFFSET_PARAM -p $PORT -t 1 --run_infinitely --out_json --out_json_file=$JSON_FILE $SERVER_HOST"
        echo "Command: $CMD" > "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        taskset -c $CPU ./ib_write_bw --write_with_imm -I $INLINE_SIZE -q $QUEUE_NUM -s $MSG_SIZE $QP_OFFSET_PARAM -p $PORT \
            -t 1 --run_infinitely --out_json --out_json_file="$JSON_FILE" \
            $SERVER_HOST >> "$LOG_FILE" 2>&1 &
    else
        # Server mode: wait for connections
        CMD="taskset -c $CPU ./ib_write_bw --write_with_imm -I $INLINE_SIZE -q $QUEUE_NUM -s $MSG_SIZE $QP_OFFSET_PARAM -p $PORT -t 1 --run_infinitely --out_json --out_json_file=$JSON_FILE"
        echo "Command: $CMD" > "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        taskset -c $CPU ./ib_write_bw --write_with_imm -I $INLINE_SIZE -q $QUEUE_NUM -s $MSG_SIZE $QP_OFFSET_PARAM -p $PORT \
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
