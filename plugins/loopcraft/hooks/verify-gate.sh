#!/usr/bin/env bash
# loopcraft deterministic lint gate (PostToolUse on Edit/Write/MultiEdit).
# Opt-in PER REPO: only acts when the repo root has a .loopcraft.json with a
# "lintCommand". Otherwise a no-op, so installing loopcraft never disrupts
# unrelated repos. Keep lintCommand FAST (e.g. lint the changed/staged files),
# since it runs after every edit. On failure it exits 2 to hand the lint
# errors back to Claude to fix before continuing.

cat >/dev/null 2>&1 || true   # consume the hook's JSON stdin payload

cfg=".loopcraft.json"
[ -f "$cfg" ] || exit 0

lint_cmd=""
if command -v python3 >/dev/null 2>&1; then
  lint_cmd="$(python3 -c 'import json;print(json.load(open(".loopcraft.json")).get("lintCommand",""))' 2>/dev/null)"
elif command -v node >/dev/null 2>&1; then
  lint_cmd="$(node -e 'try{process.stdout.write(((require("./.loopcraft.json")||{}).lintCommand)||"")}catch(e){}' 2>/dev/null)"
fi
[ -n "$lint_cmd" ] || exit 0

if out="$(eval "$lint_cmd" 2>&1)"; then
  exit 0
fi

{
  echo "loopcraft lint gate: \`$lint_cmd\` failed — fix the lint/type errors before continuing:"
  echo "$out" | tail -60
} >&2
exit 2
