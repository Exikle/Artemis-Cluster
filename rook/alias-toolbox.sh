#!/usr/bin/env bash
alias ceph="kubectl -n rook-ceph exec -it $(kubectl -n rook-ceph get pod -l 'app=toolbox' -o jsonpath='{.items[0].metadata.name}') ceph"
