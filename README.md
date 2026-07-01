# Pi-hole Helm Chart

A Helm chart for [Pi-hole](https://pi-hole.net), a network-wide ad blocker.

## Table of Contents

- [Prerequisites](#prerequisites)
  - [MicroK8s setup](#microk8s-setup)
- [Installation](#installation)
  - [1. Generate credentials](#1-generate-credentials)
  - [2. Publish and install the chart](#2-publish-and-install-the-chart)
    - [OCI registry (recommended)](#oci-registry-recommended)
      - [MicroK8s built-in registry](#microk8s-built-in-registry)
      - [GitHub Container Registry (GHCR)](#github-container-registry-ghcr)
    - [Classic HTTP repository (GitHub Pages)](#classic-http-repository-github-pages)
  - [3. Point your devices at Pi-hole](#3-point-your-devices-at-pi-hole)
- [Configuration](#configuration)
  - [Extra FTL environment variables](#extra-ftl-environment-variables)
  - [Updating the password](#updating-the-password)
  - [Using a pre-existing Secret](#using-a-pre-existing-secret)
- [DNS Service](#dns-service)
  - [Pin a stable DNS IP](#pin-a-stable-dns-ip)
- [Web Interface](#web-interface)
- [Monitoring](#monitoring)
  - [Uptime Kuma](#uptime-kuma)
- [Optional Features](#optional-features)
  - [DHCP](#dhcp)
  - [Migrating from Pi-hole v5](#migrating-from-pi-hole-v5)
- [Storage](#storage)
- [Backup and Restore](#backup-and-restore)
- [License](#license)

## Prerequisites

- Helm 3
- A Kubernetes cluster with:
  - The [Gateway API CRDs](https://gateway-api.sigs.k8s.io/guides/#install-standard-channel) installed
  - A Gateway controller (e.g. Traefik) and a `Gateway` resource named `traefik-gateway` in the `ingress` namespace
  - A `StorageClass` available (default: `ceph-rbd`)
  - A LoadBalancer provisioner (e.g. MetalLB) for the DNS service
- A kubeconfig pointing at the cluster. If you're running Helm from a machine that is not a cluster node, copy the kubeconfig from any node and replace the loopback address with the node's LAN IP or host name. If your cluster node user is `ubuntu` and a node is `node-01.local`:

  ```bash
  ssh ubuntu@node-01.local "microk8s config" \
    | sed 's/127.0.0.1/node-01.local/' \
    > ~/.kube/microk8s.yaml
  export KUBECONFIG=~/.kube/microk8s.yaml
  ```

  To avoid setting `KUBECONFIG` in every shell session, add the export to your `~/.bashrc` or `~/.zshrc`, or merge it into your existing `~/.kube/config`:

  ```bash
  KUBECONFIG=~/.kube/config:~/.kube/microk8s.yaml \
    kubectl config view --flatten > ~/.kube/config
  ```

### MicroK8s setup

```bash
microk8s enable dns storage helm3 ingress metallb
```

## Installation

### 1. Generate credentials

```bash
bash scripts/gen-secrets.sh
```

This creates `my-secrets.yaml` (gitignored) with a random admin password.

### 2. Publish and install the chart

#### OCI registry (recommended)

OCI lets you push charts to any container registry, including the MicroK8s built-in registry.

##### MicroK8s built-in registry

The MicroK8s registry addon exposes an unauthenticated registry on port 32000 on every node. Use any node's hostname to reach it from your laptop.

```bash
# Package the chart
helm package charts/pihole

# Push (Helm 3.8+)
helm push pihole-*.tgz oci://node-01.local:32000/charts --plain-http
```

View published charts:

```bash
# List all repositories in the registry
curl -s http://node-01.local:32000/v2/_catalog | jq

# List available versions of the chart
curl -s http://node-01.local:32000/v2/charts/pihole/tags/list | jq

# Inspect chart metadata for a specific version
helm show chart oci://node-01.local:32000/charts/pihole --version 0.1.0 --plain-http
```

Install directly from it:

```bash
helm upgrade --install pihole oci://node-01.local:32000/charts/pihole \
  --version 0.1.0 --plain-http \
  --namespace pihole --create-namespace \
  -f my-secrets.yaml \
  --set 'httpRoute.hostnames[0]=adblock.internal' \
  --set dnsService.loadBalancerIP=<dns-lb-ip>
```

##### GitHub Container Registry (GHCR)

**Using the `gh` CLI** (recommended; uses credentials from `gh auth login`, no token management needed):

```sh
gh auth status
```

`gh auth login` does not request `write:packages` by default. Add it once before pushing:

```bash
gh auth refresh -s write:packages
```

```sh
helm package charts/pihole
```

```bash
cat ~/.config/helm/registry/config.json
# if GHCR is not in the auths section:
gh auth token | helm registry login ghcr.io --username <github-user> --password-stdin

helm push pihole-*.tgz oci://ghcr.io/<github-user>/charts
```

GHCR defaults new packages to private. `helm push` uses the OCI protocol which has no visibility concept, so there is no way to set it at push time. Make the package public once after the first push; it stays public for all subsequent pushes to the same package. Go to **github.com → your profile → Packages → charts/pds → Package settings → Change visibility → Public**.

View published versions
```sh
gh api /user/packages/container/charts%2Fpihole/versions --jq '.[].metadata.container.tags'
```

**Using a personal access token (PAT):** Create one at **GitHub → Settings → Developer settings → Personal access tokens** with `write:packages` scope, then set it in your shell:

```bash
export GITHUB_TOKEN=ghp_...
```

```bash
echo $GITHUB_TOKEN | helm registry login ghcr.io --username <github-user> --password-stdin

helm push pihole-*.tgz oci://ghcr.io/<github-user>/charts
```

Install from the registry:

```bash
helm upgrade --install pihole oci://ghcr.io/<github-user>/charts/pihole \
  --version 0.1.0 \
  --namespace pihole --create-namespace \
  -f my-secrets.yaml \
  --set 'httpRoute.hostnames[0]=adblock.internal' \
  --set dnsService.loadBalancerIP=<dns-lb-ip>
```

#### Classic HTTP repository (GitHub Pages)

```bash
helm package charts/pihole -d docs/
helm repo index docs/ --url https://<your-username>.github.io/pi-hole
git add docs/ && git commit -m "Publish chart" && git push
```

```bash
helm repo add pihole https://<your-username>.github.io/pi-hole
helm upgrade --install pihole pihole/pihole \
  -f my-secrets.yaml \
  --set 'httpRoute.hostnames[0]=adblock.internal' \
  --set dnsService.loadBalancerIP=<dns-lb-ip>
```

**Local network access by hostname:** Add a corresponding entry to `/etc/hosts` on any machine that needs to reach the web UI. Any node IP works since Traefik runs as a DaemonSet on every node:

```
<node-ip>  adblock.internal
```

### 3. Point your devices at Pi-hole

Get the DNS service IP assigned by your LoadBalancer:

```bash
kubectl get svc pihole-dns -n pihole
```

Set this IP as the DNS server on your router (to cover all devices) or on individual devices.

**Router configuration (recommended):** Log into your router's admin interface and set the primary DNS server to the LoadBalancer IP. The exact setting is usually under **LAN → DHCP Server** or **WAN → DNS**. When configured at the router level, every device on the network uses Pi-hole automatically without per-device changes. Set a secondary DNS (e.g. `1.1.1.1`) as a fallback for when Pi-hole is unavailable.

## Configuration

All values are in `charts/pihole/values.yaml`. Key options:

| Value | Default | Description |
|---|---|---|
| `timezone` | `"UTC"` | Container timezone |
| `dnsListeningMode` | `"ALL"` | FTL DNS listening mode; keep `ALL` in Kubernetes |
| `credentials.webPassword` | `""` | Admin web UI password (required) |
| `credentials.existingSecret` | `""` | Use a pre-existing Secret instead |
| `dnsService.type` | `LoadBalancer` | DNS service type (`LoadBalancer` or `NodePort`) |
| `dnsService.loadBalancerIP` | `""` | Pin a specific IP from your LB pool |
| `httpRoute.enabled` | `true` | Create a Gateway API HTTPRoute for the web UI |
| `httpRoute.hostnames` | `[]` | Hostnames for the HTTPRoute (empty = match all) |
| `persistence.pihole.size` | `1Gi` | Storage for `/etc/pihole` |
| `persistence.pihole.storageClass` | `ceph-rbd` | StorageClass for the Pi-hole PVC |
| `capabilities.netAdmin` | `false` | Enable `NET_ADMIN` (required for DHCP) |
| `capabilities.sysTime` | `false` | Enable `SYS_TIME` (required for NTP client) |
| `capabilities.sysNice` | `false` | Enable `SYS_NICE` (optional scheduling boost) |

### Extra FTL environment variables

Any Pi-hole FTL config key can be passed as an environment variable. See the [FTL config reference](https://docs.pi-hole.net/ftldns/configfile/) for all options.

```yaml
extraEnv:
  FTLCONF_dns_upstreams: "1.1.1.1;1.0.0.1"
  FTLCONF_dns_blockESNI: "false"
```

### Updating the password

The password is injected as an environment variable from the Secret. Kubernetes does not restart pods when a Secret changes, so after updating the password you must roll the deployment:

```bash
kubectl rollout restart deployment pihole -n pihole
kubectl rollout status deployment pihole -n pihole
```

### Using a pre-existing Secret

If you manage secrets externally (e.g. with Sealed Secrets or External Secrets), create a Secret with key `web-password`, then set:

```yaml
credentials:
  existingSecret: my-pihole-secret
```

## DNS Service

Pi-hole exposes port 53 over both TCP and UDP. The chart creates a single Service with both protocols, which requires [mixed-protocol LoadBalancer support](https://kubernetes.io/docs/concepts/services-networking/service/#load-balancers-with-mixed-protocol-types) (GA in Kubernetes 1.26, supported by MetalLB 0.13+).

If your environment does not support mixed protocols, split the DNS traffic by setting `dnsService.type: NodePort` and pointing clients at the node IP and port reported by `kubectl get svc`.

### Pin a stable DNS IP

For router-level DNS configuration it is convenient to assign a fixed IP. Make sure your router's DHCP pool ends before the MetalLB range so the two never assign the same IP to different devices simultaneously. On most routers this is under **LAN → DHCP Server**.

**Avoid the first IP in the MetalLB pool.** MetalLB assigns addresses from the pool in order, so the first IP is typically claimed by whichever LoadBalancer Service was created first. In a MicroK8s cluster this is usually Traefik's ingress Service. Using the first IP for Pi-hole will result in a conflict and the DNS Service will stay in `<pending>` indefinitely. Use the second IP in the pool (or any other free address in the range) instead.

```bash
helm upgrade --install pihole ./charts/pihole \
  -f my-secrets.yaml \
  --set 'httpRoute.hostnames[0]=adblock.internal' \
  --set dnsService.loadBalancerIP=<dns-lb-ip>
```

## Web Interface

The admin interface is served at `/admin`. With the default HTTPRoute configuration it is reachable via whatever hostnames your Traefik gateway accepts.

To restrict it to a specific hostname:

```yaml
httpRoute:
  hostnames:
    - adblock.internal
```

For local access without a DNS entry, add the hostname to `/etc/hosts`:

```
<node-ip>  adblock.internal
```

Or use a Cloudflare Tunnel for external HTTPS access.

## Monitoring

### Uptime Kuma

The upstream image's [Dockerfile `HEALTHCHECK`](https://github.com/pi-hole/docker-pi-hole/blob/master/src/Dockerfile) runs a DNS lookup for `pi.hole` against `127.0.0.1`. That instruction is only honored by Docker Engine (`docker run`/Compose). Kubernetes/containerd ignores `HEALTHCHECK` entirely, so it has no effect in this chart. The `livenessProbe`/`readinessProbe` in `deployment.yaml` are what actually keep the pod healthy here.

To get the same signal in Uptime Kuma, add a **DNS** monitor pointed at the DNS Service instead. How you address that Service depends on where Uptime Kuma itself runs:

| | LoadBalancer IP | Cluster-internal DNS name |
|---|---|---|
| Works from | Anywhere on the LAN | Only pods inside the same cluster (resolved by CoreDNS) |
| Target | The IP from `kubectl get svc pihole-dns -n pihole` | `pihole-dns.pihole.svc.cluster.local` |
| Survives IP churn | No — breaks if MetalLB reassigns the IP | Yes — the name is stable regardless of IP |
| Setup | None beyond looking up the IP | Requires Uptime Kuma deployed in-cluster |

**Outside the cluster** (Uptime Kuma on a separate Docker host, VM, etc.), use the LoadBalancer IP:

1. Get the DNS service IP:

   ```bash
   kubectl get svc pihole-dns -n pihole
   ```

2. In Uptime Kuma, add a new monitor:
   - **Monitor Type:** DNS
   - **Hostname:** `pi.hole`
   - **Resolver Server:** the DNS service IP from step 1
   - **Port:** `53`
   - **Resource Record Type:** `A`

**In-cluster** (Uptime Kuma runs as a pod in the same Kubernetes cluster), use the Service's cluster-internal DNS name instead. No IP lookup needed and it keeps working even if the LoadBalancer IP changes:

- **Monitor Type:** DNS
- **Hostname:** `pi.hole`
- **Resolver Server:** `pihole-dns.pihole.svc.cluster.local`
- **Port:** `53`
- **Resource Record Type:** `A`

Either way, this mirrors the Dockerfile's own check (`dig @127.0.0.1 pi.hole`), just run against the DNS Service instead of localhost.

Optionally add a second **HTTP(s)** monitor against the admin UI so a web-server-only failure is also caught; the DNS monitor alone won't detect that. Note the web UI is a *different* Service (`<release>-web`, port 80) than the DNS one, so it needs its own address:

- Outside the cluster: use the HTTPRoute hostname (see [Web Interface](#web-interface)), e.g. `http://adblock.internal`
- In-cluster: `http://pihole-web.pihole.svc.cluster.local/admin`

## Optional Features

### DHCP

To use Pi-hole as your DHCP server you must enable `NET_ADMIN` and optionally expose UDP port 67:

```yaml
capabilities:
  netAdmin: true
```

DHCP from within a Kubernetes pod requires `hostNetwork: true`, which is outside the scope of this chart. For DHCP it is simpler to run Pi-hole directly on a host or in a dedicated VM.

### Migrating from Pi-hole v5

If you have custom dnsmasq config files from a v5 installation, enable the dnsmasq PVC for the first v6 startup to allow migration:

```yaml
persistence:
  dnsmasq:
    enabled: true
    size: 100Mi
    storageClass: ceph-rbd
```

This sets `FTLCONF_misc_etc_dnsmasq_d: "true"` automatically. You can disable it again after the migration completes.

## Storage

The chart creates one PVC by default:

| Mount | PVC name | Default size | Contents |
|---|---|---|---|
| `/etc/pihole` | `<release>-pihole` | 1Gi | Databases, blocklists, config |
| `/etc/dnsmasq.d` | `<release>-dnsmasq` | 100Mi | Custom dnsmasq files (optional) |

To bring your own PVCs:

```yaml
persistence:
  pihole:
    existingClaim: my-pihole-pvc
```

## Backup and Restore

Pi-hole's data lives entirely in `/etc/pihole` as SQLite databases and flat config files. A simple approach is to scale the deployment to zero before copying the PVC contents:

```bash
kubectl scale deployment pihole --replicas=0 -n pihole
# copy PVC data via a debug pod or a snapshot
kubectl scale deployment pihole --replicas=1 -n pihole
```

For automated off-cluster backups, attach a debug pod to the PVC and pipe a tar archive to S3:

```bash
kubectl run pihole-backup --rm -it \
  --image=alpine \
  --overrides='{"spec":{"volumes":[{"name":"pihole","persistentVolumeClaim":{"claimName":"pihole-pihole"}}],"containers":[{"name":"pihole-backup","image":"alpine","command":["sh"],"volumeMounts":[{"name":"pihole","mountPath":"/etc/pihole"}]}]}}' \
  -- tar czf - /etc/pihole | aws s3 cp - s3://my-bucket/pihole-backup.tar.gz
```

## License

GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
