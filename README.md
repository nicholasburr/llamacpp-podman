# llamacpp-podman

Shared build system **and** template for the **llama.cpp (ROCm, `gfx1151`) podman**
image family. This repo is a single copy shared across the whole family of
per-model deployment repos via a **git submodule** — it is symlinked into every
consumer, so the same `Makefile` and `Containerfile` work everywhere:

| File | Purpose |
|---|---|
| `Containerfile` | podman build recipe (builder + runtime stages) for the llama.cpp ROCm image |
| `Makefile` | shared build system — build/sync everywhere; `deploy`/`logs`/`stop` in consumers |
| `TAGS` | version source of truth (`LLAMA_TAG` / `ROCM_VERSION` / `FEDORA_VERSION`) |
| `templates/` | `@@PLACEHOLDER@@` files that `init.sh` renders into a new project |

The GPU target is hardcoded to **`gfx1151`** (AMD Strix Halo / Ryzen AI Max+ 395)
and ROCm is installed with **pip wheels** (no repo.radeon.com RPMs). This repo
builds the image but runs **no model** — it has no `compose.yaml` or quadlet units,
so `deploy`/`logs`/`stop` report "nothing to do" here. Consumer projects add this
repo as a submodule and let `init.sh` generate their own model-specific files.

## Using this repo as a submodule (deploy a model)

Add it as a git submodule to a new per-model project, and `init.sh` templates the
model-specific files in place. A project serves exactly **one** model — that model
is written to a `PROJECT` file at `init.sh` and is **immutable** for the life of the
project (the container name, image name and alias are all derived from it). To serve
a different model, initialize a brand-new project. All version bumps (llama.cpp /
ROCm / Fedora) are managed here, in the submodule.

```sh
# 1. new project
mkdir my-model && cd my-model && git init
# 2. add this repo as a submodule (it "unpacks" on checkout)
git submodule add <this-repo-url> shared
# 3. one-time: template TAGS, compose.yaml, config/ and README for your model
bash shared/init.sh MODEL=unsloth/Your-Model-GGUF:QUANT
#    optional overrides: NAME=.. ALIAS=.. HOME_DIR=/home/you DOC_URL=..
# 4. commit the generated project
git add -A && git commit -m 'bootstrap'
# 5. deploy
make deploy
```

`init.sh` derives the container name from the model (e.g. `unsloth/Foo-Bar-GGUF:Q4`
→ `foo-bar`), pulls the current `LLAMA_TAG` / `ROCM_VERSION` / `FEDORA_VERSION`
from this repo's `TAGS`, writes `PROJECT` (the immutable model), `TAGS`
(per-project versions), `compose.yaml`,
`config/containers/systemd/<name>/*.{build,container}` and `README.md` into the
project root, and symlinks `Makefile` + `Containerfile` from `shared/`. From then
on the plain `make <target>` works, since `Makefile` is now symlinked. The `PROJECT`
file is set once and never rewritten — re-running `init.sh` with a different
`MODEL` is refused.

### Updating versions later (managed by the submodule)

```sh
git submodule update --remote shared   # move to the submodule's latest commit
make sync-versions                     # copy the three version keys into TAGS
make sync && make build && make deploy # rebuild + redeploy with the new image
```

`MODEL` lives in the project's `PROJECT` file — set once at `init.sh`, never
version-managed, and immutable (a new model means a new project).

## The Makefile

The Makefile is the single interface and works identically in this repo and in
every consumer. The image tag is **computed, never hand-typed**: `TAGS` (repo root)
is the single source of truth and the Makefile derives:

    IMAGE_TAG = <LLAMA_TAG>-rocm-<ROCM_VERSION>   e.g. v0.6.0-rocm-10.1.0
    IMAGE     = <IMAGE_NAME>:<IMAGE_TAG>          e.g. localhost/my-model:v0.6.0-rocm-10.1.0

Run `make help` for the full, current list. In short:

**End-user targets (consumer projects)** — everything you need to run the model:

| Command | Effect |
|---|---|
| `make deploy` | install the quadlet units and start the service (user systemd, no root) |
| `make status` | show the build config, local images, and the deployed container |
| `make logs` | follow the service logs (`journalctl --user -fu <name>`) |
| `make stop` | stop the service |
| `make clean` | stop the service; remove the container and the built image |

**Maintainer targets** (this repo and consumers) — build & update the image:

| Command | Effect |
|---|---|
| `make build` | `podman build` with `TAG=<LLAMA_TAG>` pinned; tags `IMAGE` |
| `make parametric-build TAG=<v-or-b-tag> [ROCM=x.y.z] [FEDORA=n]` | point `TAGS` at a llama.cpp release (`vX.Y.Z`) or nightly (`bXXXXX`) tag |
| `make sync` | rewrite the image ref / build args / model ref in all file-based methods; tag HEAD with the image tag |

**Version sync** (consumer):

| Command | Effect |
|---|---|
| `make sync-versions` | pull `LLAMA_TAG`/`ROCM_VERSION`/`FEDORA_VERSION` from the submodule into `TAGS` |

In this repo there is no model and no quadlet units, so `deploy`/`logs`/`stop`
report "nothing to do" and `sync` only tags HEAD. The maintainer flow here is:

    make parametric-build TAG=<v-or-b-tag>   # 1. point TAGS at a tag
    make build                                # 2. build the image
    make sync                                 # 3. tag HEAD so consumers can pin it