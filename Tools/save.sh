#!/bin/bash
#
# save.sh — commit the current state, with a guard.
#
#   ./Tools/save.sh "what changed"
#   ./Tools/save.sh                  # uses a timestamp
#
# The point is not convenience, it is HABIT. A safety net you have to think
# about is a safety net you skip on exactly the round that needed it.
#
# The guard is the real content. This repo's whole premise is that your Team ID,
# your bundle id and your hardware UDIDs never leave your Mac — and the only
# thing standing between that promise and a public push is .gitignore, which is
# one careless `git add -f` away from being wrong. So it is checked every time,
# and a tracked secret stops the commit rather than warning about it.
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SECRETS=(Config/Local.xcconfig Config/local.env)

leaked=0
for f in "${SECRETS[@]}"; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    echo "REFUSING TO COMMIT — $f is TRACKED. It contains machine-specific data."
    echo "  git rm --cached '$f'"
    leaked=1
  fi
done
[ $leaked -eq 1 ] && exit 1

git add -A

if git diff --cached --quiet; then
  echo "nothing to save — working tree matches HEAD"
  exit 0
fi

MSG="${1:-checkpoint $(date '+%Y-%m-%d %H:%M')}"
git commit -q -m "$MSG" || exit 1

echo "saved: $MSG"
git --no-pager log --oneline -1
CHANGED=$(git --no-pager show --stat --oneline HEAD | tail -1)
echo "  $CHANGED"

if git remote get-url origin >/dev/null 2>&1; then
  AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "?")
  echo "  $AHEAD commit(s) not yet pushed — ./Tools/save.sh push, or: git push"
else
  echo "  no remote yet — see README"
fi

# `./Tools/save.sh push` saves AND pushes, for when you want both.
if [ "${2:-}" = "push" ] || [ "${1:-}" = "push" ]; then
  git push
fi
