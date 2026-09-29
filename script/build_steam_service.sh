#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
PROJECT="$ROOT_DIR/SteamService/MirageSteamService.csproj"
PUBLISH_DIR="$ROOT_DIR/SteamService/publish/osx-arm64"
DOTNET_BIN="${DOTNET_BIN:-$(command -v dotnet || true)}"
DOTNET_ROOT_VALUE="${DOTNET_ROOT:-/opt/homebrew/opt/dotnet/libexec}"

if [[ -z "$DOTNET_BIN" ]]; then
    print -u2 "找不到 dotnet；SceneHarbor 仍可建置影片與本機 Scene/Web 播放功能。"
    exit 2
fi
if [[ ! -f "$PROJECT" ]]; then
    print -u2 "找不到 SteamService 專案：$PROJECT"
    exit 2
fi

mkdir -p /private/tmp/scene-harbor-dotnet-home
env \
    DOTNET_CLI_HOME=/private/tmp/scene-harbor-dotnet-home \
    DOTNET_ROOT="$DOTNET_ROOT_VALUE" \
    "$DOTNET_BIN" publish "$PROJECT" \
    -c Release \
    -r osx-arm64 \
    --self-contained true \
    -o "$PUBLISH_DIR" \
    -p:PublishSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true \
    -p:DebugType=None \
    -p:DebugSymbols=false

SERVICE="$PUBLISH_DIR/SceneHarborSteamService"
chmod +x "$SERVICE"
print "$SERVICE"
