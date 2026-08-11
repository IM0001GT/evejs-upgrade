#!/usr/bin/env bash
# Package the upgrade tool only (no EveJS server, no private data).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd || true)"
if [[ -n "${ROOT}" && -f "${ROOT}/compose.yaml" ]]; then
  DIST="${ROOT}/dist"
else
  DIST="${SCRIPT_DIR}/dist"
fi
VERSION="${EVEJS_UPGRADE_VERSION:-1.0.0}"
NAME="evejs-upgrade-v${VERSION}"
STAGE="${DIST}/.stage-${NAME}"

echo "==> Packaging ${NAME}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/evejs-upgrade" "${DIST}"

cp -a \
  "${SCRIPT_DIR}/upgrade-to-0.12.5.sh" \
  "${SCRIPT_DIR}/README.md" \
  "${SCRIPT_DIR}/GUIDE.md" \
  "${SCRIPT_DIR}/package-kit.sh" \
  "${STAGE}/evejs-upgrade/"

chmod +x "${STAGE}/evejs-upgrade/upgrade-to-0.12.5.sh" "${STAGE}/evejs-upgrade/package-kit.sh"

# Refuse private paths
if grep -RInE '/home/[a-zA-Z0-9_-]{3,}|/run/media/|/Users/[A-Za-z0-9]' \
  "${STAGE}/evejs-upgrade" \
  --include='*.md' --include='*.sh' \
  --exclude='package-kit.sh' 2>/dev/null; then
  echo "ERROR: machine-specific paths in package" >&2
  exit 1
fi

cat > "${STAGE}/evejs-upgrade/INSTALL.txt" <<'EOF'
evejs-upgrade
=============

1. Download official EveJS v0.12.5 zip yourself.
2. Place this folder at:  <your-evejs-install>/tools/evejs-upgrade/
3. chmod +x tools/evejs-upgrade/upgrade-to-0.12.5.sh
4. ./tools/evejs-upgrade/upgrade-to-0.12.5.sh --zip /path/to/EveJS-v0.12.5.zip

See GUIDE.md. Does not include the EveJS server release.
EOF

tar -C "${STAGE}" -czf "${DIST}/${NAME}.tar.gz" evejs-upgrade
python3 - <<PY
import pathlib, zipfile
stage = pathlib.Path("${STAGE}")
out = pathlib.Path("${DIST}/${NAME}.zip")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    root = stage / "evejs-upgrade"
    for path in root.rglob("*"):
        if path.is_file():
            zf.write(path, path.relative_to(stage).as_posix())
print(out)
PY
(
  cd "${DIST}"
  sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256"
  sha256sum "${NAME}.zip" > "${NAME}.zip.sha256"
)
rm -rf "${STAGE}"
echo "Wrote ${DIST}/${NAME}.tar.gz and .zip"
