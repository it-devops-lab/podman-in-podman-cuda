# Äußerer Container: UBI8 mit rootless Podman + NVIDIA Container Toolkit
FROM registry.access.redhat.com/ubi8/ubi:latest

RUN curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
 && dnf -y module enable container-tools:rhel8 \
 && dnf -y install podman crun fuse-overlayfs slirp4netns shadow-utils nvidia-container-toolkit-base \
 && dnf clean all

# Unprivilegierter Benutzer mit Subuid/Subgid-Bereichen innerhalb der 65536 IDs des äußeren User-Namespace
RUN useradd -u 1000 podman \
 && echo -e "podman:1:999\npodman:1001:64535" > /etc/subuid \
 && echo -e "podman:1:999\npodman:1001:64535" > /etc/subgid

# Podman 4.9 liest CDI nur aus /etc/cdi und /var/run/cdi -> /etc/cdi gehört dem Benutzer podman
RUN mkdir -p /etc/cdi && chown podman:podman /etc/cdi

# Rootless-Konfiguration für den inneren Podman
COPY --chown=podman:podman containers.conf storage.conf /home/podman/.config/containers/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

USER podman
WORKDIR /home/podman
ENV PODMAN_IGNORE_CGROUPSV1_WARNING=1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
