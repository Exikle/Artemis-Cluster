#!/usr/bin/env bash

#Can only be run after toolbox pod is running, which needs the cluster up

alias ceph="kubectl exec -n rook-ceph $(kubectl -n rook-ceph get pod -l "app=rook-ceph-tools" -o jsonpath='{.items[0].metadata.name}') -- ceph"
