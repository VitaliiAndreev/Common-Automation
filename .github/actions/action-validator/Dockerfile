# Builds a tiny image that bundles the pinned action-validator binary
# from mpalmer/action-validator's GitHub releases. No official upstream
# Docker image exists, so we package one in-repo to give the helper
# the same docker-only ergonomics actionlint has via rhysd/actionlint.
#
# VERSION is required and pinned by .github/lib/versions.env via the
# get-action-validator-version.sh getter - the helper script passes it
# in as a build arg so a bump there propagates with no edits here.
#
# TARGETARCH is set automatically by BuildKit (the default builder in
# modern Docker). The default keeps a non-BuildKit `docker build` on an
# amd64 host working too. Upstream releases cover linux_{amd64,arm64};
# Windows local devs build via Docker Desktop's Linux engine, which is
# always linux, so amd64/arm64 is the full matrix.
FROM alpine:3.20

ARG VERSION
ARG TARGETARCH=amd64

# curl + ca-certificates are only needed for the download; remove them
# after to keep the final image close to base alpine size. A failed
# download fails the build loudly thanks to `set -e` + `curl -fsSL`.
RUN set -eux && \
    apk add --no-cache curl ca-certificates && \
    curl -fsSL \
        -o /usr/local/bin/action-validator \
        "https://github.com/mpalmer/action-validator/releases/download/v${VERSION}/action-validator_linux_${TARGETARCH}" && \
    chmod +x /usr/local/bin/action-validator && \
    apk del curl

ENTRYPOINT ["/usr/local/bin/action-validator"]
