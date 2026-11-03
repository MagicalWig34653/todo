#!/bin/sh
# Downloads ONE Todolino attachment from the short-lived signed URL of the MCP tool get_attachment_download into a
# local directory, so the Read tool can look at it. Prints the local path on stdout.
#
#   fetch-attachment.sh <url> [dir]
#
# dir defaults to ${TMPDIR:-/tmp}/todolino-attachments (created with mode 700).
# Refuses anything but https://host/v1/attachments/<uuid>/download?exp=..&sig=.. (http only for localhost / 127.0.0.1),
# follows no redirects, stops at 25 MB, writes only inside dir under a sanitized name and never echoes the URL.
set -u
max_bytes=26214400

die() { echo "fetch-attachment: $1" >&2; exit "${2:-1}"; }

url=${1:-}
[ -n "$url" ] || die "usage: fetch-attachment.sh <url> [dir]" 2
dir=${2:-${TMPDIR:-/tmp}/todolino-attachments}

# Only printable ASCII without spaces or userinfo: nothing that could smuggle options, hosts or headers.
case "$url" in
  *[!A-Za-z0-9._~:/?\&=%+-]*) die "refused: unexpected characters in URL" ;;
  *@*) die "refused: unexpected characters in URL" ;;
esac
case "$url" in
  https://*) rest=${url#https://} ;;
  http://localhost[:/]*|http://127.0.0.1[:/]*) rest=${url#http://} ;;
  *) die "refused: only https URLs (http only for localhost)" ;;
esac
path=/${rest#*/}
[ "$path" != "/$rest" ] || die "refused: URL has no path"
route=${path%%\?*}
query=${path#*\?}
[ "$query" != "$path" ] || die "refused: URL has no signature"
id=${route#/v1/attachments/}; id=${id%/download}
[ "/v1/attachments/$id/download" = "$route" ] || die "refused: not an attachment download URL"
case "$id" in
  [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
  *) die "refused: invalid attachment id" ;;
esac

umask 077
mkdir -p "$dir" || die "cannot create directory"
dir=$(cd "$dir" 2>/dev/null && pwd -P) || die "cannot enter directory"
work=$(mktemp -d "$dir/.fetch.XXXXXX") || die "cannot create temp directory"
trap 'rm -rf "$work"' EXIT

# --proto/--max-filesize/no -L: no redirect to other hosts, no protocol switch, size capped (also while streaming).
proto='=https'
case "$url" in http://*) proto='=http' ;; esac
status=$(curl -sS --proto "$proto" --max-filesize "$max_bytes" --max-time 120 --connect-timeout 15 \
  -D "$work/headers" -o "$work/body" -w '%{http_code}' -- "$url" 2>"$work/err") \
  || die "download failed ($(tr -d '\r\n' < "$work/err" | sed 's#https\{0,1\}://[^ ]*#<url>#g' | cut -c1-120))"
[ "$status" = "200" ] || die "download refused (HTTP $status): the link is expired or not valid, request a new one"
size=$(wc -c < "$work/body" | tr -d ' ')
[ "$size" -le "$max_bytes" ] || die "file larger than 25 MB"
[ "$size" -gt 0 ] || die "empty file"

# Name: filename*=UTF-8''... or filename="..." from Content-Disposition, reduced to [A-Za-z0-9._-]; else the attachment id.
name=$(tr -d '\r' < "$work/headers" | sed -n "s/^[Cc]ontent-[Dd]isposition:.*filename\*=UTF-8''\([^;]*\).*/\1/p" | head -n 1)
if [ -z "$name" ]; then
  name=$(tr -d '\r' < "$work/headers" | sed -n 's/^[Cc]ontent-[Dd]isposition:.*filename="\{0,1\}\([^";]*\).*/\1/p' | head -n 1)
fi
# Percent-decode is skipped on purpose: '%' is dropped below, so no separators or dots can appear through decoding.
name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_' | sed 's/\.\.*/./g; s/^[._]*//' | cut -c1-80)
[ -n "$name" ] || name=$id
case "$name" in *.*) ;; *)
  case $(tr -d '\r' < "$work/headers" | sed -n 's/^[Cc]ontent-[Tt]ype: *\([^;]*\).*/\1/p' | head -n 1 | tr 'A-Z' 'a-z') in
    image/png) name=$name.png ;; image/jpeg) name=$name.jpg ;; image/webp) name=$name.webp ;; application/pdf) name=$name.pdf ;;
  esac ;;
esac
# The id prefix keeps two attachments with the same file name apart.
target="$dir/$(printf '%s' "$id" | cut -c1-8)-$name"
mv -f "$work/body" "$target" || die "cannot write file"
printf '%s\n' "$target"
