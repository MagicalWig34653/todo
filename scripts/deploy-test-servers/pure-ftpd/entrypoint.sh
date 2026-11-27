#!/bin/sh
# Needs --cap-add SYS_NICE --cap-add DAC_READ_SEARCH --cap-add SYS_RESOURCE (pure-ftpd exits with 252 otherwise).
# FTP_USER, FTP_PASS, PUBLICHOST, TLS_MODE (1 = optional TLS, 2 = TLS required). Writes a fresh self-signed certificate per start
# to /etc/ssl/private/pure-ftpd.pem (the test reads its public part with `docker exec ... cat`).
set -e
groupadd -f ftpgroup; id ftpuser >/dev/null 2>&1 || useradd -g ftpgroup -d /dev/null -s /usr/sbin/nologin ftpuser
mkdir -p /home/"$FTP_USER"/site /etc/ssl/private /etc/pure-ftpd
if [ ! -f /etc/ssl/private/pure-ftpd.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${TLS_CN:-localhost}" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -keyout /etc/ssl/private/pure-ftpd.pem -out /tmp/cert.pem 2>/dev/null
  cat /tmp/cert.pem >> /etc/ssl/private/pure-ftpd.pem; chmod 600 /etc/ssl/private/pure-ftpd.pem
fi
(printf '%s\n%s\n' "$FTP_PASS" "$FTP_PASS") | pure-pw useradd "$FTP_USER" -f /etc/pure-ftpd/pureftpd.passwd -u ftpuser -d /home/"$FTP_USER" >/dev/null
pure-pw mkdb /etc/pure-ftpd/pureftpd.pdb -f /etc/pure-ftpd/pureftpd.passwd
chown -R ftpuser:ftpgroup /home/"$FTP_USER"
exec /usr/sbin/pure-ftpd -l puredb:/etc/pure-ftpd/pureftpd.pdb -E -j -R -A -P "${PUBLICHOST:-127.0.0.1}" -p 30000:30009 -Y "${TLS_MODE:-1}" -c 10 -C 10
