#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
python3 "$repo_root/script/fetch_public_runtime.py"
