#!/usr/bin/env bash
# Check for and apply updates to the serial2moon stack's container images.
#
#   update.sh check [--quiet]   report which images have a newer version (changes nothing)
#   update.sh apply             pull newer images and restart only the changed containers
#
# Run by the serial2moon-update*.service units when the HOST_UPDATE_CHECK / HOST_UPDATE
# macros drop a request, and once at boot (check --quiet) to announce available updates.
# Updates are only ever applied on request. Results go to the Mainsail console (via
# Moonraker and serial2moon's RESPOND) and to the journal (journalctl -u 'serial2moon-update*').
set -uo pipefail
cd "${S2M_DIR:-/opt/serial2moon}" || exit 1

MOONRAKER=${MOONRAKER:-http://127.0.0.1:7125}
BAKED=images/digests.txt # "<image ref> <image id> <repo digest>" for images loaded from the .img

log() { echo "$*"; }

# Post a line to the Mainsail console. Ignored when Moonraker or serial2moon is down.
say() {
    log "$1"
    curl -s -m 5 -X POST "$MOONRAKER/printer/gcode/script" \
        --data-urlencode "script=RESPOND ${2:+TYPE=$2 }PREFIX=update: MSG=\"$1\"" >/dev/null 2>&1 || true
}

compose() { docker compose -f compose.yml "$@"; }

# Digest of the image a tag points to in its registry (anonymous pull token), or empty.
remote_digest() {
    local ref=$1 reg name tag token
    tag=${ref##*:}
    name=${ref%:*}
    case $name in
        ghcr.io/*) reg=ghcr.io; name=${name#ghcr.io/}
            token=$(curl -fsS -m 15 "https://ghcr.io/token?scope=repository:$name:pull") ;;
        */*/*) return 0 ;; # other registries: not supported
        */*) reg=registry-1.docker.io
            token=$(curl -fsS -m 15 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$name:pull") ;;
        *) reg=registry-1.docker.io; name=library/$name
            token=$(curl -fsS -m 15 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$name:pull") ;;
    esac
    token=$(printf '%s' "$token" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("token") or d.get("access_token") or "")' 2>/dev/null) || return 0
    curl -fsSI -m 15 -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        "https://$reg/v2/$name/manifests/$tag" 2>/dev/null \
        | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

# Registry digests of the local image (after a pull), else the one recorded when the image
# was baked into the .img (docker load drops them), else empty.
local_digests() {
    local ref=$1 id
    id=$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null) || return 0
    docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" | sed -n 's/.*@//p'
    if [ -f "$BAKED" ]; then
        awk -v r="$ref" -v i="$id" '$1==r && $2==i {print $3}' "$BAKED"
    fi
    return 0 # (pipefail: a missing file must not fail the caller's grep)
}

# Sort the stack's images into $OUTDATED (a newer version exists) and $UNCHECKED (the
# registry couldn't be asked: no network, or an image it doesn't know).
scan() {
    local ref remote
    OUTDATED=() UNCHECKED=()
    for ref in $(compose config --images | sort -u); do
        remote=$(remote_digest "$ref")
        if [ -z "$remote" ]; then
            UNCHECKED+=("$ref")
        elif ! local_digests "$ref" | grep -qx "$remote"; then
            OUTDATED+=("$ref")
        fi
    done
}

# "a, b, c"
join() { local IFS=,; echo "$*" | sed 's/,/, /g'; }

printing() {
    curl -s -m 5 "$MOONRAKER/printer/objects/query?print_stats=state" 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])' 2>/dev/null \
        | grep -qxE 'printing|paused'
}

# Wait (up to ~2 min) until Moonraker answers, so console messages reach Mainsail.
wait_moonraker() {
    for _ in $(seq 60); do
        curl -s -m 2 "$MOONRAKER/server/info" >/dev/null 2>&1 && return 0
        sleep 2
    done
}

check() {
    local quiet=${1:-}
    if [ -n "$quiet" ]; then
        wait_moonraker # at boot: let the stack come up so the notice reaches the console
        sleep 15
    else
        say "Checking for updates..."
    fi
    scan
    if [ ${#OUTDATED[@]} -gt 0 ]; then
        say "New versions available: $(join "${OUTDATED[@]}"). Run HOST_UPDATE to install."
    elif [ ${#UNCHECKED[@]} -eq 0 ]; then
        [ -z "$quiet" ] && say "Everything is up to date."
    fi
    if [ ${#UNCHECKED[@]} -gt 0 ] && [ -z "$quiet" ]; then
        say "Could not check $(join "${UNCHECKED[@]}") (no internet, or not published)." error
    fi
    return 0
}

apply() {
    if printing; then
        say "Not updating while a print is running or paused." error
        return 1
    fi
    scan
    if [ ${#OUTDATED[@]} -eq 0 ]; then
        if [ ${#UNCHECKED[@]} -gt 0 ]; then
            say "Could not check $(join "${UNCHECKED[@]}") (no internet, or not published)." error
        else
            say "Everything is up to date."
        fi
        return 0
    fi
    local list
    list=$(join "${OUTDATED[@]}")
    say "Downloading: $list. Mainsail will reconnect when done."
    local ref
    for ref in "${OUTDATED[@]}"; do
        if ! docker pull --quiet "$ref" >/dev/null; then
            say "Download of $ref failed; nothing was changed." error
            return 1
        fi
    done
    if printing; then # a print may have started during the download
        say "Downloaded, but a print started. Run HOST_UPDATE again when it finishes." error
        return 1
    fi
    compose up -d # recreates only the containers whose image changed
    docker image prune -f >/dev/null 2>&1 || true
    wait_moonraker
    sleep 5 # let serial2moon reconnect to Moonraker
    say "Update finished: $list."
}

case ${1:-} in
    check) check "${2:-}" ;;
    apply) apply ;;
    *) echo "usage: $0 check [--quiet] | apply" >&2; exit 2 ;;
esac
