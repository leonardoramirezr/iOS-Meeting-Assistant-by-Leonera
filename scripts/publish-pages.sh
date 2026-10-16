#!/usr/bin/env bash
# Publica un build firmado en GitHub Pages (rama gh-pages), con una carpeta por etiqueta.
#
# La rama se reescribe en cada publicación como un único commit huérfano para que los
# IPA no se acumulen en el historial. Se conservan solo las carpetas con build.json
# (la rama pudo crearse desde el código), todas las versiones de main y los últimos
# KEEP_BRANCH_BUILDS builds de otras ramas.
#
# Variables de entorno:
#   TAG            Etiqueta del build (0.3.0 o build-42-1a2b3c4). Obligatoria.
#   IPA_PATH       Ruta del IPA firmado. Obligatoria.
#   ICON_57        Icono PNG de 57 px. Obligatoria.
#   ICON_512       Icono PNG de 512 px. Obligatoria.
#   BASE_URL       URL base de GitHub Pages, terminada en "/". Obligatoria.
#   CHANNEL        "stable" (main) o "prerelease". Obligatoria.
#   VERSION        CFBundleShortVersionString. Obligatoria.
#   BUILD_NUMBER   CFBundleVersion. Obligatoria.
#   BUNDLE_ID      Bundle ID de la app. Obligatoria.
#   APP_TITLE      Nombre visible de la app. Obligatoria.
#   BRANCH, COMMIT_SHA, COMMIT_MESSAGE, RUN_URL, RUN_NUMBER, DEVICE_COUNT  Metadatos opcionales.
#   KEEP_BRANCH_BUILDS  Builds de ramas que se conservan (20 por defecto).
#   PAGES_BRANCH   Rama de Pages (gh-pages por defecto).
#   REMOTE         Remoto de git (origin por defecto).
#
# Si existe $GITHUB_OUTPUT, escribe page_url, manifest_url e install_url.

set -euo pipefail

: "${TAG:?Falta TAG}"
: "${IPA_PATH:?Falta IPA_PATH}"
: "${ICON_57:?Falta ICON_57}"
: "${ICON_512:?Falta ICON_512}"
: "${BASE_URL:?Falta BASE_URL}"
: "${CHANNEL:?Falta CHANNEL}"
: "${VERSION:?Falta VERSION}"
: "${BUILD_NUMBER:?Falta BUILD_NUMBER}"
: "${BUNDLE_ID:?Falta BUNDLE_ID}"
: "${APP_TITLE:?Falta APP_TITLE}"
export KEEP_BRANCH_BUILDS="${KEEP_BRANCH_BUILDS:-20}"
PAGES_BRANCH="${PAGES_BRANCH:-gh-pages}"
REMOTE="${REMOTE:-origin}"

case "$BASE_URL" in
  */) ;;
  *) BASE_URL="$BASE_URL/" ;;
esac
export BASE_URL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_DIR_ABS="$(git rev-parse --absolute-git-dir)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git_() { git --git-dir="$GIT_DIR_ABS" "$@"; }

export GIT_AUTHOR_NAME="github-actions[bot]"
export GIT_AUTHOR_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# --- Carpeta del build nuevo -------------------------------------------------
BUILD_DIR="$WORK/new/$TAG"
mkdir -p "$BUILD_DIR"
IPA_NAME="$(basename "$IPA_PATH")"
cp "$IPA_PATH" "$BUILD_DIR/$IPA_NAME"
cp "$ICON_57" "$BUILD_DIR/icon-57.png"
cp "$ICON_512" "$BUILD_DIR/icon-512.png"
export IPA_NAME
python3 "$SCRIPT_DIR/pages_site.py" build "$BUILD_DIR"

# --- Publicación con reintentos ----------------------------------------------
attempt=1
max_attempts=6
while :; do
  echo "Publicando $TAG en $PAGES_BRANCH (intento $attempt/$max_attempts)…"
  old=""
  if git_ fetch --no-tags "$REMOTE" "+refs/heads/$PAGES_BRANCH:refs/remotes/$REMOTE/$PAGES_BRANCH" 2>/dev/null; then
    old="$(git_ rev-parse "refs/remotes/$REMOTE/$PAGES_BRANCH")"
  fi

  SITE="$WORK/site-$attempt"
  mkdir -p "$SITE"
  if [ -n "$old" ]; then
    EXISTING="$WORK/existing-$attempt"
    mkdir -p "$EXISTING"
    git_ archive --format=tar "$old" | tar -x -C "$EXISTING"
    for dir in "$EXISTING"/*/; do
      [ -d "$dir" ] || continue
      name="$(basename "$dir")"
      if [ -f "$dir/build.json" ] && [ "$name" != "$TAG" ]; then
        cp -R "$dir" "$SITE/$name"
      fi
    done
  fi
  cp -R "$BUILD_DIR" "$SITE/$TAG"
  python3 "$SCRIPT_DIR/pages_site.py" site "$SITE"
  touch "$SITE/.nojekyll"

  INDEX_FILE="$WORK/index-$attempt"
  (
    cd "$SITE"
    GIT_INDEX_FILE="$INDEX_FILE" git --git-dir="$GIT_DIR_ABS" --work-tree=. add -A --force .
  )
  tree="$(GIT_INDEX_FILE="$INDEX_FILE" git_ write-tree)"
  commit="$(git_ commit-tree "$tree" -m "Publicar $TAG ($CHANNEL)")"

  if git_ push --force-with-lease="refs/heads/$PAGES_BRANCH:$old" "$REMOTE" "$commit:refs/heads/$PAGES_BRANCH"; then
    echo "Publicado: ${BASE_URL}${TAG}/"
    break
  fi

  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "::error title=GitHub Pages::No se pudo publicar en $PAGES_BRANCH tras $max_attempts intentos."
    exit 1
  fi
  # Otro build publicó a la vez: se vuelve a leer la rama y se reintenta.
  sleep $(( attempt * 5 + RANDOM % 5 ))
  attempt=$(( attempt + 1 ))
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  python3 "$SCRIPT_DIR/pages_site.py" urls >> "$GITHUB_OUTPUT"
fi
