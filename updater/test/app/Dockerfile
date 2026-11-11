# A stand-in app that keeps the state contract the updater relies on (README.md): a version file, a copy of the data
# before a newer version first touches it, a staged restore taken at start, and a health answer with its version.
FROM busybox:1.37
COPY app.sh /app.sh
ARG VERSION
ARG BROKEN=
ENV VERSION=$VERSION BROKEN=$BROKEN
ENTRYPOINT ["/bin/sh", "/app.sh"]
