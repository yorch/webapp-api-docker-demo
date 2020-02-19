#!/bin/bash

docker-compose \
  -f docker-compose.build.yml \
  run builder \
    bash -c "yarn && yarn clean && yarn build api --prod && yarn build app --prod"
