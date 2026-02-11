# n8n Automation

Self-hosted [n8n](https://n8n.io/) workflow automation running in Docker.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and [Docker Compose](https://docs.docker.com/compose/install/) installed

## Quick Start

1. **Copy the environment file and adjust if needed:**

   ```bash
   cp .env.example .env
   ```

2. **Start n8n:**

   ```bash
   docker compose up -d
   ```

3. **Open the UI:** visit [http://localhost:5678](http://localhost:5678) and create your owner account on first launch.

## Configuration

All settings are configurable via the `.env` file:

| Variable                      | Default          | Description                                         |
|-------------------------------|------------------|-----------------------------------------------------|
| `N8N_PORT`                    | `5678`           | Port exposed on the host                            |
| `N8N_SECURE_COOKIE`           | `false`          | Set to `true` when running behind HTTPS             |
| `DB_SQLITE_POOL_SIZE`         | `2`              | Read connection pool size; enables WAL mode when > 0 |
| `DB_SQLITE_VACUUM_ON_STARTUP` | `false`          | Run VACUUM on startup to reclaim disk space          |
| `GENERIC_TIMEZONE`            | `Europe/Zagreb`  | Timezone used by n8n for scheduling                 |
| `TZ`                          | `Europe/Zagreb`  | Container system timezone                           |

## Project Structure

```
n8n-automation/
├── docker-compose.yml   # n8n service definition
├── .env.example         # environment variable template
├── .gitignore           # ignores .env to keep secrets out of git
└── workflows/           # exported workflow JSON files
```

## Managing Workflows

### Importing a workflow

1. Open the n8n UI
2. Go to **Workflows** > **Add Workflow** > **Import from File**
3. Select a JSON file from the `workflows/` directory

### Exporting a workflow

1. Open the workflow in the n8n UI
2. Click the **three-dot menu** (top right) > **Download**
3. Save the JSON file into the `workflows/` directory to version-control it

The `workflows/` directory is also volume-mounted into the container at `/home/node/workflows`, so files placed there are accessible from within n8n as well.

## Useful Commands

```bash
# Start
docker compose up -d

# Stop
docker compose down

# View logs
docker compose logs -f n8n

# Restart
docker compose restart n8n

# Update n8n (change image tag in docker-compose.yml, then)
docker compose pull && docker compose up -d
```

## Database

n8n supports **SQLite** (default) and **PostgreSQL**. This setup uses SQLite with WAL (Write-Ahead Logging) mode enabled via `DB_SQLITE_POOL_SIZE=2`.

### SQLite + WAL vs PostgreSQL

| | SQLite + WAL | PostgreSQL |
|---|---|---|
| **Setup** | Zero config — embedded in n8n | Separate container + credentials |
| **RAM overhead** | ~0 (runs inside n8n process) | +150-300 MB |
| **Concurrency** | Parallel reads, single writer (queue-based) | Full concurrent reads + writes |
| **Lock risk** | Low with WAL, possible under heavy webhook bursts | None — row-level locking |
| **Backup** | Copy the `.sqlite` file or `tar` the volume | `pg_dump`, point-in-time recovery |
| **Multi-instance** | Single instance only | Supported |
| **Maintenance** | Set `DB_SQLITE_VACUUM_ON_STARTUP=true` to reclaim space | Autovacuum built-in |

**When to stick with SQLite + WAL:** light-to-medium usage, scheduled workflows, fewer moving parts, saving RAM on a shared server.

**When to switch to PostgreSQL:** high webhook concurrency, need for multi-instance scaling, or you already run PostgreSQL for other services.

Migrating from SQLite to PostgreSQL later is straightforward if needed.

## Data Persistence

Workflow data, credentials, and settings are stored in the `n8n_data` Docker volume. This volume persists across container restarts and recreations. To back it up:

```bash
docker run --rm -v n8n_data:/data -v $(pwd):/backup alpine tar czf /backup/n8n_backup.tar.gz -C /data .
```

To restore:

```bash
docker run --rm -v n8n_data:/data -v $(pwd):/backup alpine tar xzf /backup/n8n_backup.tar.gz -C /data
```
