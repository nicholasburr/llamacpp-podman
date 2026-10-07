[Unit]
Description=Build @@CONTAINER_NAME@@ image for ROCm Strix Halo
Documentation=@@DOC_URL@@
After=network-online.target
Wants=network-online.target

[Build]
ImageTag=localhost/@@CONTAINER_NAME@@:@@IMAGE_TAG@@
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
