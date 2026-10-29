# vizmo GARM image

This branch builds `ghcr.io/vizmo-vms/garm` from upstream GARM with two changes:

- The Azure provider comes from
  [vizmo-vms/garm-provider-azure](https://github.com/vizmo-vms/garm-provider-azure/tree/vizmo),
  which adds Spot VMs (`"spot": true` in a scale set's extra specs), rollback of
  failed creates and Standard public IPv4 addresses. The workflow pins it by commit.
- `garm-entrypoint.sh` can write the GARM and Azure provider configs from
  environment variables, so GARM runs on Coolify with env vars and one volume.

## Environment

| Variable | Required | Default | Notes |
|---|---|---|---|
| `GARM_RENDER_CONFIG` | yes | `false` | `true` writes the configs from the variables below. Otherwise `/etc/garm/config.toml` must be mounted, as upstream. |
| `AZURE_LOCATION` | yes | | For example `newzealandnorth`. |
| `AZURE_SUBSCRIPTION_ID` | yes | | |
| `AZURE_TENANT_ID` | yes | | Service principal. |
| `AZURE_CLIENT_ID` | yes | | Service principal. |
| `AZURE_CLIENT_SECRET` | yes | | Service principal. |
| `GARM_DATA_DIR` | no | `/var/lib/garm` | Mount a persistent volume here. Holds the database and generated secrets. |
| `GARM_JWT_SECRET` | no | generated | Generated on first start and kept in the data dir. |
| `GARM_DB_PASSPHRASE` | no | generated | 32 characters. Generated on first start and kept in the data dir; never change it once the database exists. |
| `GARM_AZURE_PROVIDER_NAME` | no | `azure` | Provider name shown in GARM. |
| `AZURE_VNET_CIDR` | no | `10.10.0.0/24` | Address space of each runner's own network. |
| `AZURE_ACCELERATED_NETWORKING` | no | `true` | |
| `GARM_PORT` | no | `9997` | |
| `GARM_LOG_LEVEL` | no | `info` | |

Values must not contain a single quote.

## First start

Open the GARM URL, finish the first-run page (it fills the callback, metadata
and webhook URLs from the address you use, so open it through the public
hostname), then add GitHub credentials, the organization and scale sets in the
web UI.
