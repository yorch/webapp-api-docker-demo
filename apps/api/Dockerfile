FROM node:10-alpine

WORKDIR /app

COPY package.json /app
RUN yarn install
COPY . /app

# set your port
ENV PORT 8080

# expose the port to outside world
EXPOSE  8080

CMD ["node", "main.js"]
