# ------------------------------------------------------------------------------------
# API Server
# ------------------------------------------------------------------------------------
FROM node:12-alpine

# The name of the image we are copying here from must match the image name we use in the
# corresponding Docker Compose file (ie: docker-compose.prod.yml)
COPY --from=webapp-api-docker-demo-builder /app/dist/apps/api /app
COPY --from=webapp-api-docker-demo-builder /app/node_modules /app/node_modules
