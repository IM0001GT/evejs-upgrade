# evejs-upgrade — EveJS → stock v0.12.5

Shareable upgrade helper for private **EveJS** installs (including older
**evejs-xeve / X-Eve** trees).

**You must download the official EveJS v0.12.5 release yourself.**  
This tool never ships or downloads the game server.

## Quick start

1. Download official `EveJS - v0.12.5.zip` (or extract it).
2. Put this folder at `tools/evejs-upgrade/` inside your current install  
   **or** run the script with `--root /path/to/your-install`.
3. From the install root:

```bash
chmod +x tools/evejs-upgrade/upgrade-to-0.12.5.sh
./tools/evejs-upgrade/upgrade-to-0.12.5.sh --zip ~/Downloads/EveJS\ -\ v0.12.5.zip
```

Auto-detect zip/folder (Downloads, Desktop, cwd):

```bash
./tools/evejs-upgrade/upgrade-to-0.12.5.sh
```

Portrait restore for **already-imported** characters is **on by default**.  
Local-created alts (no TQ import metadata) are left alone.

```bash
# skip face restore
./tools/evejs-upgrade/upgrade-to-0.12.5.sh --zip ... --skip-restore-portraits

# always re-download imported faces from images.evetech.net
./tools/evejs-upgrade/upgrade-to-0.12.5.sh --zip ... --force-portrait-download
```

## What it does

| Step | Detail |
|------|--------|
| Stop | `docker compose stop` |
| Snapshot | If `tools/server-snapshot` exists |
| Backup | Moves current tree to `../<name>-backup-pre-0.12.5-<stamp>` |
| Install | Copies stock 0.12.5 into the install path |
| Preserve | Certs, `_local/`, custom tools, LAN compose, character/alliance images |
| Volume | Reuses your existing Docker data volume (characters/accounts/market) |
| Timers | By default keeps fast skill + structure timers if found (or 3600 / 0.01) |
| Portraits | **Required on 0.12.5:** copies legacy `generated/Character` JPGs into the Docker volume, bind-mounts Character, then **auto-restores faces for TQ-imported characters only** (`tqImport.sourceCharacterID`). Pure local-created alts are skipped. |
| Build/start | Rebuilds image and starts the stack |

**Living Universe / X-Eve code is not in stock 0.12.5** — the upgrade removes it
by installing official release code. Your **saved characters** stay in the volume.

## Options

```text
--zip PATH            Official release zip
--source PATH         Already-extracted v0.12.5 folder
--root PATH           Install to upgrade
--keep-timers         Keep skill/structure timers (default)
--no-keep-timers      Stock 1 / 1 timers
--skill-speed N       Force skillTrainingSpeed
--upwell-scale N      Force upwellTimerScale
--skip-snapshot       Skip universe snapshot
--skip-build          Do not docker compose build
--skip-start          Do not start after upgrade
--restore-portraits   Restore TQ-imported faces (default on)
--skip-restore-portraits  Do not restore imported faces
--force-portrait-download  Re-download faces even if host JPGs exist
--yes                 Non-interactive
--dry-run             Print plan only
```

## After upgrade

- Config lives under `config/*.json` (not `evejs.config.local.json`)
- Timers: `config/gameplay.json` → `skills.skillTrainingSpeed`, `structures.upwellTimerScale`
- Restart after edits: `docker compose restart server`
- Faces only later: `node tools/tq-import/tq-import.js restore-portraits`
- LAN (if you use dml-lan-play): re-run `lan-play.sh evejs enable` if needed

## Rollback

```bash
cd /path/to/install
docker compose down
mv /path/to/install /path/to/install.failed
mv /path/to/install-backup-pre-0.12.5-STAMP /path/to/install
cd /path/to/install && docker compose up --detach
```

## Package this tool only

```bash
bash tools/evejs-upgrade/package-kit.sh
# → dist/evejs-upgrade-v*.zip (no EveJS server code, no private data)
```

## Requirements

- Docker + Compose v2  
- `unzip` (when using `--zip`)  
- `python3` (recommended; used for compose/timer patching)  
- Official EveJS **0.12.5** zip or tree  

Trusted private use only. EveJS remains a localhost-oriented project unless you
add your own LAN tooling.
