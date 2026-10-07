[Unit]
Description=@@ALIAS@@ server (ROCm @@ROCM_VERSION@@)
Wants=@@CONTAINER_NAME@@-build.service
After=network-online.target

[Container]
ContainerName=@@CONTAINER_NAME@@
Image=localhost/@@CONTAINER_NAME@@:@@IMAGE_TAG@@
PublishPort=8000:8000
AddDevice=/dev/dri
AddDevice=/dev/kfd
GroupAdd=video
GroupAdd=render
PodmanArgs=--ipc=host
SeccompProfile=unconfined
Secret=huggingface-token,type=env,target=HF_TOKEN
Volume=@@HOME_DIR@@/.cache/huggingface/hub/:/root/.cache/huggingface/hub/:Z
Volume=@@HOME_DIR@@/.config/llama.cpp/:/root/.config/llama.cpp/:Z
# Model
Environment=LLAMA_ARG_HF_REPO=@@MODEL@@
Environment=LLAMA_ARG_ALIAS=@@ALIAS@@
# Server
Environment=LLAMA_ARG_LOG_TIMESTAMPS=on
Environment=LLAMA_ARG_HOST=0.0.0.0
Environment=LLAMA_ARG_PORT=8000
# Runtime
Environment=LLAMA_ARG_THREADS=8
Environment=LLAMA_ARG_LOAD_MODE=auto
Environment=LLAMA_ARG_FIT=off
Environment=LLAMA_ARG_N_GPU_LAYERS=99
Environment=LLAMA_ARG_CTX_SIZE=262144
Environment=LLAMA_ARG_FLASH_ATTN=on
Environment=LLAMA_ARG_N_PARALLEL=1
Environment=LLAMA_ARG_CONT_BATCHING=on
Environment=LLAMA_ARG_SPEC_TYPE=draft-mtp
Environment=LLAMA_ARG_CACHE_TYPE_K=q8_0
Environment=LLAMA_ARG_CACHE_TYPE_V=q8_0
# Features
Environment=LLAMA_ARG_UI=on
Environment=LLAMA_ARG_UI_MCP_PROXY=on
Environment=LLAMA_ARG_AGENT=on
Environment=LLAMA_ARG_TOOLS=all
Environment=LLAMA_ARG_REASONING=on
Environment=LLAMA_ARG_REASONING_EFFORT=medium
Environment=LLAMA_ARG_JINJA=on

[Service]
Restart=always

[Install]
WantedBy=default.target
