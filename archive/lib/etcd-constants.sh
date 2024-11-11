#!/bin/bash

# Base paths
: "${ETCD_BASE:=/mysql}"
: "${ETCD_NODES:=$ETCD_BASE/nodes}"
: "${ETCD_TOPOLOGY:=$ETCD_BASE/topology}"
: "${ETCD_LOCKS:=$ETCD_BASE/locks}"

# Topology paths
: "${ETCD_TOPOLOGY_MASTER:=$ETCD_TOPOLOGY/master}"

# Lock paths
: "${ETCD_LOCK_STARTUP:=$ETCD_LOCKS/startup}"
: "${ETCD_LOCK_MASTER:=$ETCD_LOCKS/master}"
