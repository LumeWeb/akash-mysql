#!/bin/bash

# Add STATE_DIR to protected paths
declare -g PROTECTED_PATHS=(
    "backup-keys"
    "mysql-files"
    "state"
)

# Cleanup function to stop all background processes
cleanup() {
  local err=$?

  # Stop cron first to prevent any new backup jobs
  if [ -n "$CROND_PID" ]; then
      log_info "Stopping cron service..."
      stop_cron
  fi

  # Stop log monitoring
  if [ -f "${STATE_DIR}/monitor/error_monitor.pid" ]; then
    kill $(cat "${STATE_DIR}/monitor/error_monitor.pid") 2>/dev/null || true
    rm -f "${STATE_DIR}/monitor/error_monitor.pid"
  fi

  # First stop monitoring processes
  if [ -n "$HEALTH_UPDATE_PID" ]; then
    kill $HEALTH_UPDATE_PID 2>/dev/null || true
    wait $HEALTH_UPDATE_PID 2>/dev/null || true
  fi

  if [ -n "$GTID_MONITOR_PID" ]; then
    kill $GTID_MONITOR_PID 2>/dev/null || true
    wait $GTID_MONITOR_PID 2>/dev/null || true
  fi

  if [ -n "$BACKUP_SCHEDULER_PID" ]; then
    kill $BACKUP_SCHEDULER_PID 2>/dev/null || true
    wait $BACKUP_SCHEDULER_PID 2>/dev/null || true
  fi

  # Then stop backup processes
  if [ -n "$STREAMING_BACKUP_PID" ]; then
    kill $STREAMING_BACKUP_PID 2>/dev/null || true
    wait $STREAMING_BACKUP_PID 2>/dev/null || true
  fi

  # Stop lease keepalive before MySQL shutdown
  if [ -n "$LEASE_KEEPALIVE_PID" ]; then
    stop_lease_keepalive "$LEASE_KEEPALIVE_PID"
    LEASE_KEEPALIVE_PID=""
  fi

  # Check MySQL state before shutdown
  detect_mysql_state
  state_code=$?

  # Only attempt clean shutdown for valid installations
  if [ $state_code -eq 1 ] && [ -f "${RUN_DIR}/mysqld.pid" ]; then
    log_info "Performing clean shutdown of valid MySQL installation"
    mysqladmin shutdown 2>/dev/null || true
    # Wait for MySQL to fully shutdown
    sleep 5
  elif [ -f "${RUN_DIR}/mysqld.pid" ]; then
    log_warn "Forcing shutdown of MySQL in state: $state_code"
    kill $(cat "${RUN_DIR}/mysqld.pid") 2>/dev/null || true
    sleep 5
  fi

  # Stop health updater if running
  if [ -n "$HEALTH_UPDATE_PID" ]; then
    kill $HEALTH_UPDATE_PID 2>/dev/null || true
    wait $HEALTH_UPDATE_PID 2>/dev/null || true
  fi

  # Stop GTID monitor if running
  if ! stop_gtid_monitor; then
    log_error "Failed to stop GTID monitor during cleanup"
  fi

  # Stop backup scheduler if running
  if [ -n "$BACKUP_SCHEDULER_PID" ]; then
    kill $BACKUP_SCHEDULER_PID 2>/dev/null || true
    wait $BACKUP_SCHEDULER_PID 2>/dev/null || true
  fi

  # Stop streaming backup server if running
  if [ -n "$STREAMING_BACKUP_PID" ]; then
    kill $STREAMING_BACKUP_PID 2>/dev/null || true
    wait $STREAMING_BACKUP_PID 2>/dev/null || true
  fi

  # Mark node as offline in etcd before exit
  if [ -n "$NODE_ID" ] && [ -n "$LEASE_ID" ]; then
    status_json=$(jq -n \
      --arg hostname "$HOSTNAME" \
      --arg port "$MYSQL_EXTERNAL_PORT" \
      '{
                status: "offline",
                hostname: $hostname,
                port: $port,
                health: {
                    status: "shutdown"
                }
            }')
    etcdctl put "$(get_node_path $NODE_ID)" "$status_json" --lease=$LEASE_ID >/dev/null || true
  fi

  exit $err
}
