#!/usr/bin/env bash
set -euo pipefail

IMAGE="tau:latest"
WORKDIR="$PWD"
OFFLINE=0
READ_ONLY=0
PI_ARGS=()
USAGE_NOTE=$(cat <<'EOF'
Usage: tau [options] [pi args...]
    -o, --offline      Run the container with no network access
    -r, --read-only    Make the container filesystem read-only (writable: mounts + /tmp)

Everything else is passed through to pi verbatim.
EOF
)

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--offline)   OFFLINE=1;      shift ;;
        -r|--read-only) READ_ONLY=1;    shift ;;
        -h|--help)
            echo "$USAGE_NOTE"
            exit 0 ;;
        *) PI_ARGS+=("$1"); shift ;;
    esac
done

if ! { [ -t 0 ] && [ -t 1 ]; }; then
    echo "tau: an interactive terminal (TTY) is required" >&2
    exit 1
fi

DOCKER_SANDBOX=()
[ "$OFFLINE" = 1 ] && DOCKER_SANDBOX+=(--network none)
[ "$READ_ONLY" = 1 ] && DOCKER_SANDBOX+=(--read-only --tmpfs /tmp)

SANDBOX_NOTE=$(cat <<EOF
You are running inside a temporary Docker container, not directly on the host.
- Your working directory "/workspace" is a bind mount of the host directory "${WORKDIR}".
- The host's "~/.pi" is mounted at "/home/pi/.pi" (pi's config and session state are shared with the host).
- The container is ephemeral: it is removed (docker run --rm) when pi exits.
- Network access: $( [ "$OFFLINE" = 1 ] && echo "DISABLED" || echo "available" ).
- Container filesystem: $( [ "$READ_ONLY" = 1 ] && echo "READ-ONLY; only /workspace, /home/pi/.pi and /tmp are writable" || echo "writable, but writes outside the mounts are discarded" ).
- Never assume host state (installed tools, services, environment variables) exists inside the container.
- The docker CLI is available and talks to the HOST Docker daemon via a mounted socket.
- Containers you start with docker/compose run on the host and persist after this container exits.
- The Docker socket is effectively root-equivalent on the host; do not start privileged containers or mount host paths.
EOF
)
DOCKERFILE=$(cat <<'EOF'
FROM node:26-slim

ENV PATH="/usr/local/lib/node_modules/.bin:$PATH"

RUN apt-get update \
 && apt-get install \
                -y \
                --no-install-recommends \
                ca-certificates \
                docker-cli \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @earendil-works/pi-coding-agent

WORKDIR /workspace

CMD ["pi"]
EOF
)

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf '%s\n' "$DOCKERFILE" | docker build -t "$IMAGE" -f -
fi

docker run \
        --rm \
        -it \
        --user "$(id -u):$(id -g)" \
        --group-add "$(getent group docker | cut -d: -f3)" \
        -w /workspace \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$WORKDIR:/workspace" \
        -v "${HOME}/.pi:/home/pi/.pi" \
        -e HOME=/home/pi \
        "${DOCKER_SANDBOX[@]}" \
        "$IMAGE" \
        pi --append-system-prompt "$SANDBOX_NOTE" "${PI_ARGS[@]}"
