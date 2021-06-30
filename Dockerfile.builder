# ------------------------------------------------------------------------------------
# Builder
# This image is only used to build assets so they can copied to final images
# ------------------------------------------------------------------------------------
FROM node:14

# Set the working directory so subsequent commands will run in this directory automatically
WORKDIR /app

# We copy these two first so in subsequent runs, we can use the cached layer if deps didn't change
COPY package.json yarn.lock /app/
RUN yarn

# We copy the rest of the app and compile the whole project
COPY . /app/
RUN yarn nx run-many --target=build --all --prod --parallel
