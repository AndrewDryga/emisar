#!/bin/sh
set -eu
umask 022

java -Xms32m -Xmx64m -XX:+UseSerialGC -XX:ActiveProcessorCount=1 -cp /fixture PerfFixture normal &
normal_pid=$!
java -Xms32m -Xmx64m -XX:+UseSerialGC -XX:ActiveProcessorCount=1 -XX:+PerfDisableSharedMem -cp /fixture PerfFixture no_shared &
no_shared_pid=$!
java -Xms32m -Xmx64m -XX:+UseSerialGC -XX:ActiveProcessorCount=1 -XX:-UsePerfData -cp /fixture PerfFixture no_data &
no_data_pid=$!

cleanup() {
    kill "$normal_pid" "$no_shared_pid" "$no_data_pid" 2>/dev/null || true
    wait "$normal_pid" "$no_shared_pid" "$no_data_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' INT TERM
wait "$normal_pid"
