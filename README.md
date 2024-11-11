# MySQL for Akash

A production-ready MySQL solution optimized for Akash Network deployments, supporting both standalone and high-availability cluster modes.

> Note: The `archive` directory contains unused code reserved for future use.

## Features

- Optimized for Akash deployments
- Automatic master/slave failover in cluster mode
- Dynamic configuration optimization
- Resource-aware scaling
- Prometheus metrics export
- Zero-config standalone mode
- Automatic backup management
- SSL/TLS support

## Deployment Modes

### Standalone Mode

Perfect for single-node deployments where high availability isn't required:

```sdl
services:
  mysql:
    image: ghcr.io/lumeweb/akash-mysql:latest
    env:
      - MYSQL_ROOT_PASSWORD=mypassword
    expose:
      - port: 3306
        as: 3306
        to:
          - global: true
```

### Cluster Mode

For high-availability deployments with automatic failover:

```sdl
services:
  etcd:
    image: bitnami/etcd:latest
    env:
      - ALLOW_NONE_AUTHENTICATION=yes
    expose:
      - port: 2379
        to:
          - service: mysql

  mysql-master:
    image: ghcr.io/lumeweb/akash-mysql:latest
    env:
      - CLUSTER_MODE=true
      - ETCD_HOST=etcd
      - ETCD_PORT=2379
      - MYSQL_ROOT_PASSWORD=mypassword
    expose:
      - port: 3306
        as: 3306
        to:
          - global: true

  mysql-slave:
    image: ghcr.io/lumeweb/akash-mysql:latest
    count: 2
    env:
      - CLUSTER_MODE=true
      - ETCD_HOST=etcd
      - ETCD_PORT=2379
      - MYSQL_ROOT_PASSWORD=mypassword
    expose:
      - port: 3306
        to:
          - global: true
```

## Environment Variables

### Required
- `MYSQL_ROOT_PASSWORD`: Root password for MySQL

### Optional
- `CLUSTER_MODE`: Enable cluster mode (default: false)
- `PORT`: MySQL port (default: 3306)
- `ETCD_HOST`: etcd host (required for cluster mode)
- `ETCD_PORT`: etcd port (required for cluster mode)
- `ETCD_USERNAME`: etcd authentication username
- `ETCD_PASSWORD`: etcd authentication password
- `METRICS_PORT`: Prometheus metrics port (default: 8080)
- `METRICS_USERNAME`: Metrics authentication username
- `METRICS_PASSWORD`: Metrics authentication password
- `MYSQL_REPL_USER`: Replication user (default: repl)
- `MYSQL_REPL_PASSWORD`: Replication password
- `BACKUP_ENABLED`: Enable automated backups (default: false)
- `BACKUP_SCHEDULE`: Backup schedule in cron format
- `SSL_ENABLED`: Enable SSL/TLS (default: false)

## etcd Protocol Schema

The cluster uses etcd for coordination with the following key structure:

## etcd Schema

The cluster uses etcd for coordination with the following structure:

### Base Paths
```
/mysql/                              # Base path for all MySQL cluster data
    /nodes/                          # Node status and metadata
    /topology/                       # Cluster topology information
```

### Node Status
```
/mysql/nodes/<node_id>              # Node status and metadata
{
    "status": "online|failed|initializing",
    "role": "master|slave",
    "host": "hostname",
    "port": "port",
    "last_seen": "timestamp",
    "gtid_position": "current_gtid"
}
```

### Topology Management
```
/mysql/topology/
    /master                          # Current master reference
        -> "<node_id>"              # Points to current master node
    /slaves/                         # Slave topology tracking
        /<node_id>                  # Each slave's replication status
            -> {
                "master_node_id": "<master_node_id>",
                "replication_lag": "seconds"
            }
```

### Lease Management
- Each node maintains a 10-second TTL lease
- Health updates occur every 5 seconds
- Node status is automatically marked offline when lease expires

## Monitoring

### Prometheus Metrics
Available on port 8080 with basic auth:

```bash
curl -u $METRICS_USERNAME:$METRICS_PASSWORD http://host:8080/metrics
```

Metrics include:
- MySQL server status
- Replication lag
- Connection pool stats
- Query performance
- Resource usage
- Backup status

### Health Monitoring
- Continuous health checks
- Automatic failover on master failure
- Resource utilization tracking
- Error condition monitoring

## Configuration

The system automatically optimizes for:
- Available memory
- CPU cores
- Container limits
- Network conditions
- Workload patterns

## Support

- Issues: [GitHub Issues](https://github.com/lumeweb/akash-mysql/issues)

## License

MIT License - see LICENSE file for details

## Authors

Hammer Technologies LLC
