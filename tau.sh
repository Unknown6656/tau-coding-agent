#!/usr/bin/env bash
set -euo pipefail

_TAU_PREFIX="\x1b[90m[\x1b[96mtau\x1b[90m]\x1b[m "
_TAU_ERR_PREFIX="${_TAU_PREFIX}\x1b[31merror:\x1b[91m "
_TAU_WARN_PREFIX="${_TAU_PREFIX}\x1b[33mwarning:\x1b[93m "

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
IMAGE="tau:$(sha256sum "$SELF" | cut -c1-12)"
WORKDIR="$PWD"
REBUILD=0
OFFLINE=0
PI_ARGS=()
DOCKER_SANDBOX_ARGS=()
CLEANUP_DIRS=()

USAGE_NOTE=$(cat <<'EOF'
Usage: tau [options] [pi args...]
    -h, --help         Show this help message (all other arguments are ignored)
    -b, --rebuild      Force rebuild of the Docker image.
    -o, --offline      Run the container with no network access.

Everything else is passed through to pi verbatim.
EOF
)


if ! command -v tau >/dev/null 2>&1; then
    BIN_DIR=""

    case ":$PATH:" in
        *":$HOME/.local/bin:"*) BIN_DIR="$HOME/.local/bin" ;;
        *)
            IFS=':' read -r -a _path_dirs <<< "$PATH"

            for _d in "${_path_dirs[@]}"; do
                if [ -d "$_d" ] && [ -w "$_d" ]; then
                    BIN_DIR="$_d";
                    break;
                fi
            done

            BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
        ;;
    esac

    mkdir -p "$BIN_DIR"
    ln -sf "$SELF" "$BIN_DIR/tau"

    echo -e "${_TAU_PREFIX}linked $BIN_DIR/tau -> $SELF"

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) echo -e "${_TAU_WARN_PREFIX}$BIN_DIR is not in your PATH; add it to your shell rc" >&2 ;;
    esac
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--rebuild) REBUILD=1; shift ;;
        -o|--offline) OFFLINE=1; shift ;;
        -h|--help)
            echo "$USAGE_NOTE"
            exit 0 ;;
        *) PI_ARGS+=("$1"); shift ;;
    esac
done

if ! { [ -t 0 ] && [ -t 1 ]; }; then
    echo -e "${_TAU_ERR_PREFIX}an interactive terminal (TTY) is required" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo -e "${_TAU_ERR_PREFIX}docker is not installed or not in PATH" >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "${_TAU_ERR_PREFIX}the docker daemon is not running or not accessible" >&2
    exit 1
fi

[ "$OFFLINE" = 1 ] && DOCKER_SANDBOX_ARGS+=(--network none)

cleanup() { rm -rf "${CLEANUP_DIRS[@]}"; }
trap cleanup EXIT

SANDBOX_NOTE=$(cat <<EOF
You are running inside the temporary Docker container 'tau', not directly on the host.

- Your working directory is the host directory "${WORKDIR}", mounted at the same path.
- The host's "~/.pi" is mounted at "/home/pi/.pi" (pi's config and session state are shared with the host).
- The 'tau' container is ephemeral: it is removed (docker run --rm) when pi exits.
- Network access: $( [ "$OFFLINE" = 1 ] && echo "DISABLED" || echo "available" ).
- Container filesystem: writable, but writes outside the mounts are discarded.
- Never assume host state (installed tools, services, environment variables) exists inside the container.
- The docker CLI is available and talks to the HOST Docker daemon via a mounted socket.
- Containers you start with docker/compose run on the host and persist after this container exits.
- The Docker socket is effectively root-equivalent on the host; do not start privileged containers or mount host paths, unless explicitly allowed by the user after asking them.
- sudo is available (passwordless) for system-level installs, e.g. 'sudo apt install ...'. Keep in mind that changes to the container are ephemeral and will be lost when it exits.
EOF
)
DOCKERFILE=$(cat <<'EOF'
FROM node:26-slim

ENV PATH="/usr/local/lib/node_modules/.bin:$PATH"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
                    ca-certificates \
                    docker-cli \
                    git \
                    curl \
                    python3 \
                    unzip \
                    perl \
                    tar \
                    binutils \
                    make \
                    sudo \
                    gcc \
                    g++ \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @earendil-works/pi-coding-agent

CMD ["pi"]
EOF
)

if [ "$REBUILD" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    BUILD_CTX="$(mktemp -d)"
    CLEANUP_DIRS+=("$BUILD_CTX")

    printf '%s\n' "$DOCKERFILE" > "$BUILD_CTX/Dockerfile"
    docker build \
            -t "$IMAGE" \
            -f "$BUILD_CTX/Dockerfile" \
            "$BUILD_CTX"
fi

if ! docker run --rm --entrypoint sh "$IMAGE" -c 'command -v pi' >/dev/null 2>&1; then
    echo -e "${_TAU_ERR_PREFIX}pi is not installed in image $IMAGE; remove it and re-run tau to rebuild" >&2
    exit 1
fi

if [ ! -d "${HOME}/.pi" ]; then
    echo -e "${_TAU_WARN_PREFIX}${HOME}/.pi does not exist; creating it" >&2
    mkdir -p "${HOME}/.pi"
fi

SUDOERS_DIR="$(mktemp -d)"
CLEANUP_DIRS+=("$SUDOERS_DIR")

echo -e "${_TAU_PREFIX}Patching sudo for user '$(id -u):$(id -g)' ..."

docker run --rm --user root -v "$SUDOERS_DIR:/fix" -e TAU_UID="$(id -u)" "$IMAGE" sh -c '
    {
        echo "$TAU_UID ALL=(ALL) NOPASSWD:ALL"
        name="$(getent passwd "$TAU_UID" | cut -d: -f1)"
        [ -n "$name" ] && echo "$name ALL=(ALL) NOPASSWD:ALL"
    } > /fix/tau
    chmod 0440 /fix/tau
'

echo -e "${_TAU_PREFIX}Starting Docker container '$IMAGE'..."
docker run \
        --rm \
        -it \
        --user "$(id -u):$(id -g)" \
        --group-add "$(getent group docker | cut -d: -f3)" \
        -w "$WORKDIR" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$SUDOERS_DIR/tau:/etc/sudoers.d/tau:ro" \
        -v "$WORKDIR:$WORKDIR" \
        -v "${HOME}/.pi:/home/pi/.pi" \
        -e HOME=/home/pi \
        "${DOCKER_SANDBOX_ARGS[@]}" \
        "$IMAGE" \
        pi --append-system-prompt "$SANDBOX_NOTE" "${PI_ARGS[@]}"
