#!/bin/sh
# Prints "public" or "internal" for gizmodata/hardcharger's releases, by an anonymous request to
# github.com (not the rate-limited API): 200 is public, 404 internal. Anything else exits 1, so
# a GitHub hiccup can't pass as "internal".
set -eu
code="$(curl -sIL -o /dev/null -w '%{http_code}' https://github.com/gizmodata/hardcharger/releases/latest || true)"
case "$code" in
  200) echo public ;;
  404) echo internal ;;
  *) echo "couldn't tell whether gizmodata/hardcharger's releases are public (HTTP $code)" >&2; exit 1 ;;
esac
