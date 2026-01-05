#!/bin/bash
set -x
taskset -c 2 ./ib_atomic_bw -q $1  --qp_offset=8 -p $2 --run_infinitely
