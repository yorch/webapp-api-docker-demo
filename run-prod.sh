#!/bin/bash

# -d argument is to run it in the background as detached, so you can close the SSH session and the Docker stack will keep running

docker-compose \
  -f docker-compose.prod.yml \
  up \
  -d \
  --build
