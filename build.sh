#!/bin/bash
# 根目录入口，等价于 native/build.sh
exec "$(dirname "$0")/native/build.sh" "$@"
