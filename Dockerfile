ARG MYSQL_VERSION=8
ARG METRICS_EXPORTER_VERSION=develop
ARG MYSQL_MANAGER_VERSION=develop
ARG ETCD_VERSION=3.5

# Disable Percona Telemetry
ARG PERCONA_TELEMETRY_DISABLE=1

# Use metrics exporter as builder stage
FROM ghcr.io/lumeweb/akash-metrics-exporter:${METRICS_EXPORTER_VERSION} AS metrics-exporter
FROM docker.io/bitnami/etcd:${ETCD_VERSION} as etcd

FROM percona:${MYSQL_VERSION}

# Switch to root for setup
USER root

# Install dependencies and set up directories in a single layer
RUN percona-release enable pxb-80 && \
    yum install -y --setopt=tsflags=nodocs \
    percona-xtrabackup-80 lz4 zstd jq nc gettext openssl cronie && \
    mkdir -p /var/lib/mysql-backup && \
    chown mysql:mysql /var/lib/mysql-backup && \
    chmod 750 /var/lib/mysql-backup && \
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
COPY --from=metrics-exporter /usr/bin/metrics-exporter /usr/bin/akash-metrics-exporter
COPY --from=etcd /opt/bitnami/etcd/bin/etcdctl /usr/bin/etcdctl
COPY ./docker-entrypoint-initdb.d /docker-entrypoint-initdb.d

# Make entrypoint executable
RUN chmod +x /entrypoint.sh

# Configure environment
ENV METRICS_PORT=9104 \
    METRICS_USERNAME=admin \
    METRICS_PASSWORD=

# Expose ports
EXPOSE 8080 3306 33060

# Keep root as the default user since entrypoint needs to handle permissions
USER root

ENTRYPOINT ["/entrypoint.sh"]
CMD ["mysqld"]
