FROM ubuntu:24.04

# Switch to https mirrors before update - Docker Desktop on Windows silently
# drops TCP connections on port 80, which causes apt-get update to time out.
RUN find /etc/apt -name '*.list' -exec sed -i 's|http://|https://|g' {} + 2>/dev/null; true

RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server sudo curl && \
    rm -rf /var/lib/apt/lists/*

# Generate host keys once so sshd can start without needing ssh-keygen at
# runtime. The /run/sshd directory is required by the sshd daemon.
RUN ssh-keygen -A && mkdir -p /run/sshd
