#!/bin/bash

# Cleanup function to stop all background processes
cleanup() {
  local err=$?

  # Stop log monitoring
  if [ -f "/var/run/mysqld/error_monitor.pid" ]; then
    kill $(cat /var/run/mysqld/error_monitor.pid) 2>/dev/null || true
    rm -f /var/run/mysqld/error_monitor.pid
  fi

  # Stop MySQL if running
  if [ -f "/var/run/mysqld/mysqld.pid" ]; then
    mysqladmin shutdown 2>/dev/null || true
  fi

  # Stop lease keepalive if running
  if [ -n "$LEASE_KEEPALIVE_PID" ]; then
    kill $LEASE_KEEPALIVE_PID 2>/dev/null || true
  fi

  # Stop health updater if running
  if [ -n "$HEALTH_UPDATE_PID" ]; then
    kill $HEALTH_UPDATE_PID 2>/dev/null || true
    wait $HEALTH_UPDATE_PID 2>/dev/null || true
  fi

  # Stop GTID monitor if running
  if [ -n "$GTID_MONITOR_PID" ]; then
    kill $GTID_MONITOR_PID 2>/dev/null || true
    wait $GTID_MONITOR_PID 2>/dev/null || true
  fi

  # Ensure final unhealthy status is recorded in etcd
  if [ -n "$NODE_ID" ] && [ -n "$LEASE_ID" ]; then
    status_json=$(jq -n \
      --arg hostname "$HOSTNAME" \
      --arg port "$PORT" \
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
  # Mark node as offline in etcd before exit
  if [ -n "$NODE_ID" ] && [ -n "$LEASE_ID" ]; then
    offline_json=$(jq -n \
      --arg hostname "$HOSTNAME" \
      --arg port "$PORT" \
      '{
                status: "offline",
                hostname: $hostname,
                port: $port
            }')
    etcdctl put "$(get_node_path $NODE_ID)" "$offline_json" --lease=$LEASE_ID >/dev/null || true
  fi

  exit $err
}
