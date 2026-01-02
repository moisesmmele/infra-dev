#!/bin/bash
# CloudBeaver setup

mkdir -p data
# CloudBeaver often runs as a non-root user (id 1000).
# Creating this as the current user (1000) on the host ensures writable access.
