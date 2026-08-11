# EveJS upgrade guide (→ stock v0.12.5)

## Who this is for

You already run an older EveJS (or evejs-xeve) private server in Docker and want
to move to the official **0.12.5** release without losing characters.

## Before you start

1. **Download** the official EveJS v0.12.5 zip from the project’s release channel  
   (Discord / author distribution — not included here).
2. Confirm Docker works: `docker compose version`
3. Optional: free disk for a full tree backup (~size of your install folder)

## Step-by-step

### 1. Install this tool

Copy `tools/evejs-upgrade/` into your existing server tree, **or** keep it
anywhere and pass `--root`.

### 2. Dry run

```bash
cd /path/to/your-evejs-install
./tools/evejs-upgrade/upgrade-to-0.12.5.sh \
  --zip ~/Downloads/EveJS\ -\ v0.12.5.zip \
  --dry-run
```

Check:

- install root  
- detected Docker volume name  
- path to the 0.12.5 release  

### 3. Upgrade

```bash
./tools/evejs-upgrade/upgrade-to-0.12.5.sh \
  --zip ~/Downloads/EveJS\ -\ v0.12.5.zip
```

Answer `y` when prompted (or pass `--yes`).

### 4. Verify

```bash
docker compose ps
curl -s http://127.0.0.1:26002/health
cat config/version.json
# portraits (if you had any)
curl -sI http://127.0.0.1:26001/Character/<charId>_256.jpg
```

Log in with the client. Character select portraits should load.

## Timers (solo-friendly)

Default behavior tries to keep accelerated training/structure timers:

| Key | Typical solo value | Stock |
|-----|--------------------|-------|
| `skillTrainingSpeed` | 3600 | 1 |
| `upwellTimerScale` | 0.01 | 1 |

Edit `config/gameplay.json`, then `docker compose restart server`.

Force values:

```bash
./tools/evejs-upgrade/upgrade-to-0.12.5.sh --zip ... \
  --skill-speed 3600 --upwell-scale 0.01
```

Stock timers:

```bash
./tools/evejs-upgrade/upgrade-to-0.12.5.sh --zip ... --no-keep-timers
```

## Character portraits (imported only)

0.12.5 stores portraits on the **Docker volume** under:

```text
gameStore/images/Character/
```

Older installs kept them in:

```text
server/src/_secondary/image/generated/Character/
```

The upgrade script:

1. **Copies** legacy host JPGs into the volume  
2. Bind-mounts the legacy Character folder  
3. **Auto-restores faces for TQ-imported characters only**  
   - Detects `tqImport.sourceCharacterID` on the character row  
   - Reuses host JPGs or re-downloads from `images.evetech.net`  
   - **Skips pure local-created characters** (no import metadata)  

If you also have `tools/tq-import`, the upgrade prefers:

```bash
node tools/tq-import/tq-import.js restore-portraits
```

Manual face-only restore later:

```bash
node tools/tq-import/tq-import.js restore-portraits
node tools/tq-import/tq-import.js restore-portraits --sync-only
```

If portraits are still missing:

```bash
VOL=$(docker volume ls -q | grep -E 'evejs.*data' | head -1)
docker run --rm -v "$VOL:/data" \
  -v "$PWD/server/src/_secondary/image/generated/Character:/portraits:ro" \
  alpine sh -c 'mkdir -p /data/gameStore/images/Character && cp -a /portraits/. /data/gameStore/images/Character/'
docker compose restart server
```

## X-Eve / Living Universe

Stock 0.12.5 does **not** include Living Universe / Family Estate / hirelings.
Those features disappear with the code upgrade. Character assets in the SQLite
universe remain.

## LAN play

If you used household LAN helpers (`compose.lan.yaml`, dml-lan-play):

1. Upgrade first (local-only ports).
2. Re-enable LAN with your LAN tool, or re-apply `compose.lan.yaml` against the
   new compose env var names (`EVEJS_MICROSERVICES_PUBLIC_URL`, etc.).

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| “No 0.12.5 release found” | Pass `--zip` or `--source` explicitly |
| Volume warning / empty universe | Confirm volume name with `docker volume ls`; do not delete the data volume |
| Server unhealthy | `docker compose logs --tail 100 server` |
| Portraits missing | See portrait copy steps above |
| Want old tree back | See README rollback section |

## Safety

- Prefer stopping the stack before upgrade (the script does this).
- Keep the tree backup until you have played a session successfully.
- Never publish snapshot archives or your `_local/` folder.
