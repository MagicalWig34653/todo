# Drittanbieterhinweise: BoringSSL in swift-nio-ssl und swift-crypto

Das Backend-Image enthält zwei Kopien von BoringSSL, statisch in `todo-app` gelinkt (`swift build -c release --static-swift-stdlib`):

| Paket | Version (Package.resolved) | Modul | BoringSSL-Revision |
|---|---|---|---|
| swift-nio-ssl | 2.37.6 (`15e0b9e4`) | `CNIOBoringSSL` | `8eb25be6fa18d475291122887a7bccd3762ff236` |
| swift-crypto | 3.15.1 (`95ba0316`) | `CCryptoBoringSSL` | `0226f30467f540a3f62ef48d453f93927da199b6` |

Die Revisionen stehen in `licenses/SOURCES.txt`; `scripts/check-third-party-notices.sh` prüft sie gegen `Package.resolved` und
die Checkouts (CI und Image-Build brechen bei Abweichung ab).

## Lizenz

BoringSSL steht in beiden Revisionen unter der **Apache License 2.0**. Der Text der Datei `LICENSE` des BoringSSL-Repositorys
(in beiden Revisionen byteidentisch) liegt unverändert in [`boringssl/LICENSE`](boringssl/LICENSE). Die Quelldateien tragen den
Apache-2.0-Kopf, z. B. „Copyright 1995-2016 The OpenSSL Project Authors. All Rights Reserved. … Licensed under the Apache
License, Version 2.0“. Die Copyright-Zeilen der Einzeldateien (u. a. The OpenSSL Project Authors, Google, Oracle, Nokia)
bleiben in den Quellen erhalten.

Weitere Bestandteile im Quellbaum:

- **fiat-crypto** (`third_party/fiat`, Copyright 2015-2020 the fiat-crypto authors): Apache-2.0, Text unverändert in
  [`boringssl/third_party-fiat-LICENSE`](boringssl/third_party-fiat-LICENSE).
- **`crypto/poly1305/poly1305_arm_asm.S`**: nach dem Kommentar der Datei gemeinfrei (neon2-Version aus SUPERCOP von
  D. J. Bernstein und Peter Schwabe); betrifft nur 32-Bit-ARM-Linux, nicht die Image-Architekturen amd64/arm64.
- Der Abschnitt „Licenses for support code“ in `boringssl/LICENSE` (Go-Lizenz, BSD-3-Klausel, Copyright 2009 The Go Authors)
  betrifft Teile der TLS-Testsuite. Sie sind laut BoringSSL nicht Teil von libcrypto/libssl und werden nicht gelinkt; der Text
  steht hier, weil er Teil der Datei ist.

Nicht ausgeliefert werden die Testdaten (z. B. Wycheproof in swift-crypto); sie liegen nur in den Test-Targets der Pakete.

## Upstream-NOTICE unverändert, veralteter Lizenzverweis

[`swift-nio-ssl/NOTICE.txt`](swift-nio-ssl/NOTICE.txt) und [`swift-crypto/NOTICE.txt`](swift-crypto/NOTICE.txt) sind
byteidentisch zu den Upstream-Dateien der gepinnten Versionen und werden bewusst nicht angepasst (die CI-Prüfung vergleicht
sie mit dem Checkout). Zusammen mit den jeweiligen `LICENSE.txt` (Apache-2.0 des SwiftNIO- bzw. SwiftCrypto-Projekts) liegen sie
unter `swift-nio-ssl/` und `swift-crypto/`.

Die `NOTICE.txt` von swift-nio-ssl 2.37.6 nennt am Ende noch: „This product contains code from boringssl. LICENSE
(Combination ISC and OpenSSL license) …/boringssl/+/refs/heads/master/LICENSE“. Dieser Satz ist **veraltet**: BoringSSL wurde
auf Apache-2.0 umgestellt, der Link zeigt auf `refs/heads/master` und damit auf den jeweils aktuellen Text, nicht auf den
Stand der gebündelten Revision. Für die tatsächlich gelinkten Revisionen gilt:

- `boringssl/LICENSE` ist der Text bei `8eb25be6` bzw. `0226f304` (Apache-2.0, plus die oben genannten Zusatzabschnitte),
- die Quellen enthalten keinen OpenSSL-/SSLeay-/ISC-Lizenztext mehr (die Prüfung im Skript sucht danach; verbleibende
  Treffer von „SSLeay“ sind nur API-Namen wie `RAND_SSLeay`),
- der frühere Befund (swift-nio-ssl 2.37.5, BoringSSL `817ab07e`, Altlizenz „OpenSSL/SSLeay“) ist damit aufgehoben.

Die swift-crypto-`NOTICE.txt` erwähnt BoringSSL nicht; die Lizenz der dort enthaltenen BoringSSL-Kopie steht deshalb in
`boringssl/LICENSE`.

## Hinweis zum Umfang

Diese Datei deckt die BoringSSL-Kopien und die beiden Pakete ab, die sie enthalten. Die übrigen Swift-Abhängigkeiten (Vapor,
Fluent, SwiftNIO usw.) sind in `Package.resolved` aufgeführt; eine vollständige Inventarliste aller Lizenzen ist nicht Teil
dieser Änderung.

# rclone (Deploy-Ziele, ADR 0039)

Das Backend-Image enthält das Programm `rclone` (`/usr/local/bin/rclone`) aus der offiziellen Release-Datei
`rclone-v1.76.0-linux-<arch>.zip` von downloads.rclone.org, im Dockerfile mit Version und SHA-256 je Architektur festgelegt.
rclone steht unter der **MIT License** (Copyright (C) 2019 by Nick Craig-Wood https://www.craig-wood.com/nick/); der Lizenztext
liegt der Release-Datei bei (`COPYING`) und unter https://github.com/rclone/rclone/blob/master/COPYING. Todolino ruft rclone als
eigenen Prozess auf und linkt es nicht.

`ssh-keyscan` stammt aus dem Ubuntu-Paket `openssh-client` (BSD-Lizenz, Paketangaben unter `/usr/share/doc/openssh-client`).
