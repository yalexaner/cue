#!/bin/sh
# blocks agent edits to the frozen project file (ROADMAP 0.2):
# structural project changes are a deliberate, human-approved event
path=$(jq -r '.tool_input.file_path // empty')
case "$path" in
*.pbxproj|*.xcworkspace/*)
  echo "cue.xcodeproj is frozen (ROADMAP 0.2): stop and ask the human instead of editing the project file" >&2
  exit 2
  ;;
esac
exit 0
