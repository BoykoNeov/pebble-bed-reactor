#!/usr/bin/env bash
# Run the headless test suite.
#
#   tests/run_tests.sh            # the pure sim/ gates (fast, no scene): tests/test_*.gd
#   tests/run_tests.sh --live     # ...plus the curated live-scene harnesses (minutes)
#   tests/run_tests.sh --all      # ...plus every tests/live_*.gd that runs headless
#
# GODOT names the binary (default: `godot` on PATH). Every script is a SceneTree that
# quits with its failure count as the exit code, so this just runs them in turn and
# reports. The first run after a checkout imports the project (creates .godot/).
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"

mode="pure"
case "${1:-}" in
  --live) mode="live" ;;
  --all)  mode="all" ;;
  "") ;;
  *) echo "usage: $0 [--live|--all]" >&2; exit 2 ;;
esac

if [ ! -d .godot ]; then
  "$GODOT" --headless --path . --import --quit >/dev/null 2>&1 || true
fi

scripts=(tests/test_*.gd)
# The live set that guards the physics end-to-end on the real scene (the render_*
# harnesses need a real renderer and are excluded; long_session takes 10 minutes).
if [ "$mode" = "live" ]; then
  scripts+=(tests/live_m4.gd tests/live_scram.gd tests/live_rods.gd tests/live_xenon.gd tests/live_radius.gd)
elif [ "$mode" = "all" ]; then
  for f in tests/live_*.gd; do
    case "$f" in tests/live_render_*) ;; *) scripts+=("$f") ;; esac
  done
fi

failed=()
for s in "${scripts[@]}"; do
  echo "===== $s"
  "$GODOT" --headless --path . --script "res://$s" 2>&1 | grep -v '^Godot Engine v'
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then failed+=("$s ($rc)"); fi
done

echo
if [ ${#failed[@]} -eq 0 ]; then
  echo "ALL ${#scripts[@]} SUITES PASSED"
else
  echo "${#failed[@]} SUITE(S) FAILED:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
