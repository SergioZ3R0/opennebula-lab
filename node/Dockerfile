# syntax=docker/dockerfile:1
FROM debian:13-slim

ARG OPENNEBULA_VERSION=7.4
ARG DEBIAN_RELEASE=13

ENV DEBIAN_FRONTEND=noninteractive \
    ONE_VERSION=${OPENNEBULA_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        gnupg \
        wget \
        apt-transport-https \
        curl \
        procps \
        openssh-server \
        tini \
        iproute2 \
        iptables \
        sudo \
        ruby \
        ruby-webrick \
        bc \
        gawk \
        netbase \
        dbus \
    && mkdir -p /etc/apt/keyrings \
    && wget -q -O- https://downloads.opennebula.io/repo/repo2.key \
        | gpg --dearmor --yes --output /etc/apt/keyrings/opennebula.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/opennebula.gpg] https://downloads.opennebula.io/repo/${OPENNEBULA_VERSION}/Debian/${DEBIAN_RELEASE} stable opennebula" \
        > /etc/apt/sources.list.d/opennebula.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        opennebula-node-kvm \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
        /usr/share/doc/* /usr/share/man/* /usr/share/locale/* \
        /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# libvirt/qemu debug-friendly logging to stdout
ENV LIBVIRT_LOG_FILTERS="1:libvirt 1:qemu" \
    LIBVIRT_LOG_OUTPUTS="1:stderr"

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
