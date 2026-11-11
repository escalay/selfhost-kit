# syntax=docker/dockerfile:1.7
# The updater: a shell script with the Docker CLI, Compose, cosign, curl and jq. README.md says what it does.
# cosign comes from its own release, not from Alpine: it has to read the signatures today's release workflows make
# (test/signatures.sh holds it to that).
FROM ghcr.io/sigstore/cosign/cosign:v3.1.4@sha256:0f06154836d2de34f887a5c273506d52ca43edaa1d9e53e6510fa78a48f69c2d AS cosign
FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
RUN apk add --no-cache docker-cli docker-cli-compose curl jq
COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign
COPY updater.sh /usr/local/bin/updater
ARG VERSION=dev
ENV UPDATER_VERSION=$VERSION
ENTRYPOINT ["/usr/local/bin/updater"]
