#!/bin/bash

set -e

cargo build --release --target wasm32-wasi

rm -f wasm.o
wasker target/wasm32-wasi/release/echo_server_vsock.wasm
