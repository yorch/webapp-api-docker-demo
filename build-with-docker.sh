#!/bin/bash

docker-compose \
  -f docker-compose.build.yml \
  run builder \
    bash -c "yarn && yarn clean && yarn build api && yarn build app"
