#!/usr/bin/env bash
#
# Runs the test suite, adding the flags swift-testing needs when only the Command Line Tools
# are installed. With a full Xcode present (as on CI) no extra flags are needed.
#
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=()
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    CLT="/Library/Developer/CommandLineTools"
    PLUGINS="$CLT/usr/lib/swift/host/plugins/testing"
    if [ -d "$PLUGINS" ]; then
        # Without these, the @Test macro plugin is not found and Testing.framework fails to
        # dlopen at run time. Neither is needed when Xcode provides them on the default paths.
        FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
        FLAGS+=(-Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks")
        FLAGS+=(-Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib")
        echo "==> Command Line Tools detected; adding swift-testing plugin path and rpaths"
    fi
fi

exec swift test "${FLAGS[@]}" "$@"
