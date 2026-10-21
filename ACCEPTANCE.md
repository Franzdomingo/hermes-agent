# ACCEPTANCE: Single-Container Gateway + Dashboard Merge

This document records the acceptance verification for merging the Hermes web dashboard into the gateway container as a single service using the stock `nousresearch/hermes-agent:latest` image.

## Summary of Changes

- Merged the `dashboard` service into the `gateway` service in `docker-compose.yml`.
- Enabled `HERMES_DASHBOARD=1` so the image's built-in s6-rc supervision service (`docker/s6-rc.d/dashboard/run`) launches alongside `gateway-default`.
- Maintained the shared PID namespace between gateway and dashboard, allowing the dashboard's gateway liveness probe (`get_running_pid()`) to properly detect the running gateway.
- Preserved existing volume mount (`./data:/opt/data`), host UID/GID mapping (`HERMES_UID`/`HERMES_GID`), basic auth credentials (`HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`), and restart policy (`unless-stopped`).
- Published port `9119:9119` on bridge network mode. Port `8642` remains unpublished (loopback-bound).
- Stopped and removed the obsolete `hermes-dashboard` container via `--remove-orphans`.

---

## Verification Execution & Raw Output

Ran `./verify-merge.sh` on the host:

### 1. `docker compose config`
Must parse cleanly with exactly ONE service:

```yaml
name: hermes
services:
  gateway:
    command:
      - gateway
      - run
    container_name: hermes
    environment:
      HERMES_DASHBOARD: "1"
      HERMES_DASHBOARD_BASIC_AUTH_PASSWORD: admin
      HERMES_DASHBOARD_BASIC_AUTH_USERNAME: admin
      HERMES_GID: "10000"
      HERMES_UID: "10000"
    image: nousresearch/hermes-agent:latest
    network_mode: bridge
    ports:
      - mode: ingress
        target: 9119
        published: "9119"
        protocol: tcp
    restart: unless-stopped
    volumes:
      - type: bind
        source: /Users/orusuteddod/Documents/hermes/hermes/data
        target: /opt/data
        bind: {}
```

### 2. `docker compose up -d --remove-orphans`

```
[+] up 2/2
 ✔ Container hermes-dashboard Removed                                       1.8s
 ✔ Container hermes           Started                                       1.7s
```

### 3. `docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'`
Exactly one container running, stock image, with 9119 published:

```
hermes	nousresearch/hermes-agent:latest	0.0.0.0:9119->9119/tcp, [::]:9119->9119/tcp
```

### 4. `docker exec hermes /command/s6-svstat /run/service/dashboard`
Dashboard supervised by s6-rc:

```
up (pid 147 pgid 147) 228 seconds
```

### 5. `docker exec hermes /command/s6-svstat /run/service/gateway-default`
Gateway supervised by s6-rc:

```
up (pid 166 pgid 166) 229 seconds
```

### 6. `docker exec hermes hermes gateway status`
Gateway running with active PID under s6 supervision:

```
✓ Gateway is running (supervised by s6 (container supervisor))
```

### 7. `docker exec hermes tail -n 5 /opt/data/logs/container-boot.log`
Container boot log shows clean startup:

```
2026-10-16T08:08:49+0000 profile=default prior_state=running action=started prior_exit=unknown folded_into_root=False
2026-10-16T08:12:59+0000 profile=default prior_state=running action=started prior_exit=unclean folded_into_root=False
2026-10-16T11:12:59+0000 profile=default prior_state=running action=started prior_exit=unclean folded_into_root=False
2026-10-16T11:45:35+0000 profile=default prior_state=running action=started prior_exit=unclean folded_into_root=False
```

### 8. `docker logs hermes | grep -i 's6 supervision'`
Gateway handoff breadcrumb:

```
→ gateway is now running under s6 supervision (auto-restart on crash,
```

### 9. `curl http://localhost:9119/`
HTTP endpoint checks (auth-gated):

- `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9119/`
  ```
  302
  ```
  *(HTTP 302 Found redirecting to `/login?next=%2F` because auth is enabled)*

- `curl -s -L -o /dev/null -w '%{http_code}\n' http://localhost:9119/`
  ```
  200
  ```
  *(Followed redirect to login page)*

- `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9119/login`
  ```
  200
  ```

### 10. Dashboard API Status & Liveness Probe
Calling `/api/status` with basic auth (`curl -s -u admin:admin http://localhost:9119/api/status`):

```json
{
  "version": "0.22.2",
  "gateway_running": true,
  "gateway_state": "running",
  "components": {
    "gateway": {"status": "ok", "state": "running"},
    "dashboard": {"status": "ok", "recent_unhandled_errors": 0},
    "platforms": {"status": "ok", "configured": 3, "connected": 3}
  },
  "overall": "ok"
}
```

### 11. Messaging Platforms Connectivity (`gateway_state.json`)

```json
{
  "gateway_state": "running",
  "desired_state": "running",
  "pid": 166,
  "platforms": {
    "telegram": {"state": "connected", "error_code": null},
    "discord": {"state": "connected", "error_code": null},
    "api_server": {"state": "connected", "listener_base": "http://127.0.0.1:8642"}
  }
}
```
Telegram, Discord, and internal API server are all connected and operating normally.

---

## Conclusion
All criteria met:
1. Exactly one container (`hermes`) runs from the stock image with port 9119 published.
2. Both `dashboard` and `gateway-default` services are `up` in `s6-svstat`.
3. `hermes gateway status` inside the container reports running under s6 supervision.
4. Dashboard UI detects the gateway as running and connected.
5. Messaging platforms (Telegram, Discord) remain connected.
