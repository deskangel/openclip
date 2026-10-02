#!/bin/bash
# Fast local development build, install to ~/Applications, and run.
#
# Builds OpenClip in Debug mode with bundle ID com.openclip.OpenClip.dev
# and installs to ~/Applications/OpenClip Dev.app so macOS TCC Accessibility
# permissions stay permanently granted and never collide with /Applications/OpenClip.app.
# Use --verbose to show the full xcodebuild output.

set -eo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

NO_INSTALL=false
FORCE_GENERATE=false
VERBOSE=false

for arg in "$@"; do
  case "$arg" in
    --no-install)
      NO_INSTALL=true
      ;;
    --generate|-g)
      FORCE_GENERATE=true
      ;;
    --verbose)
      VERBOSE=true
      ;;
    --help|-h)
      printf 'Usage: ./scripts/dev_run.sh [--no-install] [--generate] [--verbose]\n'
      printf '  --no-install  Launch from DerivedData without copying the app\n'
      printf '  --generate    Regenerate the Xcode project before building\n'
      printf '  --verbose     Show the full xcodebuild output\n'
      exit 0
      ;;
    *)
      ;;
  esac
done

# Smart xcodegen: only regenerate if project.yml is newer or forced
if [ "$FORCE_GENERATE" = true ] || [ ! -d "OpenClip.xcodeproj" ] || [ "project.yml" -nt "OpenClip.xcodeproj" ]; then
  printf 'Generating Xcode project...\n'
  xcodegen generate
fi

# Prefer Xcode-managed Apple Development signing when a local team or identity is supplied.
if [ -z "${OPENCLIP_DEV_TEAM:-}" ] && [ -z "${OPENCLIP_DEV_SIGN_IDENTITY:-}" ] && [ -f "$PROJECT_DIR/keys/dev-signing-identity" ]; then
  IFS= read -r OPENCLIP_DEV_SIGN_IDENTITY < "$PROJECT_DIR/keys/dev-signing-identity" || true
fi

SIGNING_ARGS=()
if [ -n "${OPENCLIP_DEV_TEAM:-}" ]; then
  SIGNING_ARGS+=("DEVELOPMENT_TEAM=$OPENCLIP_DEV_TEAM" "CODE_SIGN_IDENTITY=Apple Development" "CODE_SIGN_STYLE=Automatic" "-allowProvisioningUpdates")
elif [ -n "${OPENCLIP_DEV_SIGN_IDENTITY:-}" ]; then
  SIGNING_ARGS+=("CODE_SIGN_IDENTITY=$OPENCLIP_DEV_SIGN_IDENTITY" "CODE_SIGN_STYLE=Manual")
fi

DERIVED_DATA="$PROJECT_DIR/build/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/OpenClip.app"

BUILD_CMD=(
  xcodebuild
  -scheme OpenClip
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$DERIVED_DATA"
  "${SIGNING_ARGS[@]}"
  build
)

printf '\nBuilding OpenClip Dev (Debug)...\n'
printf '[1/3] Build\n'

BUILD_LOG=""
if [ "$VERBOSE" = true ]; then
  if "${BUILD_CMD[@]}"; then
    BUILD_STATUS=0
  else
    BUILD_STATUS=$?
  fi
else
  BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/openclip-build.XXXXXX")"
  if "${BUILD_CMD[@]}" >"$BUILD_LOG" 2>&1; then
    BUILD_STATUS=0
  else
    BUILD_STATUS=$?
  fi
fi

if [ "$BUILD_STATUS" -eq 0 ]; then
  printf '%s\n' '- Status: Succeeded'
  if [ -n "$BUILD_LOG" ]; then
    awk -v root="$PROJECT_DIR/" '
      function clean(line, position) {
        position = index(line, root)
        if (position) return substr(line, position + length(root))
        position = index(line, "warning:")
        if (position) return substr(line, position)
        return line
      }
      /warning:/ {
        line = clean($0)
        message = substr(line, index(line, "warning:"))
        if (!(message in warningIndex)) {
          warningIndex[message] = ++warningCount
          warnings[warningCount] = line
        }
        warningOccurrences[message]++
      }
      END {
        if (warningCount == 0) {
          printf "- Warnings: none\n"
          exit
        }
        shown = warningCount < 5 ? warningCount : 5
        printf "- Warnings: %d (%d distinct)\n", totalOccurrences, warningCount
        for (i = 1; i <= shown; i++) {
          line = warnings[i]
          message = substr(line, index(line, "warning:"))
          printf "- %s", line
          if (warningOccurrences[message] > 1) printf " (%d occurrences)", warningOccurrences[message]
          printf "\n"
        }
        if (warningCount > shown) {
          remainingOccurrences = 0
          for (i = shown + 1; i <= warningCount; i++) {
            message = substr(warnings[i], index(warnings[i], "warning:"))
            remainingOccurrences += warningOccurrences[message]
          }
          printf "- %d more distinct warnings (%d occurrences); use --verbose for full output\n", warningCount - shown, remainingOccurrences
        }
      }
      /warning:/ { totalOccurrences++ }
    ' "$BUILD_LOG"
    rm -f "$BUILD_LOG"
  fi
else
  printf '%s\n' "- Status: Failed (exit code $BUILD_STATUS)"
  if [ -n "$BUILD_LOG" ]; then
    awk -v root="$PROJECT_DIR/" '
      function clean(line, position) {
        position = index(line, root)
        if (position) return substr(line, position + length(root))
        position = index(line, "error:")
        if (position) return substr(line, position)
        position = index(line, "warning:")
        if (position) return substr(line, position)
        return line
      }
      /error:/ {
        line = clean($0)
        if (!seenErrors[line]++) errors[++errorCount] = line
      }
      /warning:/ {
        line = clean($0)
        if (!seenWarnings[line]++) warnings[++warningCount] = line
      }
      END {
        printf "- Errors: %d\n", errorCount
        for (i = 1; i <= errorCount; i++) printf "- %s\n", errors[i]
        if (warningCount) {
          printf "- Warnings: %d\n", warningCount
          for (i = 1; i <= warningCount; i++) printf "- %s\n", warnings[i]
        }
      }
    ' "$BUILD_LOG"
    rm -f "$BUILD_LOG"
  fi
  exit "$BUILD_STATUS"
fi

if [ ! -d "$BUILT_APP" ]; then
  printf 'Error: Could not find the built application at:\n  %s\n' "$BUILT_APP" >&2
  exit 1
fi

APP_TO_RUN="$BUILT_APP"

if [ "$NO_INSTALL" = false ]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
  TARGET_APP="$INSTALL_DIR/OpenClip Dev.app"

  printf '\n[2/3] Install\n'
  # Terminate old dev instance before updating the binary
  pkill -f "OpenClip Dev" 2>/dev/null || true
  sleep 0.2

  rm -rf "$TARGET_APP"
  ditto "$BUILT_APP" "$TARGET_APP"
  APP_TO_RUN="$TARGET_APP"
  printf '%s\n' '- Status: Installed'
  printf '%s\n' "- Destination: $TARGET_APP"
else
  printf '\n[2/3] Install\n'
  printf '%s\n' '- Status: Skipped (--no-install)'
  pkill -f "$BUILT_APP" 2>/dev/null || true
  sleep 0.2
fi

printf '\n[3/3] Launch\n'
/usr/bin/open -n --stdout /tmp/openclip.log --stderr /tmp/openclip.log "$APP_TO_RUN"

printf '%s\n' '- Status: Running'
printf '%s\n' "- Application: $APP_TO_RUN"
printf '%s\n' '- Bundle ID: com.openclip.OpenClip.dev'
printf '%s\n' '- Log file: /tmp/openclip.log'
printf '%s\n' '- View logs: tail -f /tmp/openclip.log'
printf '\nIf macOS requests Accessibility access, enable OpenClip Dev in\n'
printf 'System Settings > Privacy & Security > Accessibility.\n'
