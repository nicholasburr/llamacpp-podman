#!/usr/bin/env bash
#
# init.sh — bootstrap a NEW llamacpp project from this shared submodule.
#
# Run this ONCE from the root of a fresh, empty project repo that has this
# submodule checked out at ./shared. It renders the templates/ files into the
# project root, writes the immutable PROJECT file, symlinks the shared Makefile
# + Containerfile, and prints next steps.
#
# MODEL is a one-time input: it is written to the PROJECT file and is immutable
# for the life of the project (a project serves exactly one model). Re-running
# init.sh with a DIFFERENT MODEL is refused — to serve another model, initialize
# a brand-new project. Version bumps (llama.cpp / ROCm / Fedora) are managed by
# the submodule via `make sync-versions`.
#
# Usage:
#   bash shared/init.sh MODEL=<hf-repo:quant> [NAME=..] [ALIAS=..] \
#                       [HOME_DIR=..] [DOC_URL=..] [--force] [-h|--help]

set -euo pipefail

MODEL="" NAME="" ALIAS="" HOME_DIR="" DOC_URL="" FORCE=""
SHARED="${SHARED:-shared}"

die() { echo "ERROR: $*" >&2; exit 2; }

usage() {
  cat <<'USAGE'
init.sh — bootstrap a NEW llamacpp project from this shared submodule (one-time).

Run from the root of a fresh, empty project repo that has this submodule checked
out at ./shared. It renders the templates into the project root, writes the immutable
PROJECT file, symlinks the shared Makefile + Containerfile, and prints next steps.

Usage:
  bash shared/init.sh MODEL=<hf-repo:quant> [options]

Required:
  MODEL=<hf-repo:quant>   Hugging Face repo + quant, e.g. unsloth/Your-Model-GGUF:Q4_K_XL.
                          Written to PROJECT and IMMUTABLE for the life of the project
                          (a project serves exactly one model).

Options:
  NAME=<name>             Container name (derived from MODEL if omitted)
  ALIAS=<name>            Short name for logs/status (defaults to NAME)
  HOME_DIR=<path>         $HOME path for the quadlet units (defaults to $HOME)
  DOC_URL=<url>           Repo URL written into the generated README
  --force                 Overwrite files that already exist (MODEL must still match PROJECT)
  -h, --help              Show this help menu and exit

Environment:
  SHARED                  Directory holding this submodule (default ./shared)

Examples:
  bash shared/init.sh MODEL=unsloth/Your-Model-GGUF:Q4_K_XL
  bash shared/init.sh MODEL=unsloth/Your-Model-GGUF:Q4_K_XL NAME=my-model
  bash shared/init.sh MODEL=unsloth/Your-Model-GGUF:Q4_K_XL --force    # overwrite existing project

Notes:
  * After init, MODEL is locked to PROJECT; to serve a different model, initialize a
    brand-new project.
  * Versions (llama.cpp / ROCm / Fedora) come from shared/TAGS and are bumped later
    with `git submodule update --remote shared && make sync-versions`.
USAGE
}

for a in "$@"; do
  case "$a" in
    MODEL=*)    MODEL="${a#*=}" ;;
    NAME=*)     NAME="${a#*=}" ;;
    ALIAS=*)    ALIAS="${a#*=}" ;;
    HOME_DIR=*) HOME_DIR="${a#*=}" ;;
    DOC_URL=*)  DOC_URL="${a#*=}" ;;
    FORCE=*)    FORCE="${a#*=}" ;;
    --force)    FORCE=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown argument '$a' (expected MODEL=... [NAME=..] [ALIAS=..] [HOME_DIR=..] [DOC_URL=..] [--force])" ;;
  esac
done

TPL="$SHARED/templates"

[ -n "$MODEL" ] || die "MODEL required, e.g. bash shared/init.sh MODEL=unsloth/Your-Model-GGUF:Q4_K_XL"

# Immutability guard: a project serves exactly one model (see PROJECT).
if [ -f "PROJECT" ]; then
  locked=$(awk -F= -v k="MODEL" '$1==k{print $2; exit}' PROJECT 2>/dev/null)
  if [ -n "$locked" ] && [ "$locked" != "$MODEL" ]; then
    echo "ERROR: this project is locked to MODEL=$locked (see PROJECT)." >&2
    echo "       MODEL is immutable — a project serves exactly one model." >&2
    echo "       To serve '$MODEL', initialize a brand-new project." >&2
    exit 3
  fi
fi

[ -f "$SHARED/TAGS" ] || die "$SHARED/TAGS not found — check out the shared submodule first: git submodule update --init"
[ -d "$TPL" ]         || die "$TPL not found — is this the llamacpp-podman submodule?"

tagvar() { awk -F= -v k="$1" '$1==k{print $2; exit}' "$SHARED/TAGS" 2>/dev/null; }

LLAMA_TAG=$(tagvar LLAMA_TAG)
ROCM_VERSION=$(tagvar ROCM_VERSION)
FEDORA_VERSION=$(tagvar FEDORA_VERSION)
for v in LLAMA_TAG ROCM_VERSION FEDORA_VERSION; do
  [ -n "${!v}" ] || die "$v missing from $SHARED/TAGS"
done

# Derive the container name from the model (repo basename minus a -GGUF suffix),
# lowercased and sanitized. Override with NAME=.
repo="${MODEL%%:*}"
repo="${repo##*/}"
base="${repo%-GGUF}"
base="${base%-gguf}"
NAME=$(printf '%s' "${NAME:-$base}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')
[ -n "$NAME" ] || die "could not derive a container name from MODEL=$MODEL (pass NAME=)"

ALIAS="${ALIAS:-$NAME}"
IMAGE_NAME="localhost/llamacpp"
IMAGE_TAG="f${FEDORA_VERSION}-rocm${ROCM_VERSION}-${LLAMA_TAG}"
TAGGED_IMAGE="$IMAGE_NAME:$IMAGE_TAG"
REPO_PATH="$(pwd)"
HOME_DIR="${HOME_DIR:-${HOME:-}}"
[ -n "$HOME_DIR" ] || die "HOME not set; pass HOME_DIR=/home/<you>"
DOC_URL="${DOC_URL:-https://github.com/nicholasburr/llamacpp-$NAME}"

echo "==> bootstrapping project in: $REPO_PATH"
echo "    MODEL   = $MODEL"
echo "    NAME    = $NAME"
echo "    ALIAS   = $ALIAS"
echo "    IMAGE   = $TAGGED_IMAGE"
echo "    versions from $SHARED/TAGS: LLAMA_TAG=$LLAMA_TAG ROCM_VERSION=$ROCM_VERSION FEDORA_VERSION=$FEDORA_VERSION"

# Refuse to clobber an existing project (re-run with --force to overwrite).
existing=""
for f in TAGS PROJECT compose.yaml README.md "config/containers/systemd/$NAME/$NAME.build" "config/containers/systemd/$NAME/$NAME.container" Makefile Containerfile; do
  if [ -e "$f" ] || [ -L "$f" ]; then existing="$existing $f"; fi
done
if [ -n "$existing" ] && [ -z "$FORCE" ]; then
  echo "ERROR: these files already exist:$existing" >&2
  echo "       re-run with --force (bash shared/init.sh ... --force) to overwrite." >&2
  exit 1
fi

render() {
  local tpl="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  sed -e "s|@@CONTAINER_NAME@@|$NAME|g" \
      -e "s|@@MODEL@@|$MODEL|g" \
      -e "s|@@ALIAS@@|$ALIAS|g" \
      -e "s|@@IMAGE_NAME@@|$IMAGE_NAME|g" \
      -e "s|@@IMAGE_TAG@@|$IMAGE_TAG|g" \
      -e "s|@@LLAMA_TAG@@|$LLAMA_TAG|g" \
      -e "s|@@ROCM_VERSION@@|$ROCM_VERSION|g" \
      -e "s|@@FEDORA_VERSION@@|$FEDORA_VERSION|g" \
      -e "s|@@HOME_DIR@@|$HOME_DIR|g" \
      -e "s|@@REPO_PATH@@|$REPO_PATH|g" \
      -e "s|@@DOC_URL@@|$DOC_URL|g" \
      "$tpl" > "$out"
  echo "  wrote $out"
}

rm -f TAGS PROJECT compose.yaml README.md
rm -f "config/containers/systemd/$NAME/$NAME.build" "config/containers/systemd/$NAME/$NAME.container"
render "$TPL/TAGS.tpl" TAGS
render "$TPL/PROJECT.tpl" PROJECT
render "$TPL/compose.yaml.tpl" compose.yaml
render "$TPL/quadlet.build.tpl" "config/containers/systemd/$NAME/$NAME.build"
render "$TPL/quadlet.container.tpl" "config/containers/systemd/$NAME/$NAME.container"
render "$TPL/README.md.tpl" README.md

link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    rm -f "$dst"
  elif [ -e "$dst" ]; then
    if [ -n "$FORCE" ]; then rm -f "$dst"; else echo "  skip $dst (exists and is not a symlink)"; return 0; fi
  fi
  ln -s "$src" "$dst"
  echo "  linked $dst -> $src"
}

link "$SHARED/Makefile" Makefile
link "$SHARED/Containerfile" Containerfile

printf '.git\nshared\n*.tpl\n*.bak\n*.bak-*\n' > .podmanignore
echo "  wrote .podmanignore"

# Commit the generated project. The project is expected to already be `git init`-ed
# with the shared submodule added (see the README), so `git add -A` also records
# the new .gitmodules + submodule gitlink. Skipped (with a note) when we're not in
# a git work tree or there's nothing to commit.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git add -A && git commit -m "bootstrap llamacpp-$NAME"; then
    echo "  -> committed the generated project"
  else
    echo "  note: no commit made (nothing to commit, or git user.name/user.email not set)." >&2
    echo "        when ready: git add -A && git commit -m 'bootstrap llamacpp-$NAME'" >&2
  fi
else
  echo "  note: not inside a git work tree, so no commit was made." >&2
  echo "        when ready: git add -A && git commit -m 'bootstrap llamacpp-$NAME'" >&2
fi

echo
echo "==> done. Next steps:"
echo "    make deploy          # build the image + start the service"
echo "    make status          # check it came up"
echo "    (PROJECT locks MODEL=$MODEL for this project — a new model needs a NEW project)"
echo
echo "To update llama.cpp / ROCm / Fedora later (managed by the submodule):"
echo "    git submodule update --remote shared && make sync-versions && make sync && make build && make deploy"