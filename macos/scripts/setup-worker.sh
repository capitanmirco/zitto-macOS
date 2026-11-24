#!/bin/bash
# Prepares what separates the songs: a Python environment with zitto, PyTorch (on the GPU of
# the Mac through Metal) and the libraries of the models. Safe to run again to update.
#
# Needs Python 3.11 or later and ffmpeg, for example from Homebrew:
#     brew install python@3.12 ffmpeg
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
place="$HOME/Library/Application Support/zitto"
python="${PYTHON:-$(command -v python3.12 || command -v python3.13 || command -v python3.11 || command -v python3)}"

"$python" -c 'import sys; sys.exit(sys.version_info < (3, 11))' || {
    echo "Python 3.11 or later is needed: brew install python@3.12"; exit 1; }
command -v ffmpeg >/dev/null || echo "Warning: ffmpeg is missing. Install it with: brew install ffmpeg"

mkdir -p "$place"
if [ ! -x "$place/venv/bin/python3" ]; then
    "$python" -m venv "$place/venv"
fi
"$place/venv/bin/python3" -m pip install --upgrade pip
"$place/venv/bin/python3" -m pip install --upgrade -r "$here/requirements-macos.txt"
"$place/venv/bin/python3" -m pip install --no-deps -e "$here"
"$place/venv/bin/python3" -c 'import torch; print("GPU of the Mac:", torch.backends.mps.is_available())'
echo
echo "Ready. Build the app with macos/scripts/build-app.sh"
