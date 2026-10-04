#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
prefix=${PREFIX:-"$HOME/.local"}
bindir=${BINDIR:-"$prefix/bin"}

echo "Building chemu with Zig 0.17..."
zig build --build-file "$project_dir/build.zig" -Doptimize=ReleaseFast --prefix "$project_dir/zig-out"

install -d "$bindir"
install -m 755 "$project_dir/zig-out/bin/ch32fun-desktop-emulator" "$bindir/chemu-core"
install -m 755 "$script_dir/chemu" "$bindir/chemu"

echo "Installed:"
echo "  $bindir/chemu"
echo "  $bindir/chemu-core"
case ":${PATH:-}:" in
    *:"$bindir":*) ;;
    *)
        echo
        echo "Add this directory to PATH:"
        echo "  export PATH=\"$bindir:\$PATH\""
        ;;
esac
