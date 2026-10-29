#!/bin/bash
set -e
# CDI-Spec für den inneren Podman aus den von außen injizierten Treiberdateien erzeugen.
# no-additional-gids-for-device-nodes: hält die Spec bei CDI <= 0.6, die Podman 4.9 noch parsen kann
# (die GID der /dev/dri-Knoten ist im User-Namespace ohnehin nur 65534/nobody).
nvidia-ctk cdi generate --feature-flag=no-additional-gids-for-device-nodes \
    --output=/etc/cdi/nvidia.yaml 2>/tmp/cdi-generate.log \
  || { echo "CDI-Generierung fehlgeschlagen:" >&2; cat /tmp/cdi-generate.log >&2; exit 1; }
exec "$@"
