ARG MYSQL_VERSION=8
ARG METRICS_EXPORTER_VERSION=develop
ARG METRICS_REGISTRAR_VERSION=develop
ARG ETCD_VERSION=3.5
ARG GO_VERSION=1.23

# Disable Percona Telemetry
ARG PERCONA_TELEMETRY_DISABLE=1

# Use metrics exporter and registrar as builder stages
FROM ghcr.io/lumeweb/akash-metrics-exporter:${METRICS_EXPORTER_VERSION} AS metrics-exporter
FROM ghcr.io/lumeweb/akash-metrics-registrar:${METRICS_REGISTRAR_VERSION} AS metrics-registrar

# Build mysqld_exporter
FROM golang:${GO_VERSION} AS mysqld-builder
RUN CGO_ENABLED=0 go install github.com/prometheus/mysqld_exporter@latest

FROM docker.io/bitnami/etcd:${ETCD_VERSION} as etcd

FROM percona:${MYSQL_VERSION}

# Latest releases available at https://github.com/aptible/supercronic/releases
ENV SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64 \
    SUPERCRONIC_SHA1SUM=71b0d58cc53f6bd72cf2f293e09e294b79c666d8 \
    SUPERCRONIC=supercronic-linux-amd64

# Switch to root for setup
USER root

# Install dependencies and set up directories in a single layer
RUN percona-release enable pxb-80 && \
    yum install -y --setopt=tsflags=nodocs \
    percona-xtrabackup-80 lz4 zstd jq nc gettext openssl openssl-perl && \
    curl -fsSLO "$SUPERCRONIC_URL" \
    && echo "${SUPERCRONIC_SHA1SUM}  ${SUPERCRONIC}" | sha1sum -c - \
    && chmod +x "$SUPERCRONIC" \
    && mv "$SUPERCRONIC" "/usr/local/bin/${SUPERCRONIC}" \
    && ln -s "/usr/local/bin/${SUPERCRONIC}" /usr/local/bin/supercronic && \
    yum clean all && \
    rm -rf /var/cache/yum && \
    mkdir -p /var/log/{mysql,mysql-manager} /etc/mysql /var/run/mysqld /etc/mysql/conf.d && \
    mkdir -p /etc/cron.d && \
    rm -f /docker-entrypoint.sh

# Copy files
COPY --chown=mysql:mysql entrypoint.sh /entrypoint.sh
COPY --chown=mysql:mysql paths.sh /paths.sh
COPY --chown=mysql:mysql lib/ /usr/local/lib/
COPY --chown=mysql:mysql bin/mysql-backup-* /usr/local/bin/
RUN chmod 755 /usr/local/bin/mysql-backup-*

# Copy binaries from builder stages
COPY --from=metrics-exporter /usr/bin/metrics-exporter /usr/bin/akash-metrics-exporter
COPY --from=metrics-registrar /usr/bin/metrics-registrar /usr/bin/akash-metrics-registrar
COPY --from=mysqld-builder /go/bin/mysqld_exporter /usr/bin/mysqld_exporter
COPY --from=etcd /opt/bitnami/etcd/bin/etcdctl /usr/bin/etcdctl
COPY ./docker-entrypoint-initdb.d /docker-entrypoint-initdb.d

# Make entrypoint executable
RUN chmod +x /entrypoint.sh

# Expose ports
EXPOSE 8080 3306 33060

# Keep root as the default user since entrypoint needs to handle permissions
USER root

VOLUME ["/var/lib/data"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["mysqld"]