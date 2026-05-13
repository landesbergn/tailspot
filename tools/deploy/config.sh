# Tailspot deploy-loop config.
# Sourced by bin/deploy, bin/log-start, bin/log-stop, bin/log-tail.
#
# To override any value locally (e.g. a different device UDID for
# someone else's clone), copy this file to tools/deploy/config.local.sh
# and edit the values there. config.local.sh is gitignored.

TAILSPOT_DEVICE_ID="B88009FD-BC73-575C-BF03-02A46C9DDC98"
TAILSPOT_DEVICE_NAME="Noah's iPhone"

TAILSPOT_SCHEME="Tailspot"
TAILSPOT_PROJECT="ios/Tailspot/Tailspot.xcodeproj"
TAILSPOT_BUNDLE_ID="com.landesberg.Tailspot"
TAILSPOT_LOG_SUBSYSTEM="com.landesberg.tailspot"

TAILSPOT_BUILD_DIR="build"
TAILSPOT_LOG_DIR="$HOME/Library/Logs/tailspot"
TAILSPOT_LOG_FILE="$TAILSPOT_LOG_DIR/device.log"
TAILSPOT_LOG_PIDFILE="$TAILSPOT_LOG_DIR/log-stream.pid"

# Optional local override (gitignored)
__cfg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$__cfg_dir/config.local.sh" ] && source "$__cfg_dir/config.local.sh"
unset __cfg_dir
