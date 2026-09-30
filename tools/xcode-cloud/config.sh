# Xcode Cloud CLI config. Sourced by bin/xcode-cloud-build.
#
# The App Store Connect API key is a SECRET and never lives in this file.
# Put the three values in ~/.config/tailspot/xcode-cloud.sh (outside the
# repo, so every worktree sees it) or in tools/xcode-cloud/config.local.sh
# (gitignored, per checkout). The repo-local file wins if both exist.
#
#   ASC_ISSUER_ID="<issuer uuid>"          # App Store Connect → Users and Access → Integrations → App Store Connect API
#   ASC_KEY_ID="<10-char key id>"
#   ASC_KEY_PATH="$HOME/.appstoreconnect/AuthKey_<key id>.p8"   # downloadable ONCE, at key creation
#
# Key role: App Manager. (Developer keys can read Xcode Cloud state but
# cannot start builds.) Environment variables of the same names override
# both files.

TAILSPOT_BUNDLE_ID="${TAILSPOT_BUNDLE_ID:-com.landesberg.Tailspot}"
XCODE_CLOUD_DEFAULT_BRANCH="${XCODE_CLOUD_DEFAULT_BRANCH:-main}"

__cfg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__cfg_home="${XDG_CONFIG_HOME:-$HOME/.config}/tailspot/xcode-cloud.sh"
[ -f "$__cfg_home" ] && source "$__cfg_home"
[ -f "$__cfg_dir/config.local.sh" ] && source "$__cfg_dir/config.local.sh"
unset __cfg_dir __cfg_home
