# syntax=docker/dockerfile:1.7
# The updater: a shell script with the Docker CLI, Compose, cosign, curl and jq. README.md says what it does.
FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
RUN apk add --no-cache docker-cli docker-cli-compose cosign curl jq
COPY updater.sh /usr/local/bin/updater
ARG VERSION=dev
ENV UPDATER_VERSION=$VERSION
ENTRYPOINT ["/usr/local/bin/updater"]
