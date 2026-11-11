# The updater as shipped, with cosign replaced: the tests' images are signed by nobody
ARG UPDATER
FROM ${UPDATER}
COPY cosign /usr/local/bin/cosign
RUN chmod +x /usr/local/bin/cosign
