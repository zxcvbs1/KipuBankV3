#!/usr/bin/env bash
# Minimal script to load variables from .env

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
  echo "Variables loaded from .env"
else
  echo "Error: .env file not found"
fi