FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C TZ=UTC HOME=/tmp
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential binutils ca-certificates curl file gawk gettext git \
    libncurses-dev libssl-dev python3 rsync unzip wget zstd squashfs-tools genisoimage \
    qemu-system-x86 ovmf util-linux bzip2 xz-utils cpio bc \
    && rm -rf /var/lib/apt/lists/*
COPY scripts /opt/firmware/scripts
COPY packages /opt/firmware/packages
COPY files /opt/firmware/files
WORKDIR /opt/firmware
ENTRYPOINT ["python3", "/opt/firmware/scripts/firmware.py"]
