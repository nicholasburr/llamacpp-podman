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
Type=simple
RemainAfterExit=yes

[Install]
WantedBy=default.target
