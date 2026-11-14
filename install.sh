#!/bin/sh
# Install sbx: link the script into ~/.local/bin and seed the config dir.
set -e

here=$(cd "$(dirname "$0")" && pwd)
bin="${BIN_DIR:-$HOME/.local/bin}"
conf="${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox"

mkdir -p "$bin" "$conf"
chmod +x "$here/sbx"

ln -sf "$here/sbx" "$bin/sbx"
printf 'linked %s -> %s\n' "$bin/sbx" "$here/sbx"

for f in allow-read.txt allow-rw.txt; do
  if [ -f "$conf/$f" ]; then
    printf 'kept   %s (already exists)\n' "$conf/$f"
  else
    cp "$here/examples/$f" "$conf/$f"
    printf 'wrote  %s\n' "$conf/$f"
  fi
done

case ":$PATH:" in
  *":$bin:"*) ;;
  *) printf '\nnote: %s is not on PATH\n' "$bin" ;;
esac

printf '\ntry: cd <some repo> && sbx --print pi\n'
