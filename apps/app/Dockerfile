FROM nginx:1.17-alpine
WORKDIR /app
COPY --from=0 /app/build/* /usr/share/nginx/html/
RUN mkdir /usr/share/nginx/html/static && \
    mv /usr/share/nginx/html/js /usr/share/nginx/html/css /usr/share/nginx/html/static
EXPOSE  80
