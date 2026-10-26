#!/bin/bash
set -eu
# Ubuntu runtime has bash, but no curl. Check both endpoints via HTTP/1.1.
for path in live ready; do
  exec 3<>/dev/tcp/127.0.0.1/8080
  printf 'GET /health/%s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' "$path" >&3
  IFS= read -r status <&3
  exec 3>&-
  [[ "$status" == *' 200 '* ]]
done
