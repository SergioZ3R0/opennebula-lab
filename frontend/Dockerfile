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
        openssh-client \
        openssh-server \
        rsync \
        tini \
        iproute2 \
        iputils-ping \
        iputils-tracepath \
        net-tools \
        netcat-openbsd \
        dnsutils \
        traceroute \
        mtr-tiny \
        tcpdump \
        lsof \
        psmisc \
        jq \
        less \
        nano \
        tree \
        htop \
        file \
        unzip \
        zip \
        git \
        sudo \
        gawk \
        bc \
        bash-completion \
    && mkdir -p /etc/apt/keyrings \
    && wget -q -O- https://downloads.opennebula.io/repo/repo2.key \
        | gpg --dearmor --yes --output /etc/apt/keyrings/opennebula.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/opennebula.gpg] https://downloads.opennebula.io/repo/${OPENNEBULA_VERSION}/Debian/${DEBIAN_RELEASE} stable opennebula" \
        > /etc/apt/sources.list.d/opennebula.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        opennebula \
        opennebula-fireedge \
        opennebula-gate \
        opennebula-guacd \
    && (apt-get install -y --no-install-recommends opennebula-flow \
        || apt-get install -y --no-install-recommends opennebula-oneflow \
        || true) \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
        /usr/share/doc/* /usr/share/man/* /usr/share/locale/*

COPY entrypoint.sh /entrypoint.sh
COPY seed.sh /seed.sh
COPY motd /etc/motd
RUN chmod +x /entrypoint.sh /seed.sh \
    && mkdir -p /run/sshd \
    && rm -f /etc/ssh/ssh_host_* \
    && echo '[ -r /etc/bash_completion ] && . /etc/bash_completion' >> /etc/bash.bashrc \
    && echo 'alias ll="ls -alF"' >> /root/.bashrc \
    && echo 'alias ll="ls -alF"' >> /home/oneadmin/.bashrc 2>/dev/null || true \
    && chown oneadmin:oneadmin /home/oneadmin/.bashrc 2>/dev/null || true

# sshd is required: qcow2 TM clone runs ON THE NODE and pulls disks from the
# front-end via ssh (local datastore is not shared).
EXPOSE 2633 2616 22

# oned must be running and answering XML-RPC. Process+port is password-agnostic;
# make smoke/doctor do a real one.system.version call with credentials.
# /dev/tcp is bash-only; HEALTHCHECK runs under /bin/sh, so use ss + pgrep.
HEALTHCHECK --interval=15s --timeout=5s --start-period=120s --retries=10 \
    CMD pgrep -x oned >/dev/null && ss -tln | grep -q ':2633' && exit 0 || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
