#!/bin/bash

docker-compose \
  -f docker-compose.build.yml \
  run builder \
    yarn \
    && yarn clean \
    && yarn build api \
    && yarn build app
