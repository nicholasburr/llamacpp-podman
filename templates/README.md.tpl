# llamacpp-@@CONTAINER_NAME@@

Podman deployment of **@@MODEL@@** (served as `@@ALIAS@@`) on
[llama.cpp](https://github.com/ggml-org/llama.cpp) with **ROCm @@ROCM_VERSION@@**
on Strix Halo (AMD Ryzen AI Max+ 395, 32GB UMA), built on Fedora @@FEDORA_VERSION@@.

This project was bootstrapped from the **llamacpp-shared** git submodule
(`shared/`) with `make init MODEL=@@MODEL@@`. Everything model-specific
(`TAGS`, `compose.yaml`, `config/containers/systemd/@@CONTAINER_NAME@@/*`, this
README) is templated in place; the shared build machinery (`Makefile`,
`Containerfile`) is symlinked from the submodule.

> The GPU target is **hardcoded to `gfx1151`** (Strix Halo / Ryzen AI Max+ 395)
> in the Containerfile — this project only builds for that GPU.

## Quick start

```sh
make deploy      # build the image + install the quadlet units + start the service
make status      # container state
make logs        # follow the logs
make stop        # stop the service
```

The default deployment is **quadlet** (user systemd, no root): `make deploy`
installs the units from `config/containers/systemd/@@CONTAINER_NAME@@/` and
starts `@@CONTAINER_NAME@@.service`. A **podman compose** deployment
(`compose.yaml`) is an operator alternative that defines the identical
container — run exactly one method at a time:

| Method | Files | Start |
|---|---|---|
| quadlet (**default**) | `config/containers/systemd/@@CONTAINER_NAME@@/*.container`, `*.build` | `make deploy` |
| podman compose | `compose.yaml` | `podman compose up -d` |

Both stay in lockstep with `TAGS` via `make sync`.

## The Makefile (single interface)

| Command | Effect |
|---|---|
| `make deploy` | install quadlet units and start the service (user systemd, no root) |
| `make status` / `make logs` / `make stop` | container lifecycle |
| `make clean` | stop the service; remove the container and the built image |
| `make build` | build the active `TAGS` image |
| `make sync` | rewrite image tag / build args / model ref in the deploy files; tag HEAD |
| `make parametric-build TAG=<v-or-b-tag> [ROCM=x.y.z] [FEDORA=n]` | pin a new llama.cpp tag in `TAGS` |
| `make sync-versions` | pull `LLAMA_TAG`/`ROCM_VERSION`/`FEDORA_VERSION` from the shared submodule into `TAGS` |

`TAGS` is the single source of truth. The image tag is computed, never hand-typed:

```
IMAGE_TAG = <LLAMA_TAG>-rocm-<ROCM_VERSION>      e.g. @@IMAGE_TAG@@
IMAGE     = localhost/@@CONTAINER_NAME@@:<IMAGE_TAG>
```

## Versions are managed by the shared submodule

`LLAMA_TAG`, `ROCM_VERSION`, and `FEDORA_VERSION` live in the **submodule's**
`shared/TAGS` and are the source of truth. To pick up a new llama.cpp / ROCm /
Fedora version:

```sh
git submodule update --remote shared   # move the submodule to its latest commit
make sync-versions                     # copy the three version keys into this project's TAGS
make sync && make build && make deploy # rebuild + redeploy with the new image
```

`MODEL` (the served model) is **not** version-managed — it is this project's
one-time input and never changes (a project serves exactly one model).

## Runtime environment

The container runs `llama-server` with the runtime/feature environment
variables defined in `compose.yaml` and the quadlet `@@CONTAINER_NAME@@.container`
unit (kept in sync by `make sync`): 8 CPU threads, 262144 ctx, flash attention,
q8_0 KV cache, `draft-mtp` speculative decoding, and the Web UI / agent / tools /
reasoning feature flags. The model is pulled at runtime from `@@MODEL@@` via the
Hugging Face secret (`huggingface-token`), cached in `@@HOME_DIR@@/.cache/huggingface`.

## Caveats

- **Trusted network only:** the server listens on `0.0.0.0:8000` with no API key,
  and `LLAMA_ARG_AGENT=on` is experimental per llama.cpp ("do not enable in
  untrusted environments").
- **`ipc: host`** is required so the large model load does not exhaust the
  default ~64MB `/dev/shm`; the `podman compose` path needs the `podman-compose`
  IPC patch (see the llamacpp-shared family notes) — plain `podman run --ipc=host`
  works without it.
- **Shared iGPU:** other GPU workloads contend for the iGPU and drop throughput
  while they are mid-generation.
