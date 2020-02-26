# Webapp and API Server with Docker Demo

This is a demo project composed of:

- React Web Application
- NodeJS / Express server for handling API requests from a Postgres database
- Docker orchestration to deploy and run the load balancer, webapp, server and database.

The architecture and tech stack of the deployed application consist of:

- [Traefik](https://traefik.io/): As the reverse proxy and load balancer for the web app and the API server with SSL termination, so all the requests to ports 80 and 443 (SSL / HTTPS) will go to it.
- React and [React Admin](https://marmelab.com/react-admin/) for the Front End.
- NodeJS / [Express.js](https://expressjs.com/) for the API server.
- [TypeORM](https://github.com/typeorm/typeorm) as the [ORM](https://en.wikipedia.org/wiki/Object-relational_mapping) for the API server.
- [PostgreSQL](https://www.postgresql.org/) for the database.
- [Nx](https://nx.dev/), a CLI tool for managing monorepos.
- [Adminer](https://www.adminer.org/) a simple web application to manage databases.

## Requirements

- You will need a server / VPS, ideally that has a public IP address. You can get a \$5/month VPS from providers as:
  - [Digital Ocean](https://m.do.co/c/386aa021b4aa)
  - [Vultr](https://www.vultr.com/?ref=6940743)
- A domain, it could be a `.com`, `.net`, `.info`, `.cc` or any other domain you like.
- Install Docker and [Docker Compose](https://docs.docker.com/compose/) in the server, both Digital Ocean and Vultr have images with Docker pre-installed. You could also use a regular Ubuntu 16.04 or Ubuntu 18.04 image and use a script like [this](https://github.com/yorch/server-simple-setup) to set it up (or do it manually, it's a great way to learn Linux, just check the [source code of the script](https://github.com/yorch/server-simple-setup/blob/master/server-setup.sh), it's pretty straightforward).

## Getting Started

- Once you have your server setup and you are SSH into it, clone this repo (or a fork of this if you created one).
- Create an `.env` file based on `.env.sample` (ie: `cp .env.sample .env`).
- Update the env variables in your new `.env` file, mainly `DOMAIN`.
- Run the build:
  ```sh
  ./build-with-docker.sh
  ```
  This command will install all NodeJS dependencies and run the build using `yarn` inside a Docker container and saving the results in your server, so you don't have to install NodeJS / Yarn on the server, which makes this very portable.
- Once the build is complete, the compiled bundles for the web app and server will live in `dist` directory.
- Next, we need to run Docker Compose to prepare and start all the require containers for the whole stack. We can use:
  ```sh
  ./run-prod.sh
  ```

---

This project was generated using [Nx](https://nx.dev).

<p align="center"><img src="https://raw.githubusercontent.com/nrwl/nx/master/nx-logo.png" width="450"></p>

🔎 **Nx is a set of Extensible Dev Tools for Monorepos.**

## Adding capabilities to your workspace

Nx supports many plugins which add capabilities for developing different types of applications and different tools.

These capabilities include generating applications, libraries, etc as well as the devtools to test, and build projects as well.

Below are some plugins which you can add to your workspace:

- [React](https://reactjs.org)
  - `npm install --save-dev @nrwl/react`
- Web (no framework frontends)
  - `npm install --save-dev @nrwl/web`
- [Angular](https://angular.io)
  - `npm install --save-dev @nrwl/angular`
- [Nest](https://nestjs.com)
  - `npm install --save-dev @nrwl/nest`
- [Express](https://expressjs.com)
  - `npm install --save-dev @nrwl/express`
- [Node](https://nodejs.org)
  - `npm install --save-dev @nrwl/node`

## Generate an application

Run `nx g @nrwl/react:app my-app` to generate an application.

> You can use any of the plugins above to generate applications as well.

When using Nx, you can create multiple applications and libraries in the same workspace.

## Generate a library

Run `nx g @nrwl/react:lib my-lib` to generate a library.

> You can also use any of the plugins above to generate libraries as well.

Libraries are sharable across libraries and applications. They can be imported from `@demo-docker/mylib`.

## Development server

Run `nx serve my-app` for a dev server. Navigate to http://localhost:4200/. The app will automatically reload if you change any of the source files.

## Code scaffolding

Run `nx g @nrwl/react:component my-component --project=my-app` to generate a new component.

## Build

Run `nx build my-app` to build the project. The build artifacts will be stored in the `dist/` directory. Use the `--prod` flag for a production build.

## Running unit tests

Run `nx test my-app` to execute the unit tests via [Jest](https://jestjs.io).

Run `nx affected:test` to execute the unit tests affected by a change.

## Running end-to-end tests

Run `ng e2e my-app` to execute the end-to-end tests via [Cypress](https://www.cypress.io).

Run `nx affected:e2e` to execute the end-to-end tests affected by a change.

## Understand your workspace

Run `nx dep-graph` to see a diagram of the dependencies of your projects.

## Further help

Visit the [Nx Documentation](https://nx.dev) to learn more.
