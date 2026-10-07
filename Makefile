# ============================================================================
#  Shared build system for the llama.cpp (ROCm, gfx1151) podman image.
#
#  This Makefile is the single copy for the whole family of repos — shared
#  via git submodule (symlinked into every consumer project). The same
#  targets work everywhere:
#
#     - llamacpp-shared (this repo): `make build` builds the image from the
#       Containerfile and `make sync` tags HEAD with the image tag, so
#       consumers can pin the submodule to a tagged build. There is no
#       model container here, so `deploy`/`logs`/`stop` report that.
#     - consumer projects: everything above, plus `make deploy`, which
#       deploys the model container (quadlet units + user systemd).
#
#  Per-project values (IMAGE_NAME, MODEL, versions) are read from the TAGS
#  file in the CURRENT repo — consumers keep their own TAGS; this repo's
#  TAGS describes the shared image. See TAGS for the image-tag scheme.
#
#  End-user targets (consumers):
#      make deploy     install quadlet units and start the service (user systemd)
#      make status     show container state
#      make logs       follow container logs
#      make stop       stop the service
#      make clean      stop the service; remove the container and the built image
#
#  Maintainer targets (this repo and consumers):
#      make build             build the active TAGS image
#      make parametric-build  pin a new llama.cpp tag in TAGS (TAG=<tag>)
#      make sync              rewrite the deploy files + tag HEAD
# ============================================================================

SHELL := /bin/bash
MAKEFLAGS += --no-builtin-rules
.DEFAULT_GOAL := help

# The shared submodule lives at ./shared in consumer projects (it is this repo
# when run from the submodule itself). Used by `init` and `sync-versions`.
SHARED ?= shared

# ---------------------------------------------------------------------------
#  TAGS is the single source of truth for the image contents (per repo):
#
#      IMAGE_TAG = <LLAMA_TAG>-rocm-<ROCM_VERSION>     e.g. v0.6.0-rocm-10.1.0
#
#  Read KEY=VALUE from TAGS.
# ---------------------------------------------------------------------------

TAGS := TAGS
tagvar = $(strip $(shell awk -F= -v k="$(1)" '$$1==k{print $$2; exit}' $(TAGS) 2>/dev/null))

IMAGE_NAME     := $(call tagvar,IMAGE_NAME)
LLAMA_TAG      := $(call tagvar,LLAMA_TAG)
ROCM_VERSION   := $(call tagvar,ROCM_VERSION)
FEDORA_VERSION := $(call tagvar,FEDORA_VERSION)
MODEL          := $(call tagvar,MODEL)

IMAGE_TAG    := $(LLAMA_TAG)-rocm-$(ROCM_VERSION)
TAGGED_IMAGE := $(IMAGE_NAME):$(IMAGE_TAG)

# Container name defaults to the image name's basename (e.g. my-model for
# localhost/my-model); override with: make deploy CONTAINER_NAME=<name>
CONTAINER_NAME ?= $(notdir $(IMAGE_NAME))

CONTAINERFILE := Containerfile
QUADLET_SRC   := config/containers/systemd/$(CONTAINER_NAME)
DEPLOY_FILES  := compose.yaml \
                 $(QUADLET_SRC)/$(CONTAINER_NAME).build \
                 $(QUADLET_SRC)/$(CONTAINER_NAME).container

# Context detection: consumer repos have quadlet units + a user systemd
# service; this repo has neither. The Makefile is shared, so deploy/logs/
# stop are full recipes in consumers and no-ops here.
HAS_QUADLET := $(shell test -d "$(QUADLET_SRC)" && echo yes)
HAS_SERVICE := $(shell systemctl --user cat "$(CONTAINER_NAME).service" >/dev/null 2>&1 && echo yes)

LLAMA_REPO := https://github.com/ggml-org/llama.cpp.git

.PHONY: help init sync-versions deploy status logs stop clean sync build parametric-build

help: ## Print this list.
	@echo "image:     $(TAGGED_IMAGE)"
	@echo "container: $(CONTAINER_NAME)"
	@
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk '{ n=index($$0, ":"); h=index($$0, "## "); \
		       printf "  make %-42s %s\n", substr($$1,1,n-1), substr($$0,h+3) }'

deploy: ## Deploy the container as a systemd service.
ifeq ($(HAS_QUADLET),yes)
	@if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$(CONTAINER_NAME)"; then \
		if ! systemctl --user is-active --quiet $(CONTAINER_NAME).service 2>/dev/null; then \
			echo "REFUSED: a non-systemd container named '$(CONTAINER_NAME)' is present (compose or plain podman)"; \
			echo "         stop it first — podman compose down   — then re-run make deploy"; \
			exit 1; \
		fi \
	fi
	podman quadlet install --application=$(CONTAINER_NAME) --reload-systemd --replace $(QUADLET_SRC)
	systemctl --user start $(CONTAINER_NAME)-build.service
	systemctl --user start $(CONTAINER_NAME).service
	@# Warn if linger is not enabled (services only start at login, not at boot)
	@if ! loginctl show-user "$$USER" -p Linger --value 2>/dev/null | grep -qx yes; then \
		echo; \
		echo "WARNING: linger is not enabled for '$$USER'."; \
		echo "         The services only start at login, NOT at boot."; \
		echo "         To start them at boot (no login required):"; \
		echo "             sudo loginctl enable-linger $$USER"; \
		echo; \
	fi
else
	@echo "no quadlet units in this repo ($(QUADLET_SRC)) — nothing to deploy"
endif

status: ## Display current status of environment.
	@echo "Build configuration:"
	@echo "  IMAGE_NAME : $(TAGGED_IMAGE)"
	@echo "  LLAMA_TAG      : $(LLAMA_TAG)"
	@echo "  ROCM_VERSION   : $(ROCM_VERSION)"
	@echo "  FEDORA_VERSION : $(FEDORA_VERSION)"
	@echo "  MODEL          : $(MODEL)"
	@
	@echo "Available images:"
	@podman image list --filter reference=$(CONTAINER_NAME) --format '  {{.Tag}} | {{.ID}} | {{.CreatedSince}}' | grep -v latest || true
	@
	@echo "Deployed container:"
	@podman ps -a --filter name=^/$(CONTAINER_NAME) --format '  {{.Image}} | {{.ID}} | {{.Status}}' || true

logs: ## Follow systemd logs.
ifeq ($(HAS_SERVICE),yes)
	@journalctl --user -fu $(CONTAINER_NAME).service
else
	@echo "no systemd service '$(CONTAINER_NAME).service' in this repo — nothing to follow"
endif

stop: ## Stop the service
ifeq ($(HAS_SERVICE),yes)
	@systemctl --user stop $(CONTAINER_NAME).service
else
	@echo "no systemd service '$(CONTAINER_NAME).service' in this repo — nothing to stop"
endif

clean: ## Stop the service; remove the container and the built image.
	@echo "cleaning up $(CONTAINER_NAME) ..."
	@if [ -n "$(HAS_SERVICE)" ]; then \
		echo "  stopping + disabling systemd services"; \
		systemctl --user stop $(CONTAINER_NAME)-build.service $(CONTAINER_NAME).service 2>/dev/null || true; \
		systemctl --user disable $(CONTAINER_NAME)-build.service $(CONTAINER_NAME).service 2>/dev/null || true; \
	fi
	@if [ -d "$$HOME/.config/containers/systemd/$(CONTAINER_NAME)" ]; then \
		echo "  removing installed quadlet units"; \
		rm -rf "$$HOME/.config/containers/systemd/$(CONTAINER_NAME)"; \
		systemctl --user daemon-reload 2>/dev/null || true; \
	elif [ -z "$(HAS_SERVICE)" ]; then \
		echo "  no systemd service '$(CONTAINER_NAME).service' in this repo — skipping"; \
	fi
	@if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$(CONTAINER_NAME)"; then \
		echo "  removing container $(CONTAINER_NAME)"; \
		podman rm -f $(CONTAINER_NAME); \
	else \
		echo "  no container '$(CONTAINER_NAME)' to remove"; \
	fi
	@if podman image inspect "$(TAGGED_IMAGE)" >/dev/null 2>&1; then \
		echo "  removing image $(TAGGED_IMAGE)"; \
		podman rmi $(TAGGED_IMAGE) || \
			echo "  WARNING: could not remove $(TAGGED_IMAGE) (in use? check 'podman ps -a' and retry)"; \
	else \
		echo "  no image '$(TAGGED_IMAGE)' to remove"; \
	fi
	@echo "clean complete"

sync: ## Rewrite image tag, build args and model ref; tag HEAD with the image tag.
	@files=""; \
	for f in $(DEPLOY_FILES); do \
		[ -f "$$f" ] && files="$$files $$f"; \
	done; \
	if [ -n "$$files" ]; then \
		echo "syncing deploy files -> $(TAGGED_IMAGE)"; \
		for f in $$files; do \
			sed -i -E "s|$(IMAGE_NAME):[A-Za-z0-9._-]+|$(TAGGED_IMAGE)|g" $$f; \
		done; \
		if [ -f "$(QUADLET_SRC)/$(CONTAINER_NAME).build" ]; then \
			sed -i -E \
				-e "s|^BuildArg=FEDORA_VERSION=.*|BuildArg=FEDORA_VERSION=$(FEDORA_VERSION)|" \
				-e "s|^BuildArg=ROCM_VERSION=.*|BuildArg=ROCM_VERSION=$(ROCM_VERSION)|" \
				-e "s|^BuildArg=BRANCH=.*|BuildArg=TAG=$(LLAMA_TAG)|" \
				-e "s|^BuildArg=TAG=.*|BuildArg=TAG=$(LLAMA_TAG)|" \
				"$(QUADLET_SRC)/$(CONTAINER_NAME).build"; \
		fi; \
		if [ -n "$(MODEL)" ] && [ -f compose.yaml ]; then \
			old=$$(awk -F'"' '/LLAMA_ARG_HF_REPO/{print $$2; exit}' compose.yaml); \
			if [ -n "$$old" ] && [ "$$old" != "$(MODEL)" ]; then \
				echo "syncing model ref: $$old -> $(MODEL)"; \
				for f in $$files; do \
					sed -i "s|$$old|$(MODEL)|g" $$f; \
				done; \
			else \
				echo "model ref already in sync"; \
			fi; \
		else \
			echo "no model to sync (MODEL not set in TAGS / no compose.yaml)"; \
		fi; \
	else \
		echo "no deploy files in this repo — skipping file sync"; \
	fi
	@if git rev-parse -q --verify "refs/tags/$(IMAGE_TAG)" >/dev/null 2>&1; then \
		echo "git tag $(IMAGE_TAG) already exists — leaving it untouched"; \
	else \
		git tag -a "$(IMAGE_TAG)" \
			-m "llama.cpp $(LLAMA_TAG) + ROCm $(ROCM_VERSION) — image $(TAGGED_IMAGE)"; \
		echo "tagged $$(git rev-parse --short HEAD) with $(IMAGE_TAG)"; \
	fi

build: ## Build the active TAGS image, pinned to the commit in TAGS.
	@running=$$(podman inspect "$(CONTAINER_NAME)" --format '{{.Image}}' 2>/dev/null); \
	tagid=$$(podman image inspect "$(TAGGED_IMAGE)" --format '{{.Id}}' 2>/dev/null); \
	if [ -n "$$running" ] && [ -n "$$tagid" ] && [ "$$running" = "$$tagid" ]; then \
		echo "WARNING: $(TAGGED_IMAGE) is what the running '$(CONTAINER_NAME)' container uses —"; \
		echo "         the rebuild replaces it in place (production keeps its current"; \
		echo "         binary until its next restart)."; \
	fi
	podman build -f $(CONTAINERFILE) \
		--build-arg FEDORA_VERSION=$(FEDORA_VERSION) \
		--build-arg ROCM_VERSION=$(ROCM_VERSION) \
		--build-arg TAG=$(LLAMA_TAG) \
		-t $(TAGGED_IMAGE) \
		.

parametric-build: ## Pin a new llama.cpp tag in TAGS: TAG=<v-or-b-tag> [ROCM=x.y.z] [FEDORA=n].
	@test -n "$(TAG)" || { echo "usage: make parametric-build TAG=<v-or-b-tag> [ROCM=x.y.z] [FEDORA=n]"; exit 2; }
	@{ c=$$(git ls-remote $(LLAMA_REPO) "refs/tags/$(TAG)^{}" 2>/dev/null | awk '{print $$1}' | head -1); \
	  [ -n "$$c" ] || c=$$(git ls-remote $(LLAMA_REPO) "refs/tags/$(TAG)" 2>/dev/null | awk '{print $$1}' | head -1); \
	  if [ -z "$$c" ]; then echo "ERROR: tag '$(TAG)' not found on $(LLAMA_REPO)"; exit 2; fi; \
	  sed -i "s|^LLAMA_TAG=.*|LLAMA_TAG=$(TAG)|" $(TAGS); \
	  { test -z "$(ROCM)" || sed -i "s|^ROCM_VERSION=.*|ROCM_VERSION=$(ROCM)|" $(TAGS); }; \
	  { test -z "$(FEDORA)" || sed -i "s|^FEDORA_VERSION=.*|FEDORA_VERSION=$(FEDORA)|" $(TAGS); }; \
	  echo "TAGS updated -> $(IMAGE_NAME):$(TAG)-rocm-$$(awk -F= -v k=ROCM_VERSION '$$1==k{print $$2}' $(TAGS))"; \
	  echo "next: make build && make deploy"; }

# ============================================================================
#  Consumer tooling — bootstrap a new project + sync versions from the submodule
#  ----------------------------------------------------------------------------
#  `make -f shared/Makefile init MODEL=<hf-repo:quant>` renders templates/ into a
#  fresh project (TAGS, compose.yaml, the quadlet units, README.md), symlinks the
#  shared Makefile + Containerfile, and prints next steps. The served model is a
#  ONE-TIME input (a project serves exactly one model); version bumps (llama.cpp /
#  ROCm / Fedora) are managed by the submodule via `make sync-versions`. See the
#  README section "Using this repo as a submodule".
# ============================================================================

init: ## Bootstrap a NEW project from this shared submodule (one-time). Usage: make -f shared/Makefile init MODEL=<hf-repo:quant> [NAME=..] [ALIAS=..] [HOME_DIR=..] [DOC_URL=..] [FORCE=1]
	@set -eu; \
	SH="$(SHARED)"; \
	TPL="$$SH/templates"; \
	MODEL="$(MODEL)"; NAME="$(NAME)"; ALIAS="$(ALIAS)"; HOME_DIR="$(HOME_DIR)"; DOC_URL="$(DOC_URL)"; FORCE="$(FORCE)"; \
	if [ -z "$$MODEL" ]; then echo "ERROR: MODEL required, e.g. make -f shared/Makefile init MODEL=unsloth/Your-Model-GGUF:Q4_K_XL" >&2; exit 2; fi; \
	if [ ! -f "$$SH/TAGS" ]; then echo "ERROR: $$SH/TAGS not found — check out the shared submodule first: git submodule update --init" >&2; exit 1; fi; \
	if [ ! -d "$$TPL" ]; then echo "ERROR: $$TPL not found — is this the llamacpp-shared submodule?" >&2; exit 1; fi; \
	tagvar() { awk -F= -v k="$$1" '$$1==k{print $$2; exit}' "$$SH/TAGS" 2>/dev/null; }; \
	LLAMA_TAG="$$(tagvar LLAMA_TAG)"; \
	ROCM_VERSION="$$(tagvar ROCM_VERSION)"; \
	FEDORA_VERSION="$$(tagvar FEDORA_VERSION)"; \
	for v in LLAMA_TAG ROCM_VERSION FEDORA_VERSION; do \
	  if [ -z "$${!v}" ]; then echo "ERROR: $$v missing from $$SH/TAGS" >&2; exit 1; fi; \
	done; \
	repo="$${MODEL%%:*}"; \
	repo="$${repo##*/}"; \
	base="$${repo%-GGUF}"; \
	base="$${base%-gguf}"; \
	NAME="$$(printf '%s' "$${NAME:-$$base}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$$//')"; \
	if [ -z "$$NAME" ]; then echo "ERROR: could not derive a container name from MODEL=$$MODEL (pass NAME=)" >&2; exit 1; fi; \
	ALIAS="$${ALIAS:-$$NAME}"; \
	IMAGE_NAME="localhost/$$NAME"; \
	IMAGE_TAG="$${LLAMA_TAG}-rocm-$${ROCM_VERSION}"; \
	TAGGED_IMAGE="$$IMAGE_NAME:$$IMAGE_TAG"; \
	REPO_PATH="$$(pwd)"; \
	HOME_DIR="$${HOME_DIR:-$${HOME:-}}"; \
	if [ -z "$$HOME_DIR" ]; then echo "ERROR: HOME not set; pass HOME_DIR=/home/<you>" >&2; exit 1; fi; \
	DOC_URL="$${DOC_URL:-https://github.com/nicholasburr/llamacpp-$$NAME}"; \
	echo "==> bootstrapping project in: $$REPO_PATH"; \
	echo "    MODEL   = $$MODEL"; \
	echo "    NAME    = $$NAME"; \
	echo "    ALIAS   = $$ALIAS"; \
	echo "    IMAGE   = $$TAGGED_IMAGE"; \
	echo "    versions from $$SH/TAGS: LLAMA_TAG=$$LLAMA_TAG ROCM_VERSION=$$ROCM_VERSION FEDORA_VERSION=$$FEDORA_VERSION"; \
	existing=""; \
	for f in TAGS compose.yaml README.md "config/containers/systemd/$$NAME/$$NAME.build" "config/containers/systemd/$$NAME/$$NAME.container" Makefile Containerfile; do \
	  if [ -e "$$f" ] || [ -L "$$f" ]; then existing="$$existing $$f"; fi; \
	done; \
	if [ -n "$$existing" ] && [ -z "$$FORCE" ]; then \
	  echo "ERROR: these files already exist:$$existing" >&2; \
	  echo "       re-run with FORCE=1 (make init ... FORCE=1) to overwrite." >&2; \
	  exit 1; \
	fi; \
	render() { local tpl="$$1" out="$$2"; mkdir -p "$$(dirname "$$out")"; sed -e "s|@@CONTAINER_NAME@@|$$NAME|g" -e "s|@@MODEL@@|$$MODEL|g" -e "s|@@ALIAS@@|$$ALIAS|g" -e "s|@@IMAGE_NAME@@|$$IMAGE_NAME|g" -e "s|@@IMAGE_TAG@@|$$IMAGE_TAG|g" -e "s|@@LLAMA_TAG@@|$$LLAMA_TAG|g" -e "s|@@ROCM_VERSION@@|$$ROCM_VERSION|g" -e "s|@@FEDORA_VERSION@@|$$FEDORA_VERSION|g" -e "s|@@HOME_DIR@@|$$HOME_DIR|g" -e "s|@@REPO_PATH@@|$$REPO_PATH|g" -e "s|@@DOC_URL@@|$$DOC_URL|g" "$$tpl" > "$$out"; echo "  wrote $$out"; }; \
	rm -f TAGS compose.yaml README.md; \
	rm -f "config/containers/systemd/$$NAME/$$NAME.build" "config/containers/systemd/$$NAME/$$NAME.container"; \
	render "$$TPL/TAGS.tpl" TAGS; \
	render "$$TPL/compose.yaml.tpl" compose.yaml; \
	render "$$TPL/quadlet.build.tpl" "config/containers/systemd/$$NAME/$$NAME.build"; \
	render "$$TPL/quadlet.container.tpl" "config/containers/systemd/$$NAME/$$NAME.container"; \
	render "$$TPL/README.md.tpl" README.md; \
	link() { local src="$$1" dst="$$2"; if [ -L "$$dst" ]; then rm -f "$$dst"; elif [ -e "$$dst" ]; then if [ -n "$$FORCE" ]; then rm -f "$$dst"; else echo "  skip $$dst (exists and is not a symlink)"; return 0; fi; fi; ln -s "$$src" "$$dst"; echo "  linked $$dst -> $$src"; }; \
	link "$$SH/Makefile" Makefile; \
	link "$$SH/Containerfile" Containerfile; \
	printf '.git\nshared\n*.tpl\n*.bak\n*.bak-*\n' > .podmanignore; \
	echo "  wrote .podmanignore"; \
	echo; \
	echo "==> done. Next steps:"; \
	echo "    git add -A && git commit -m 'bootstrap llamacpp-$$NAME'"; \
	echo "    make deploy          # build the image + start the service"; \
	echo "    make status          # check it came up"; \
	echo; \
	echo "To update llama.cpp / ROCm / Fedora later (managed by the submodule):"; \
	echo "    git submodule update --remote shared && make sync-versions && make sync && make build && make deploy"

sync-versions: ## (consumer) Pull LLAMA_TAG/ROCM_VERSION/FEDORA_VERSION from the shared submodule into TAGS.
	@if [ -f "$(SHARED)/TAGS" ]; then \
	  changed=0; \
	  for k in LLAMA_TAG ROCM_VERSION FEDORA_VERSION; do \
	    v=$$(awk -F= -v k="$$k" '$$1==k{print $$2; exit}' "$(SHARED)/TAGS"); \
	    if [ -n "$$v" ]; then \
	      cur=$$(awk -F= -v k="$$k" '$$1==k{print $$2; exit}' TAGS 2>/dev/null); \
	      if [ "$$cur" != "$$v" ]; then sed -i "s|^$$k=.*|$$k=$$v|" TAGS; echo "  $$k: $$cur -> $$v"; changed=1; fi; \
	    fi; \
	  done; \
	  if [ "$$changed" = 1 ]; then echo "TAGS versions updated. next: make sync && make build && make deploy"; else echo "versions already in sync with $(SHARED)/TAGS"; fi; \
	else echo "no $(SHARED)/TAGS — run this in a consumer project with the shared submodule at ./$(SHARED)"; exit 1; fi