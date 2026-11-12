#!/bin/zsh
# dump.sh <pid> <addr> <len> [out.bin] — read another process's memory and
# write it to a file (then disassemble it with the true addresses).
#
# 32-bit code a packer generates at run time exists nowhere in the file, so
# the only copy of a protector's VM handler is the live process.  mem.exe
# writes the bytes; ndisasm labels them from <addr>, which matters because
# jumping into the middle of an instruction is how this code obfuscates:
#
#   ndisasm -b 32 -o 0x322da00 /tmp/d_322da00.bin
#
# ndisasm ships with nasm (brew install nasm).
set -u
HERE=${0:A:h}
BOTTLE=${BOTTLE:-Aurora17}
W=/Applications/CrossOver-FIFA.app/Contents/SharedSupport/CrossOver/bin/wine

[[ $# -ge 3 ]] || { print "usage: $0 pid addr len [out.bin]"; exit 2 }
pid=$1 addr=$2 len=${3:-0x200} out=${4:-${TMPDIR:-/tmp}/d_$addr.bin}

"$W" --bottle "$BOTTLE" --workdir "Z:$HERE" --cx-app "Z:$HERE/mem.exe" \
    "$pid" "$addr" "$len" "Z:$out" || exit 1
[[ -x /opt/homebrew/bin/ndisasm ]] && /opt/homebrew/bin/ndisasm -b 32 -o "0x$addr" "$out"
