#!/bin/bash
set -x
taskset -c 0 ./ib_write_bw --write_with_imm -q $1 --run_infinitely
