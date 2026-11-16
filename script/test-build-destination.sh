#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
app="$scratch/Existing.app"
mkdir "$app"
touch "$app/marker"
if output="$(KEYBOOP_BUILD_FRESH=1 KEYBOOP_BUILD_APP="$app" bash build-app.sh 2>&1)"; then
  echo "FAIL: fresh build accepted a caller-supplied path" >&2
  exit 1
fi
[[ "$output" == *"allocates its own path"* && -f "$app/marker" ]]
echo "PASS: fresh mode rejected an existing destination"
# The public checkout uses this fallback when the local private tool is absent.
if [[ ! -f Tools/keyboop-process-safety.sh ]]; then
  mkdir "$scratch/bin"
  printf '#!/bin/bash\nexit 3\n' > "$scratch/bin/pgrep"
  chmod +x "$scratch/bin/pgrep"
  if output="$(PATH="$scratch/bin:$PATH" KEYBOOP_BUILD_FRESH=0 KEYBOOP_BUILD_APP="$app" bash build-app.sh 2>&1)"; then
    echo "FAIL: replacement accepted an unknown process list" >&2
    exit 1
  fi
  [[ "$output" == *"GUI/persistent helper: ?"* && -f "$app/marker" ]]
  echo "PASS: replacement failed closed when the process lookup was unavailable"
fi
