#!/usr/bin/env bash
# What the suite needs from the machine, asked before the suite rather than discovered inside it.
#
#     bash tools/gatedeps.sh        # exit 0 when everything is here; otherwise what is missing and how to get it
#
# **Why this exists.** A test whose oracle is missing does not always skip. The webrtc oracles fail
# with `ModuleNotFoundError` after waiting out their timeouts, coturn's absence is twenty attempts of a
# second and a half, and an sshd with no privilege-separation directory "never accepted on" its port —
# so a machine short of one package produced a red suite three minutes slower than a green one, with
# forty failures that all said something other than "install aioice". Measured on a fresh machine on
# 2026-11-03: 946s red, against 762s once these were installed.
#
# **Only what makes a test fail.** What a test skips cleanly without — a C tor, anvil, OpenSSL 3.5, an
# HTTP proxy — is not asked here, because the skip already says what it would take.
#
# `tools/push.sh` runs this first; `WAC_GATE_DEPS_ANYWAY=1` goes past it.
set -u

missing=()
warn=()
need() { missing+=("$1 — $2"); }

for m in aioice aiortc google_crc32c; do
  python3 -c "import $m" 2>/dev/null || need "python3 module $m" "pip install ${m//_/-} (packages/webrtc/test/*_oracle.py)"
done
for c in openssl turnserver ssh ssh-keygen ss git; do
  command -v "$c" >/dev/null 2>&1 || case "$c" in
    turnserver) need "turnserver" "apt-get install coturn (packages/webrtc/test/wac/stun_test.wac)" ;;
    ss) need "ss" "apt-get install iproute2 (the DTLS tests ask it whether openssl has bound)" ;;
    ssh|ssh-keygen) need "$c" "apt-get install openssh-client (packages/ssh/test/wac)" ;;
    *) need "$c" "install $c" ;;
  esac
done
if [ ! -x /usr/sbin/sshd ]; then
  need "/usr/sbin/sshd" "apt-get install openssh-server (packages/ssh/test/wac/live_test.wac)"
elif [ ! -d /run/sshd ]; then
  need "/run/sshd" "mkdir -p /run/sshd — sshd refuses to start without its privilege-separation directory"
fi

# **The browser the Deno tests' Playwright will ask for**, not a browser: `npm:playwright@1` resolves to the
# newest 1.x, which names a Chromium build of its own, and an older one in `~/.cache/ms-playwright` is
# "Executable doesn't exist" in every browser test.
if command -v deno >/dev/null 2>&1; then
  exe=$(deno eval 'const { chromium } = await import("npm:playwright@1"); console.log(chromium.executablePath());' 2>/dev/null | tail -1)
  if [ -z "$exe" ]; then
    need "npm:playwright@1" "deno could not load it — is the npm registry reachable?"
  elif [ ! -x "$exe" ]; then
    need "Chromium for npm:playwright@1" "deno run -A npm:playwright@1 install chromium (wants $exe)"
  fi
fi

# Not fatal, and said so: these fail tests whatever is installed.
[ "$(id -u)" = "0" ] && warn+=("running as root: the tests of what a refused permission looks like (rm -f, find, du, a locked directory) cannot see a refusal")

for w in "${warn[@]}"; do echo "gatedeps: note — $w"; done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "gatedeps: the suite would fail for want of ${#missing[@]} thing(s) on this machine:"
  for m in "${missing[@]}"; do echo "   $m"; done
  exit 1
fi
echo "gatedeps: everything the suite asks of the machine is here"
