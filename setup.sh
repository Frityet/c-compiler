#!/bin/sh
# Install basic build tools
set -e
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y build-essential
fi
