#!/bin/bash
# Äußeren rootless UBI8-Container mit GPU starten. Darin: rootless Podman für den innersten CUDA-Container.
#
# Voraussetzung (einmalig als root, nach Treiber-Updates wiederholen):
#   nvidia-ctk cdi generate --class gpu-nested --disable-hook disable-device-node-modification \
#       --output=/etc/cdi/nvidia-nested.yaml
#
# Die Flags im Einzelnen:
#   nvidia.com/gpu-nested=all  GPU ohne den params-tmpfs-Overmount auf /proc/driver/nvidia
#   /dev/fuse                  fuse-overlayfs für den Storage des inneren Podman
#   /dev/net/tun               slirp4netns-Netzwerk des inneren Podman
#   unmask=...                 Overmounts entfernen, damit innen proc/sysfs frisch gemountet werden dürfen
#   label=disable              SELinux-Labeling des äußeren Containers aus (sonst kein Nesting)
set -euo pipefail
TTY=(); [[ -t 0 ]] && TTY=(-it)
exec podman run --rm "${TTY[@]}" \
    --device nvidia.com/gpu-nested=all \
    --device /dev/fuse \
    --device /dev/net/tun \
    --security-opt label=disable \
    --security-opt 'unmask=/proc/*:/sys/firmware:/sys/dev/block' \
    localhost/pinp-cuda-ubi8 "$@"
