# Podman in Podman (rootless) mit NVIDIA CUDA

Verschachtelter rootless-Betrieb mit GPU auf RHEL 8.10:

```
Host (RHEL 8.10, Podman 4.9, rootless)
 └─ äußerer Container: UBI8, rootless Podman 4.9 als Benutzer "podman"
     └─ innerer Container: nvidia/cuda …-ubi8  → CUDA auf der GPU
```

Getestet mit RTX 3090, Treiber 580.196.07, NVIDIA Container Toolkit 1.20.1,
Kernel 4.18.0-553 (cgroups v1). Ergebnis im innersten Container: `nvidia-smi` sowie das
CUDA-Sample `vectoradd` (`Test PASSED`).

## Dateien

| Datei | Zweck |
|---|---|
| `Containerfile` | Äußeres Image: UBI8 + podman, runc, fuse-overlayfs, slirp4netns, nvidia-container-toolkit-base |
| `entrypoint.sh` | Erzeugt beim Start `/etc/cdi/nvidia.yaml` für den inneren Podman |
| `containers.conf` | Konfiguration des inneren Podman (`utsns = "host"`, `runtime = "runc"`, cgroupfs) |
| `storage.conf` | Storage des inneren Podman über fuse-overlayfs |
| `run.sh` | Startet den äußeren Container mit allen nötigen Optionen |

## Schritte

### 1. Voraussetzungen auf dem Host

- NVIDIA-Treiber und `nvidia-container-toolkit` installiert (`nvidia-smi` funktioniert)
- Subscription aktiv (das UBI8-Image installiert podman aus den RHEL-8-Repos)
- Subuid/Subgid für den Benutzer, mind. 65536 IDs (`/etc/subuid`, `/etc/subgid`)

### 2. CDI-Spec für den äußeren Container erzeugen (einmalig als root)

```bash
sudo nvidia-ctk cdi generate \
  --class gpu-nested \
  --disable-hook disable-device-node-modification \
  --output=/etc/cdi/nvidia-nested.yaml
```

Damit gibt es das Gerät `nvidia.com/gpu-nested=all` neben den unveränderten Standard-Specs.

> **Nach jedem Treiber-Update wiederholen.** Diese Datei wird, anders als
> `/var/run/cdi/nvidia.yaml`, nicht automatisch neu erzeugt.

### 3. Image bauen

```bash
podman build -t localhost/pinp-cuda-ubi8 .
```

### 4. Äußeren Container starten

```bash
./run.sh            # interaktive Shell als Benutzer podman
```

`run.sh` entspricht:

```bash
podman run --rm -it \
  --device nvidia.com/gpu-nested=all \
  --device /dev/fuse \
  --device /dev/net/tun \
  --security-opt label=disable \
  --security-opt 'unmask=/proc/*:/sys/firmware:/sys/dev/block' \
  localhost/pinp-cuda-ubi8
```

### 5. Inneren CUDA-Container starten (im äußeren Container)

```bash
podman run --rm --device nvidia.com/gpu=all --security-opt label=disable \
  docker.io/nvidia/cuda:12.9.1-base-ubi8 nvidia-smi

podman run --rm --device nvidia.com/gpu=all --security-opt label=disable \
  nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubi8
```

## Variante mit `--net=host` im inneren Container

Benötigt der innere Container kein eigenes Netzwerk, wird der äußere Container schlanker:

```bash
podman run --rm -it \
  --device nvidia.com/gpu-nested=all \
  --device /dev/fuse \
  --security-opt label=disable \
  --security-opt 'unmask=/proc/*' \
  localhost/pinp-cuda-ubi8

# innen:
podman run --rm --net=host --device nvidia.com/gpu=all --security-opt label=disable \
  nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubi8
```

Ohne eigenes Netzwerk-Namespace darf (und muss) die Runtime `/sys` nicht neu mounten, sondern
bindet das vorhandene ein. Dadurch entfallen:

- `unmask` für `/sys/firmware` und `/sys/dev/block`
- `--device /dev/net/tun` (kein slirp4netns)
- die Notwendigkeit von runc: auch crun 1.14 funktioniert (`--runtime crun`)

**Weiterhin nötig:** `unmask=/proc/*` (ein eigenes PID-Namespace braucht ein frisches procfs)
und `utsns = "host"` (siehe unten, `--net=host` ändert daran nichts).

Getestete Matrix (innen jeweils `--net=host`):

| äußeres `unmask` | Runtime | `--uts` | Ergebnis |
|---|---|---|---|
| `/proc/*:/sys/firmware:/sys/dev/block` | runc / crun | host | ✅ GPU |
| `/proc/*` | runc / crun | host | ✅ GPU |
| beliebig | runc / crun | private | ❌ `sethostname: operation not permitted` |
| keins | runc / crun | beliebig | ❌ `mount proc: operation not permitted` |

## Hintergrund: warum jede Option nötig ist

| Symptom | Ursache | Lösung |
|---|---|---|
| `crun: mount proc to proc: Operation not permitted` | Der Hook `disable-device-node-modification` der Standard-CDI-Spec legt ein tmpfs über `/proc/driver/nvidia/params`. Ein (gesperrter) Overmount auf procfs verbietet dem Kernel, im User-Namespace ein neues procfs zu mounten. | Eigene Spec `gpu-nested` ohne diesen Hook (Schritt 2) |
| dito | Podman maskiert Pfade unter `/proc` mit Overmounts | `unmask=/proc/*` |
| `mount sysfs: operation not permitted` | Dasselbe für sysfs: Masken auf `/sys/firmware` und `/sys/dev/block` sind nicht-leere Verzeichnisse | `unmask=…:/sys/firmware:/sys/dev/block` (entfällt bei `--net=host`) |
| `unresolvable CDI devices nvidia.com/gpu=all` | `nvidia-ctk` schreibt für die `/dev/dri`-Knoten `additionalGids` (CDI 0.7), das Podman 4.9 nicht parsen kann; die ganze Spec wird verworfen | `--feature-flag=no-additional-gids-for-device-nodes` im `entrypoint.sh`. Die GID wäre im User-Namespace ohnehin nur 65534 (nobody) |
| `crun: mount_setattr /sys: Function not implemented` | crun 1.14 mountet sysfs zuerst ohne `MS_RDONLY`. Das gesperrt-ro `/sys` des äußeren Containers lässt das nicht zu, und der Fallback nutzt `mount_setattr()`, das Kernel 4.18 nicht hat | `runtime = "runc"`: runc mountet sysfs direkt read-only (entfällt bei `--net=host`) |
| `sethostname: operation not permitted` | Das Standard-Seccomp-Profil erlaubt `sethostname`/`setdomainname` nur mit `CAP_SYS_ADMIN`; der äußere Container läuft ohne Capabilities | `utsns = "host"`: der innere Container erbt den Hostnamen des äußeren, statt ihn zu setzen (wie im offiziellen `quay.io/podman/stable`) |
| Podman 4.9 im äußeren Container findet keine Spec im Home | Podman 4.9 liest CDI nur aus `/etc/cdi` und `/var/run/cdi` | `/etc/cdi` gehört im Image dem Benutzer `podman` |

### CAP_SYS_ADMIN

`CAP_SYS_ADMIN` wird nicht vergeben, auch nicht mit `--net=host`. Ein eigener UTS-Namespace
mit eigenem Hostnamen im inneren Container bräuchte es aber, und zwar unabhängig vom Netzwerkmodus:
Das Seccomp-Profil des äußeren Containers knüpft `sethostname` an diese Capability. Deshalb steht
`utsns = "host"` in `containers.conf`. Die Alternative wäre ein angepasstes Seccomp-Profil für den
äußeren Container, das `sethostname`/`setdomainname` ohne Capability erlaubt.

## Sicherheitshinweise

- Der äußere Container läuft rootless und ohne Capabilities, aber mit `label=disable`
  (kein SELinux-Labeling) und ohne die Standard-Maskierung der genannten `/proc`/`/sys`-Pfade.
- cgroups v1: Ressourcenlimits für den inneren Container sind nicht verfügbar. Die
  Deprecation-Warnung von Podman wird per `PODMAN_IGNORE_CGROUPSV1_WARNING=1` ausgeblendet.
