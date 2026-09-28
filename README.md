# EngramHalo on 128 GiB AMD Strix Halo

Headless Docker Compose deployment of Qwen3.8-Flash-Next with the Q8_0 MTP sidecar, served through llama.cpp's OpenAI-compatible API. `UD-IQ4_XS` is the default; the larger `UD-Q4_K_XL` target can be selected in `.env` without rebuilding the image.

## Why this stack

- **Backend:** ROCm/HIP targeting `gfx1151`. EngramHalo's published Strix Halo measurements and MTP path are validated on ROCm 7.14; the fork explicitly says its Vulkan path is untested and can regress.
- **Memory profile:** SSD-backed mmap keeps the model's 26.8 GiB engram table near 1-1.5 GiB resident instead of pinning it in RAM. Q8_0 KV uses half the memory of BF16 for this model.
- **Conservative default:** one slot, a 65,536-token context, and `UD-IQ4_XS` leave useful unified-memory headroom for separate Whisper, Kokoro, and ACE-Step services. The default target GGUF and sidecar occupy about 91.1 GiB on disk, but the SSD-backed engram table is not fully resident.
- **Reproducibility:** EngramHalo source, target GGUF, MTP GGUF, byte sizes, and SHA-256 hashes are pinned.

Keep the project on fast NVMe storage. Models are stored in the ordinary `./models` host directory and the engram table is read lazily from there during inference. Change `MODEL_DIR` to an absolute NVMe path if preferred.

## Host prerequisites

Use a current Ubuntu Server kernel/firmware that exposes both `/dev/kfd` and `/dev/dri` for the Radeon 8060S. Docker Engine with the Compose v2 plugin is required. No host GUI or host ROCm user-space installation is needed; the image contains the pinned ROCm runtime.

Check the devices:

```bash
ls -l /dev/kfd /dev/dri/renderD*
```

Confirm the host group IDs and copy them into `.env` if they differ from the Ubuntu defaults in `.env.example`:

```bash
getent group video
getent group render
```

For a 128 GiB machine, a practical upper bound is a 96 GiB GTT or 124 GiB GTT aperture while the default `balanced` profile is intended to coexist with other models. This is an addressable ceiling, not a physical reservation or a guarantee that 32 GiB or 4 GiB remains free. Add these kernel parameters to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then update GRUB and reboot:

```text
- 96 GiB
amdgpu.gttsize=98304 ttm.pages_limit=25165824

- 124 GiB
amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

Do not apply the 124 GiB GTT profile described below if you intend to co-host other models. GTT is a maximum aperture, not a guaranteed reservation, but system-wide unified-memory pressure still matters. Confirm the active values after reboot:

```bash
cat /proc/cmdline
sudo dmesg | grep -Ei 'GTT size|TTM size|GTT memory ready|gttsize|pages_limit' | tail -n 30
```

The capacity settings do not require disabling IOMMU. `amd_iommu=off` is an
optional performance choice for a dedicated appliance, but it disables NPU use
and DMA isolation. Leave IOMMU enabled unless that trade-off is intentional.

## Start

Create the local configuration, then review `.env`, especially the bind address
and explicit download approval:

```bash
./scripts/init-env.sh
docker compose up -d
docker compose logs -f model-setup
```

`init-env.sh` copies the public template, generates a random 256-bit API key,
detects the current host UID/GID and the `video`/`render` group IDs, and writes
`.env` with mode `0600`. It never overwrites an existing `.env`. The server
refuses to start with a missing key or the public placeholder from
`.env.example`. Docker Compose loads `.env` for interpolation; the optional
Hugging Face token is passed only to the downloader and not to the API service.

The first start builds the pinned ROCm image, creates `./models` and `./cache/huggingface`, downloads the selected target (91.1 GiB for the default), verifies SHA-256 hashes, and starts the API. Downloads resume after interruption. Subsequent starts reuse those host directories, including after image rebuilds or container deletion.

If your Ubuntu account does not use UID/GID `1000:1000`, put the output of these commands in `MODEL_OWNER_UID` and `MODEL_OWNER_GID` in `.env`:

```bash
id -u
id -g
```

To store models elsewhere, use an absolute path in `.env`, for example:

```env
MODEL_DIR=/mnt/nvme/ai-models/engramhalo
HF_CACHE_DIR=/mnt/nvme/ai-cache/huggingface
```

The image intentionally builds the complete configured CMake target set before running `cmake --install`. A target-only `llama-server` build is insufficient because EngramHalo's install manifest also installs generated test and utility targets.

`DOWNLOAD_MODEL=true` in `.env.example` is the approval that makes the requested two-command startup non-interactive. To require a prompt instead, set `DOWNLOAD_MODEL=ask` and run setup interactively before starting:

```bash
docker compose run --rm -it -e DOWNLOAD_MODEL=ask model-setup
docker compose up -d
```

If downloads are disabled while files are absent, setup exits with a clear instruction and the API does not start.

### Optional `UD-Q4_K_XL` target

The default remains unchanged:

```env
MODEL_QUANT=UD-IQ4_XS
```

To select the larger quantization later, change only this line in `.env`:

```env
MODEL_QUANT=UD-Q4_K_XL
```

When updating an existing deployment from an older package, also set the new image tag so Docker builds the scripts that understand this option:

```env
IMAGE_TAG=2026-09-16-quant-select
```

Then recreate the services:

```bash
docker compose up -d --build --force-recreate
docker compose logs -f model-setup
```

No image rebuild or other server flag is required. Setup downloads and verifies four `UD-Q4_K_XL` shards from the same pinned Unsloth repository, then reuses the existing Q8_0 MTP sidecar. Both targets remain in `MODEL_DIR`, so switching back requires no download:

```env
MODEL_QUANT=UD-IQ4_XS
```

Run `docker compose up -d --force-recreate` again after switching. Disk requirements are:

| Selected target | Target GGUF | Target + shared MTP |
|---|---:|---:|
| `UD-IQ4_XS` (default) | 87.24 GiB | 91.1 GiB |
| `UD-Q4_K_XL` | 103.69 GiB | 107.5 GiB |

Keeping both targets uses about 194.8 GiB because the 3.85 GiB MTP file is shared. If vision is enabled for both variants, each target directory currently retains its own 862.1 MiB projector copy.

The pinned EngramHalo benchmark does not contain a same-hardware `UD-Q4_K_XL` result; it measures `UD-IQ4_XS` and `UD-IQ3_XXS`. Therefore similar generic llama.cpp results should not be treated as a guaranteed tokens-per-second match for this ROCm+MTP path. Both targets have the same 6B active-parameter architecture and the same byte-identical 26.82 GiB engram table, so performance should be in the same broad range. However, `UD-Q4_K_XL` has about 16.4 GiB more dense target weights and can be somewhat slower when decode becomes memory-bandwidth-bound. Measure it with identical fresh prompts after one warm-up request.

In the default balanced profile, expect the larger target to reduce the previously estimated 35-40 GiB of spare unified memory by roughly 16 GiB, leaving approximately 19-24 GiB under comparable workload conditions. That is still useful for Whisper and Kokoro, but it is materially tighter for ACE-Step or several simultaneous services. Actual free memory depends on context depth, page cache, vision use, and ROCm allocations.


## Monitor startup and health:

```bash
docker compose logs -f api
docker compose ps
curl --fail http://127.0.0.1:8080/health
```

## Test the OpenAI-compatible API

Load the generated key from `.env` into a temporary shell variable and test the
API without writing the credential into the command or README:

```bash
API_KEY_VALUE=$(awk -F= '$1 == "API_KEY" { sub(/^[^=]*=/, ""); print; exit }' .env)
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY_VALUE" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.8-flash-next",
    "messages": [
      {"role": "system", "content": "You are a concise technical assistant."},
      {"role": "user", "content": "Write a Python function that returns Fibonacci numbers."}
    ],
    "temperature": 0,
    "max_tokens": 256
  }'
unset API_KEY_VALUE
```

The API binds to loopback by default. Put a TLS/authenticating reverse proxy in front of it before changing `BIND_ADDRESS` to `0.0.0.0` on an untrusted network.

## Optional image understanding (mmproj)

Vision is disabled by default to preserve memory. To enable it, change this in `.env`:

```env
ENABLE_VISION=true
```

Then apply the profile:

```bash
docker compose up -d
docker compose logs -f model-setup
```

Setup downloads only the pinned `mmproj-F16.gguf` if the selected main model is already present; it does not download that target again. The projector is 904,004,000 bytes (862.1 MiB) on disk and is checksum-verified. Disabling vision later leaves the file in `MODEL_DIR` for reuse but does not load it.

Budget approximately **1-2 GiB of additional unified memory** while processing one typical image: about 0.84 GiB for projector weights plus image-encoding and runtime buffers. Large, high-resolution, or multiple images can temporarily use more. If the text-only configuration leaves roughly 35-40 GiB available on your host, a practical vision estimate is roughly 33-39 GiB available; measure the actual workload because Linux page cache and image dimensions vary.

Test the OpenAI-compatible vision request after enabling it:

```bash
API_KEY_VALUE=$(awk -F= '$1 == "API_KEY" { sub(/^[^=]*=/, ""); print; exit }' .env)
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY_VALUE" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.8-flash-next",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "Describe this image in one sentence."},
        {"type": "image_url", "image_url": {"url": "https://cdn.britannica.com/61/93061-050-99147DCE/Statue-of-Liberty-Island-New-York-Bay.jpg"}}
      ]
    }],
    "max_tokens": 128
  }'
unset API_KEY_VALUE
```

This enables image understanding in Qwen; it is not an image generator and does not replace Qwen-Image or Z-Image.

## Memory and operational tuning

### Balanced and dedicated performance profiles

The default profile keeps the 26.8 GiB engram table SSD-backed so other services retain useful memory. These defaults also apply to `UD-Q4_K_XL`, although its larger dense weights leave about 16 GiB less headroom:

```env
PERFORMANCE_PROFILE=balanced
CONTEXT_SIZE=65536
```

To dedicate the machine to Qwen and favor the fastest interactive path, use:

```env
PERFORMANCE_PROFILE=dedicated
DEDICATED_CONTEXT_SIZE=32768
```

Apply the change without downloading the model again:

```bash
docker compose up -d --force-recreate api
docker compose logs -f api
```

The `dedicated` profile selects `--load-mode none --lazy-mode off`, keeping the complete 26.8 GiB engram table resident rather than reading selected rows from NVMe. EngramHalo measured its IQ3 code workload at 39.3 t/s in RAM mode versus 35.3 t/s with the SSD-backed profile, approximately 11% faster. **There is no published IQ4_XS RAM-mode result**, so treat that percentage as an indication rather than a promise. Warm-cache workloads may improve less, while cold or random engram access can improve more.

RAM mode makes the selected target-plus-MTP model resident—approximately 91.1 GiB for `UD-IQ4_XS` or 107.5 GiB for `UD-Q4_K_XL`—and also needs context, compute, ROCm, and operating-system memory. On a 128 GiB system, expect little capacity for Whisper, Kokoro, ACE-Step, or other large processes. `UD-Q4_K_XL` dedicated mode is especially tight. Keep the dedicated context at 32K initially; increasing it can cause allocation failure or system-wide memory pressure. Vision adds roughly another 1-2 GiB when enabled.

For this single-model configuration, the current Strix Halo host guide uses a roughly 124 GiB GPU-addressable ceiling. On Ubuntu, replace the earlier 96 GiB values in `/etc/default/grub` with the following, preserve all unrelated kernel arguments, run `sudo update-grub`, and reboot:

```text
amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

This does not reserve 124 GiB at boot; it raises the maximum GTT and pinned-page
limits. On newer kernels, `amdgpu.gttsize` may be reported as deprecated while
`ttm.pages_limit` remains the effective limit; keeping both preserves
compatibility across supported host kernels. The container cannot safely apply
bootloader changes automatically. If maximum benchmark performance matters more
than NPU support and DMA isolation, `amd_iommu=off` may be added separately
after evaluating that security and functionality trade-off.

For maximum sustained performance, install TuneD on the Ubuntu host and select the accelerator profile:

```bash
sudo apt update
sudo apt install -y tuned
sudo systemctl enable --now tuned
sudo tuned-adm profile accelerator-performance
tuned-adm active
```

Confirm the selected server profile in the log:

```bash
docker compose logs api 2>&1 | grep 'Starting PERFORMANCE_PROFILE'
```

- Keep `PARALLEL_SLOTS=1` with MTP. The server script rejects other values because this EngramHalo MTP configuration is not validated for multi-slot serving.
- `CONTEXT_SIZE=65536` is a deliberate co-hosting default. EngramHalo validates MTP up to 163,840 tokens, but larger caches reduce headroom for audio models.
- Keep `KV_CACHE_TYPE=q8_0`, `--load-mode mmap`, and lazy tensor reads. Do not use `--no-mmap` for this profile.
- If lazy loading hangs with a host setup that enables XNACK, change `--lazy-mode on` to `--lazy-mode off` in `scripts/start-server.sh`; keep mmap enabled. The upstream fork documents this as a host-specific fallback.
- Avoid Docker `mem_limit` for this container. ROCm allocations share physical memory with the CPU and a cgroup cap can cause misleading GPU allocation failures.
- Stop this service before launching a combination of additional models that would push total resident memory near 128 GiB.

## Verified upstream references

- EngramHalo source and Strix Halo guide: <https://github.com/Aristo94/EngramHalo.cpp/tree/strix-halo-qwen4exp>
- Strix Halo 128 GiB host configuration: <https://strix-halo-toolboxes.com/#host-config>
- Target quant: <https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/tree/38bb39ee97821de2c9009abb7e93950eec396e66/UD-IQ4_XS>
- Optional larger target quant: <https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/tree/38bb39ee97821de2c9009abb7e93950eec396e66/UD-Q4_K_XL>
- Optional F16 multimodal projector: <https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/blob/38bb39ee97821de2c9009abb7e93950eec396e66/mmproj-F16.gguf>
- MTP sidecar: <https://huggingface.co/EasiiX/Qwen3.8-Flash-Next-MTP-Strix-Halo-GGUF/tree/6f7900648b1c6b14f067a182c640e47971e9ab35>
- llama.cpp OpenAI-compatible server: <https://github.com/ggml-org/llama.cpp/tree/master/tools/server>

Review the Qwen Community License 1.0 before commercial serving, especially its Model-as-a-Service terms.
