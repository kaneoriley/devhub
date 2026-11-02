#!/bin/sh
# Runs independently of DevHub. All building/staging/signature checks finish before launch.
set -eu
PARENT_PID="$1"
STAGING="$2"
DESTINATION="$3"
RESULT="$4"
BACKUP="$STAGING/previous.app"
NEW="$STAGING/DevHub.app"

finish() {
  code=$?
  trap - EXIT
  if [ "$code" -ne 0 ]; then
    if [ -d "$BACKUP" ]; then
      rm -rf "$DESTINATION"
      mv "$BACKUP" "$DESTINATION"
    fi
    printf 'DevHub could not finish installing. Reopen Check for Updates and try again.\n' > "$RESULT"
    /usr/bin/open "$DESTINATION" || true
  fi
  rm -rf "$STAGING"
  exit "$code"
}
trap finish EXIT

# Don't replace the executable while its original process is still running.
attempt=0
while kill -0 "$PARENT_PID" 2>/dev/null; do
  attempt=$((attempt + 1))
  # A modal sheet can veto AppKit's normal quit. This helper exists solely for
  # this app's requested restart, so ensure that its original process exits.
  if [ "$attempt" -eq 10 ]; then kill -TERM "$PARENT_PID" 2>/dev/null || true; fi
  if [ "$attempt" -ge 300 ]; then
    printf 'DevHub did not quit in time. Installation was cancelled.\n' > "$RESULT"
    trap - EXIT
    rm -rf "$STAGING"
    exit 1
  fi
  sleep 0.2
done

/usr/bin/codesign --verify --strict "$NEW"
if [ -e "$DESTINATION" ]; then mv "$DESTINATION" "$BACKUP"; fi
mv "$NEW" "$DESTINATION"
/usr/bin/open "$DESTINATION"
rm -f "$RESULT"
