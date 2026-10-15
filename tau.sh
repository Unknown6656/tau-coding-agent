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

USAGE_NOTE=$(cat <<EOF
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

function cleanup() {
    rm -rf "${CLEANUP_DIRS[@]}";
}
trap cleanup EXIT

APT_PACKAGES=(
    binutils
    ca-certificates
    chromium
    cmake
    curl
    diffutils
    docker-cli
    fd-find
    file
    g++
    gcc
    gdb
    git
    iproute2
    jq
    less
    libssl-dev
    lsof
    make
    netcat-openbsd
    openssh-client
    patch
    perl
    pkg-config
    procps
    python3
    python3-dev
    python3-pip
    python3-venv
    ripgrep
    rsync
    sudo
    tar
    tree
    unzip
    zip
)

VOL_CACHE="tau-cache"        # volume for pip / npm / chromium caches -> /home/pi/.cache
VOL_CHROMIUM="tau-chromium"  # volume for chromium profile data  -> /home/pi/chromium
VOL_APT="tau-apt-cache"      # volume for apt package archives   -> /var/cache/apt

SANDBOX_NOTE=$(cat <<EOF
You are the pi coding agent, started by the 'tau' wrapper script inside a temporary Docker container, not directly on the host.

- Your working directory is the host directory "${WORKDIR}", mounted at the same path.
- The host's "~/.pi" is mounted at "/home/pi/.pi" (pi's config and session state are shared with the host).
- The container is ephemeral: it is removed (docker run --rm) when pi exits.
- Network access: $( [ "$OFFLINE" = 1 ] && echo "DISABLED" || echo "available" ).
- Container filesystem: writable, but writes outside the mounts are discarded.
- Never assume host state (installed tools, services, environment variables) exists inside the container.
- The docker CLI is available and talks to the HOST Docker daemon via a mounted socket.
- Containers you start with docker/compose run on the host and persist after this container exits.
- The Docker socket is effectively root-equivalent on the host; do not start privileged containers or mount host paths, unless explicitly allowed by the user after asking them.
- Preinstalled packages: ${APT_PACKAGES[*]}.
- chromium is available for headless web testing: 'chromium --headless --no-sandbox --disable-gpu ...'. Pass --user-data-dir=/home/pi/chromium to keep its profile across container restarts.
- sudo is available (passwordless) for system-level installs, e.g. 'sudo apt install ...'. Keep in mind that changes to the container are ephemeral and will be lost when it exits.
- The following paths are Docker named volumes on the host and persist across container runs (list them with 'docker volume ls'): /home/pi/chromium (chromium profile), /home/pi/.cache (pip/npm caches), /var/cache/apt (apt archives). Everything else on the container filesystem is lost when it exits.
- Do NOT run 'rm -rf': the harness aborts the operation instantly if the command contains this string. Remove files with targeted 'rm' (without -r -f), 'find ... -delete', or similar non-recursive alternatives.
EOF
)
DOCKERFILE=$(cat <<EOF
FROM node:26-slim

ENV PATH="/usr/local/lib/node_modules/.bin:\$PATH"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ${APT_PACKAGES[*]}

RUN npm install -g @earendil-works/pi-coding-agent

CMD ["pi"]
EOF
)

if [ "$REBUILD" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo -e "${_TAU_PREFIX}Building Docker image '$IMAGE'..."

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

docker run --rm --user root \
        -v "$SUDOERS_DIR:/fix" \
        -v "$VOL_CACHE:/v/cache" \
        -v "$VOL_CHROMIUM:/v/chromium" \
        -v "$VOL_APT:/v/apt" \
        -e TAU_UID="$(id -u)" -e TAU_GID="$(id -g)" "$IMAGE" sh -c '
    chown "$TAU_UID:$TAU_GID" /v/cache /v/chromium
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
        -v "$VOL_CACHE:/home/pi/.cache" \
        -v "$VOL_CHROMIUM:/home/pi/chromium" \
        -v "$VOL_APT:/var/cache/apt" \
        -e HOME=/home/pi \
        -e npm_config_cache=/home/pi/.cache/npm \
        "${DOCKER_SANDBOX_ARGS[@]}" \
        "$IMAGE" \
        pi --append-system-prompt "$SANDBOX_NOTE" "${PI_ARGS[@]}"
