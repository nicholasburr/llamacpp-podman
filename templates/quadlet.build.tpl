[Unit]
Description=Build the shared llama.cpp ROCm image (for @@CONTAINER_NAME@@)
Documentation=@@DOC_URL@@
After=network-online.target
Wants=network-online.target

[Build]
ImageTag=localhost/llamacpp:@@IMAGE_TAG@@
File=Containerfile
SetWorkingDirectory=@@REPO_PATH@@
ForceRM=true
BuildArg=FEDORA_VERSION=@@FEDORA_VERSION@@
BuildArg=ROCM_VERSION=@@ROCM_VERSION@@
BuildArg=TAG=@@LLAMA_TAG@@

[Service]
# Type=oneshot: the unit only reaches "active" AFTER `podman build` FINISHES.
# With Type=simple it would be active as soon as the build starts, and the
# container unit — ordered after this one — would race the build and fail
# with "image not found". RemainAfterExit=yes keeps a success sticky so
# container restarts do not re-trigger a (cached) build; `make deploy`
# re-runs this unit explicitly when the image is missing (e.g. after clean).
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=default.target
