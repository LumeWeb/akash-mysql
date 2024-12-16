# MySQL for Akash

A production-ready MySQL solution optimized for Akash Network deployments, supporting both standalone and high-availability cluster modes.

## Features

- Automatic master/slave failover in cluster mode
- Dynamic configuration optimization based on available resources
- Automated encrypted backups to S3
- GTID-based replication
- Comprehensive health monitoring
- Zero-config standalone mode

## Environment Variables

### Required
- `MYSQL_ROOT_PASSWORD`: Root password for MySQL
- `MYSQL_REPL_USERNAME`: Replication user (required for cluster mode)
- `MYSQL_REPL_PASSWORD`: Replication password (required for cluster mode)

### S3 Backup Configuration (Required for backups)
- `S3_ACCESS_KEY`: S3 access key
- `S3_SECRET_KEY`: S3 secret key
- `S3_ENDPOINT`: S3 endpoint URL
- `S3_BUCKET`: S3 bucket name
- `S3_PATH`: Path within bucket for backups
- `S3_SSL`: Enable SSL for S3 (true/false)

### Backup Configuration
- `BACKUP_CONFIG_DIR`: Backup configuration directory (default: /etc/mysql/backup)
- `BACKUP_RETENTION_DAYS`: Number of days to retain backups
- `BACKUP_FULL_INTERVAL`: Interval between full backups in seconds
- `BACKUP_INCR_INTERVAL`: Interval between incremental backups in seconds

### Cluster Configuration
- `CLUSTER_MODE`: Enable cluster mode (default: false)
- `ETCDCTL_ENDPOINTS`: etcd endpoints (required for cluster mode)
- `ETC_USERNAME`: etcd authentication username (optional)
- `ETC_PASSWORD`: etcd authentication password (optional)
- `ETC_PREFIX`: etcd key prefix for all MySQL cluster data (default: /mysql)

## etcd Schema

The cluster uses etcd for coordination with the following structure:

### Base Paths
```
/mysql/                           # Base path for all MySQL cluster data
    /nodes/                       # Node status and metadata
    /topology/                    # Cluster topology information
```

### Node Status
```
/mysql/nodes/<node_id>           # Node status and metadata
{
    "status": "online|offline",
    "role": "master|slave",
    "host": "hostname",
    "port": "port",
    "last_seen": "timestamp",
    "gtid_position": "current_gtid",
    "health": {
        "status": "string",
        "connections": number,
        "uptime": number
    }
}
```

### Topology Management
```
/mysql/topology/master           # Current master reference
```

### Lease Management
- Each node maintains a lease with TTL
- Health updates occur every 5 seconds
- Node status automatically marked offline when lease expires

## Backup System

- Encrypted backups using AES256
- Full and incremental backup support
- Automatic backup verification
- Streaming backup support via port 4444
- S3-compatible storage support

## Health Monitoring

- Continuous health checks including:
  - Process status
  - MySQL connectivity
  - Read/Write capability
  - Replication status
- Automatic failover on master failure
- Error condition monitoring

## Configuration

The system automatically optimizes for:
- Available memory
- CPU cores
- Container limits
- Kubernetes environment detection
- InnoDB settings
- Performance schema (when >8GB RAM available)

## License

MIT License - see LICENSE file for details
