#!/bin/sh
set -e
dockerd-entrypoint.sh "$@" &
DOCKERD_PID=$!
echo "DinD: waiting for Docker daemon..."
timeout 30 sh -c 'until docker info >/dev/null 2>&1; do sleep 1; done'
for image in postgres:16-alpine redis:7-alpine; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo "DinD: pre-pulling $image..."
        docker pull "$image" || echo "DinD: WARNING: failed to pull $image (will be pulled on demand)"
    fi
done
echo "DinD: ready"
wait $DOCKERD_PID
