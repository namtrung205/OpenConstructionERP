# Deploy OpenConstructionERP on Ubuntu with Docker and Cloudflare Tunnel

This guide deploys the production stack on Ubuntu and publishes it at a custom
hostname through a remotely managed Cloudflare Tunnel. It uses the example
hostname `openconstructionerp.clover4leaf.store`; replace it with your own
hostname where appropriate.

The Tunnel connector runs as part of the same Docker Compose project as the
frontend. It reaches the frontend over the private Compose network at
`http://frontend:80`. No public host port, local TLS certificate, Nginx reverse
proxy, router port forwarding, or inbound firewall rule is required.

## Architecture

```text
Browser
  -> https://openconstructionerp.clover4leaf.store
  -> Cloudflare edge
  -> outbound Cloudflare Tunnel connection
  -> cloudflared container
  -> http://frontend:80 (private Docker network)
  -> /api/* -> backend:8000
  -> PostgreSQL
```

## Prerequisites

- Ubuntu host with Docker Engine and the Docker Compose plugin.
- The repository checked out on the Ubuntu host.
- A domain managed by Cloudflare.
- A remotely managed Cloudflare Tunnel and its **Tunnel token**.

A Tunnel token is not a Cloudflare API token, Global API Key, or Tunnel UUID.
In Cloudflare Zero Trust, open **Networks -> Tunnels**, select the tunnel, and
choose **Add a replica** or **Configure -> Docker**. Cloudflare displays a
command similar to:

```bash
docker run cloudflare/cloudflared:latest tunnel --no-autoupdate run --token eyJhIjoi...
```

Only the value after `--token` belongs in the application's `.env` file.

## 1. Prepare the environment file

From the repository root, create `.env` by running the deployment script once,
or create it manually. It must contain at least:

```dotenv
POSTGRES_PASSWORD=replace-with-a-strong-random-password
JWT_SECRET=replace-with-a-long-random-secret
TUNNEL_TOKEN=eyJhIjoi...
DISABLE_DEMO_ACCOUNTS=1
```

Generate secure application secrets when needed:

```bash
openssl rand -base64 24
openssl rand -hex 32
```

The `.env` file is ignored by Git. Never commit or paste the Tunnel token,
database password, or JWT secret into source control, an issue, or deployment
logs.

## 2. Configure the published application in Cloudflare

In **Cloudflare Zero Trust -> Networks -> Tunnels**, select the tunnel and add
a **Published application** route:

```text
Hostname:     openconstructionerp.clover4leaf.store
Service type: HTTP
Service URL:  http://frontend:80
```

Use `frontend`, not `localhost`. Inside the `cloudflared` container,
`localhost` means the connector container itself. Docker DNS resolves
`frontend` to the frontend container on the shared Compose network.

Do not select HTTPS for the origin service. The browser-to-Cloudflare
connection is still HTTPS; HTTP is used only inside the private Docker network.
Cloudflare creates the DNS route automatically when the zone uses full
Cloudflare DNS.

## 3. Run the deployment

Make the deployment script executable once:

```bash
chmod +x deploy-openconstructionerp.sh
```

Run it in Cloudflare Tunnel mode:

```bash
./deploy-openconstructionerp.sh \
  --domain openconstructionerp.clover4leaf.store \
  --cloudflare-tunnel
```

This mode performs the following actions:

- Builds and starts PostgreSQL, backend, frontend, and `cloudflared`.
- Sets `ALLOWED_ORIGINS` to the public HTTPS hostname.
- Gives slow first-boot database migrations and seed work enough healthcheck
  time on modest hardware.
- Does not publish the frontend on a host port.
- Does not install Nginx or Certbot.
- Does not open inbound firewall ports 80 or 443.

The equivalent Compose command is:

```bash
docker compose \
  --profile tunnel \
  -f docker-compose.prod.yml \
  -f docker-compose.tunnel.yml \
  up -d --build
```

Always include `docker-compose.tunnel.yml` for Tunnel deployments. That override
removes the frontend host-port publication because `cloudflared` reaches it
directly through Docker networking.

## 4. Verify the deployment

Check container state:

```bash
docker compose \
  --profile tunnel \
  -f docker-compose.prod.yml \
  -f docker-compose.tunnel.yml \
  ps
```

Expected state:

```text
postgres     Up (healthy)
backend      Up (healthy)
frontend     Up (healthy)
cloudflared  Up
```

Check Tunnel registration:

```bash
docker logs openconstructionerp-cloudflared-1 --tail=100
```

Healthy logs include `Registered tunnel connection` and a configuration entry
like:

```text
"hostname":"openconstructionerp.clover4leaf.store"
"service":"http://frontend:80"
```

Verify the public endpoint:

```bash
curl -I https://openconstructionerp.clover4leaf.store
```

The expected response is `HTTP/2 200`.

## Updating and routine operation

Re-run the deployment script to update and recreate services safely:

```bash
./deploy-openconstructionerp.sh \
  --domain openconstructionerp.clover4leaf.store \
  --cloudflare-tunnel
```

Follow logs:

```bash
docker compose \
  --profile tunnel \
  -f docker-compose.prod.yml \
  -f docker-compose.tunnel.yml \
  logs -f backend frontend cloudflared
```

Restart the stack:

```bash
docker compose \
  --profile tunnel \
  -f docker-compose.prod.yml \
  -f docker-compose.tunnel.yml \
  restart
```

## Troubleshooting

### `Permission denied` when running the deployment script

Set its executable bit:

```bash
chmod +x deploy-openconstructionerp.sh
```

Alternatively, invoke it explicitly with Bash:

```bash
bash deploy-openconstructionerp.sh \
  --domain openconstructionerp.clover4leaf.store \
  --cloudflare-tunnel
```

### Host port 80 or 8080 is already in use

CasaOS commonly owns host port 80 through `casaos-gateway`. A Tunnel deployment
does not need either port 80 or 8080 on the host. Confirm that the Tunnel
override is present in every manual Compose command:

```bash
docker compose \
  --profile tunnel \
  -f docker-compose.prod.yml \
  -f docker-compose.tunnel.yml \
  up -d
```

If `docker-compose.tunnel.yml` is omitted, the production file may attempt to
publish a host port and conflict with an existing service.

### Backend is reported unhealthy during the first deployment

The first boot creates the schema and may seed reference or demo data. On older
hardware this can take more than two minutes. Follow progress with:

```bash
docker logs -f openconstructionerp-backend-1
```

Normal startup eventually reports `Application startup complete` and begins
returning `200 OK` from `/api/health`. The production healthcheck includes a
three-minute start period for this work.

Warnings about Qdrant or a missing embedding model disable semantic search but
do not prevent the core application from starting.

### Frontend runs but is marked unhealthy

Inspect the healthcheck history:

```bash
docker inspect openconstructionerp-frontend-1 \
  --format '{{range .State.Health.Log}}{{println .End "exit=" .ExitCode}}{{println .Output}}{{end}}'
```

The frontend healthcheck intentionally uses `http://127.0.0.1:80/`, not
`http://localhost:80/`. Newer nginx-alpine images can resolve `localhost` to
IPv6 `::1` while this Nginx configuration listens on IPv4, which otherwise
causes a misleading `Connection refused` result even though Nginx is running.

Rebuild and recreate the frontend after updating the healthcheck:

```bash
docker compose \
  --profile tunnel \
  -f docker-compose.prod.yml \
  -f docker-compose.tunnel.yml \
  up -d --build --force-recreate frontend cloudflared
```

### `Provided Tunnel token is not valid`

Inspect the connector logs:

```bash
docker logs openconstructionerp-cloudflared-1 --tail=100
```

Open `.env` and replace `TUNNEL_TOKEN` with only the `eyJ...` value shown after
`--token` in Cloudflare's Docker connector command. Do not use an API token and
do not paste the full `docker run` command into `.env`.

Recreate the connector:

```bash
docker compose \
  --profile tunnel \
  -f docker-compose.prod.yml \
  -f docker-compose.tunnel.yml \
  up -d --force-recreate cloudflared
```

### Cloudflare returns 502 Bad Gateway

First confirm the connector is running and that the Cloudflare route says
`http://frontend:80`:

```bash
docker compose \
  --profile tunnel \
  -f docker-compose.prod.yml \
  -f docker-compose.tunnel.yml \
  ps

docker logs openconstructionerp-cloudflared-1 --since 5m
```

Confirm that the connector and frontend share the same network:

```bash
docker inspect openconstructionerp-cloudflared-1 \
  --format '{{json .NetworkSettings.Networks}}'

docker inspect openconstructionerp-frontend-1 \
  --format '{{json .NetworkSettings.Networks}}'
```

Both must include `openconstructionerp_default`.

Test Docker DNS and the frontend from the same network:

```bash
docker run --rm \
  --network openconstructionerp_default \
  curlimages/curl:latest \
  -v http://frontend:80/
```

#### Multiple connectors on one Tunnel

Cloudflare treats multiple connectors using the same Tunnel token as replicas
and may send a request to any of them. Every replica must be able to reach every
origin in that Tunnel's published application configuration.

For example, if one Tunnel publishes both:

```text
code.clover4leaf.store                -> http://code-server:8443
openconstructionerp.clover4leaf.store -> http://frontend:80
```

but one connector only joins `code-server_default` and another only joins
`openconstructionerp_default`, requests intermittently return 502. List all
local connectors:

```bash
docker ps \
  --filter ancestor=cloudflare/cloudflared \
  --format 'table {{.Names}}\t{{.Networks}}\t{{.Status}}'
```

For an immediate repair, join both replicas to both required networks:

```bash
docker network connect openconstructionerp_default cloudflared

docker network connect code-server_default \
  openconstructionerp-cloudflared-1

docker restart cloudflared openconstructionerp-cloudflared-1
```

Then test repeatedly because Cloudflare can select either replica:

```bash
for i in {1..10}; do
  curl -s -o /dev/null \
    -w '%{http_code}\n' \
    https://openconstructionerp.clover4leaf.store
done
```

Every request should return `200`.

Manually attached networks survive a normal container restart but are lost when
Compose recreates the container. The recommended permanent design is one Tunnel
per independent Compose application. Give OpenConstructionERP its own Tunnel
token and published hostname so its connector only needs
`openconstructionerp_default`.

## Security and upload-size notes

- Keep the frontend unpublished on the host when using Tunnel mode.
- Keep `.env` permissions restrictive, for example `chmod 600 .env`.
- Do not open or forward inbound ports 80, 443, or 8080 solely for Cloudflare
  Tunnel. The connector establishes outbound connections to Cloudflare.
- Cloudflare's proxied request-body limit depends on the account plan. Large
  BIM, IFC, CAD, or point-cloud uploads can receive HTTP 413 even though the
  bundled Nginx frontend accepts bodies up to 2 GB. Use chunked uploads or an
  appropriately sized Cloudflare plan for files above the plan limit.

