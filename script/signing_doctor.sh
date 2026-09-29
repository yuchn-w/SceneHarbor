#!/bin/zsh
set -euo pipefail

echo "=== Available code-signing identities ==="
/usr/bin/security find-identity -v -p codesigning

echo
echo "=== Current configuration ==="

DEFAULT_SIGN_IDENTITY="-"
RESOLVED_IDENTITY="${SCENE_HARBOR_CODESIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}"

if /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -q "$RESOLVED_IDENTITY"; then
    echo "Resolved signing identity:"
    echo "$RESOLVED_IDENTITY"
elif [[ -n "${SCENE_HARBOR_CODESIGN_IDENTITY:-}" ]]; then
    echo "SCENE_HARBOR_CODESIGN_IDENTITY="
    echo "$SCENE_HARBOR_CODESIGN_IDENTITY"
else
    echo "No usable SceneHarbor signing identity is installed."
fi

if [[ "${SCENE_HARBOR_DISABLE_SESSION_PERSISTENCE:-0}" == "1" ]]; then
    echo "SCENE_HARBOR_DISABLE_SESSION_PERSISTENCE=1"
    echo "Steam session persistence: disabled"
else
    echo "Steam session persistence: enabled"
fi
