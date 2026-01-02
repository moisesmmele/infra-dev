#!/bin/bash
# Nginx Proxy Manager setup

mkdir -p data
mkdir -p letsencrypt

# Note: NPM often runs as root, so standard permissions are usually fine.
# If user mapping is needed later, add chown here.
