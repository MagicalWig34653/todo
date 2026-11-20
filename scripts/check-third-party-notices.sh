#!/usr/bin/env bash
# Prüft, dass licenses/ zum tatsächlich aufgelösten Quellstand passt (Karte 72A0421F):
#  - Package.resolved pinnt swift-nio-ssl und swift-crypto auf die in licenses/SOURCES.txt genannten Versionen/Revisionen,
#  - die darin gebündelten BoringSSL-Revisionen (hash.txt in .build/checkouts) stimmen überein,
#  - LICENSE.txt/NOTICE.txt der beiden Pakete sind byteidentisch zum Upstream-Checkout (nicht verändert),
#  - die mitgelieferten Lizenztexte stimmen mit licenses/SHA256SUMS überein,
#  - der BoringSSL-Lizenztext ist Apache-2.0 und die Quellen tragen keinen OpenSSL-/SSLeay-Lizenztext mehr.
# Läuft nach `swift package resolve` (CI und Dockerfile). Exit 0 = alles stimmig.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FEHLER: $*" >&2; exit 1; }
src() { sed -n "s/^$1=//p" licenses/SOURCES.txt; }
pin() { # <identity> <version|revision>
  awk -v id="$1" -v key="$2" '
    $0 ~ "\"identity\" : \"" id "\"" { hit = 1 }
    hit && $0 ~ "\"" key "\"" { gsub(/[",]/, ""); print $3; exit }' Package.resolved
}
sumcheck() { if command -v sha256sum >/dev/null; then (cd licenses && sha256sum -c --quiet SHA256SUMS); else (cd licenses && shasum -a 256 -c --quiet SHA256SUMS); fi; }

for p in swift-nio-ssl swift-crypto; do
  [ "$(pin $p version)" = "$(src $p.version)" ]   || fail "$p: Version in Package.resolved ($(pin $p version)) weicht von licenses/SOURCES.txt ($(src $p.version)) ab"
  [ "$(pin $p revision)" = "$(src $p.revision)" ] || fail "$p: Revision in Package.resolved weicht von licenses/SOURCES.txt ab"
  co=.build/checkouts/$p
  [ -d "$co" ] || fail "$co fehlt (zuerst swift package resolve)"
  cmp -s "$co/LICENSE.txt" "licenses/$p/LICENSE.txt" || fail "licenses/$p/LICENSE.txt ist nicht byteidentisch zum Upstream"
  cmp -s "$co/NOTICE.txt" "licenses/$p/NOTICE.txt"   || fail "licenses/$p/NOTICE.txt ist nicht byteidentisch zum Upstream (Upstream-NOTICE bleibt unverändert)"
done

bssl() { sed -n 's/.*at revision \([0-9a-f]\{40\}\).*/\1/p' "$1" | head -n1; }
[ "$(bssl .build/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL/hash.txt)" = "$(src swift-nio-ssl.boringssl)" ] || fail "BoringSSL-Revision in swift-nio-ssl weicht von licenses/SOURCES.txt ab"
[ "$(bssl .build/checkouts/swift-crypto/Sources/CCryptoBoringSSL/hash.txt)" = "$(src swift-crypto.boringssl)" ] || fail "BoringSSL-Revision in swift-crypto weicht von licenses/SOURCES.txt ab"

sumcheck || fail "licenses/SHA256SUMS: ein mitgelieferter Lizenztext wurde verändert"
head -n 3 licenses/boringssl/LICENSE | grep -q "Apache License" || fail "licenses/boringssl/LICENSE ist nicht Apache-2.0"
for d in .build/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL .build/checkouts/swift-crypto/Sources/CCryptoBoringSSL; do
  if grep -rIl "OpenSSL license\|OpenSSL Toolkit\|Eric Young\|Permission to use, copy, modify, and/or distribute" "$d" >/dev/null 2>&1; then
    fail "$d enthält noch OpenSSL-/SSLeay-/ISC-Lizenztext, THIRD-PARTY-NOTICES.md muss das abbilden"
  fi
done
echo "licenses/: ok (swift-nio-ssl $(src swift-nio-ssl.version), BoringSSL $(src swift-nio-ssl.boringssl | cut -c1-8); swift-crypto $(src swift-crypto.version), BoringSSL $(src swift-crypto.boringssl | cut -c1-8))"
