#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="hermes"

echo "=== CHECK 1: docker compose config (must parse; exactly ONE service) ==="
docker compose config

echo "=== CHECK 2: docker compose up -d --remove-orphans ==="
docker compose up -d --remove-orphans

echo "=== Waiting 25 seconds for container and s6 services to boot... ==="
sleep 25

echo "=== CHECK 3: docker ps (exactly one hermes container with 9119 published) ==="
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'

echo "=== CHECK 4: s6-svstat /run/service/dashboard (expect: up) ==="
docker exec "$CONTAINER_NAME" /command/s6-svstat /run/service/dashboard

echo "=== CHECK 5: s6-svstat /run/service/gateway-default (expect: up) ==="
docker exec "$CONTAINER_NAME" /command/s6-svstat /run/service/gateway-default

echo "=== CHECK 6: hermes gateway status (expect: running, with a PID) ==="
docker exec "$CONTAINER_NAME" hermes gateway status

echo "=== CHECK 7: tail -n 5 /opt/data/logs/container-boot.log (expect profile=default ... action=started) ==="
docker exec "$CONTAINER_NAME" tail -n 5 /opt/data/logs/container-boot.log

echo "=== CHECK 8: docker logs breadcrumb (s6 supervision) ==="
docker logs "$CONTAINER_NAME" 2>&1 | grep -i 's6 supervision' | head -n 1

echo "=== CHECK 9: curl localhost:9119 ==="
echo -n "Direct GET / HTTP code: "
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9119/
echo -n "Follow redirects (-L) HTTP code: "
curl -s -L -o /dev/null -w '%{http_code}\n' http://localhost:9119/
echo -n "Direct GET /login HTTP code: "
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9119/login

echo "=== CHECK 10: messaging platforms connectivity (gateway_state.json) ==="
docker exec "$CONTAINER_NAME" cat /opt/data/gateway_state.json
