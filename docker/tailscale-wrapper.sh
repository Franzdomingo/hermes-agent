#!/bin/bash
set -e

mkdir -p /var/run/tailscale /var/lib/tailscale

# Start tailscaled in the background using the default VarRoot (/var/lib/tailscale)
# which is now a persistent Docker volume.
/usr/sbin/tailscaled --tun=userspace-networking &

# Wait for tailscaled to be ready
sleep 5

# If an auth key is provided, attempt to bring tailscale up
if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    echo "Tailscale auth key found, bringing Tailscale up..."
    # Use --force-reauth in case there's a stale login from a previous failed key attempt
    tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname="${TAILSCALE_HOSTNAME:-hermes-dashboard}" --accept-routes=false --accept-dns=false || echo "Tailscale up failed, possibly already authenticated"
fi

# Execute entrypoint dispatcher
exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
