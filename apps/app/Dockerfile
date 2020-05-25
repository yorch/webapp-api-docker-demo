# ------------------------------------------------------------------------------------
# App Static Server
# ------------------------------------------------------------------------------------
FROM nginx:1.17-alpine AS app

ENV HTML_PATH=/usr/share/nginx/html

RUN rm -rf ${HTML_PATH}/*

# The name of the image we are copying here from must match the image name we use in the
# corresponding Docker Compose file (ie: docker-compose.prod.yml)
COPY --from=webapp-api-docker-demo-builder /app/dist/apps/app ${HTML_PATH}
