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
- A domain, it could be a `.com`, `.net`, `.info`, `.cc` or any other domain you like. You need to configure two DNS records for it:
  - `A` record, that should point to the IP address of your newly configured server.
  - `CNAME` record like: `*.yourdomain.com` to point to `yourdomain.com`, this will allow you to use any subdomain you may need (like `api.yourdomain.com`) with this stack without having to configure the DNS of your domain every time.
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

  This will run all the containers configured in `docker-compose.prod.yml`.

## Endpoints

Once the stack is running, you can access the different parts using:

- Front End / Web application: `https://yourdomain.com`, the domain that you configured in your `.env` file.
- API Server: `https://api.yourdomain.com`, you can change the subdomain in your `.env` file.
- Traefik Dashboard: `https://traefik.yourdomain.com`, where you can see the different services configured in your Docker stack and that Traefik is serving.
- DB Admin / Adminer: `https://adminer.yourdomain.com/`, a simple database management tool, you can use the DB credentials configured in the `.env` file to log in.

## Some Docker commands

Once you have your Docker stack / services running, you can do a few different things:

- `docker ps` -> To see all the containers that are running:
- `docker ps -a` -> To see all the containers that are either running or stopped (and that have not been removed with `docker rm`).
- `docker images` -> To see all the images your Docker host has pulled locally (ie: like when using `docker pull ${imageName}` or just by running a container which image does not exist locally).
- `docker-compose -f docker-compose.prod.yml down` -> To stop and cleanup your Docker services. When there is a file named `docker-compose.yml`, the `-f` param can be skipped, but in this case, since we have a couple different Docker Compose files, we have to be explicit.
- `docker-compos -f docker-compose.prod.yml logs` -> To see the logs from all the services in the Docker Compose file.

## Running locally

If you want to run this project locally, you would need to run Postgres somehow, luckily, we can also use Docker for this (be sure to [install Docker](https://docs.docker.com/docker-for-mac/) in your computer first and to have it running):

```sh
yarn start-local-db
```

This will run a PostgreSQL container and will setup the database with dummy data, you can see the SQL script used in the bootstrap process [here](docker/_db_init).

It will also run Adminer on port `8090`, so you can manage the database in a simple web application. If you have port conflicts, you can modify the file [`docker-compose.dev.yml`](docker-compose.dev.yml).

To run the FE and the server, you would need to have NodeJS and Yarn locally installed and then run:

```sh
# Install dependencies
yarn
# Start both services
yarn start
```

> Fun fact: Using Docker we could also skipped the dependency of having NodeJS and Yarn locally installed and still be able to work on this repo.

---

This project was generated using [Nx](https://nx.dev).

<p style="text-align: center;"><img src="https://raw.githubusercontent.com/nrwl/nx/master/images/nx-logo.png" width="450"></p>

🔎 **Smart, Fast and Extensible Build System**

## Adding capabilities to your workspace

Nx supports many plugins which add capabilities for developing different types of applications and different tools.

These capabilities include generating applications, libraries, etc as well as the devtools to test, and build projects as well.

Below are our core plugins:

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

There are also many [community plugins](https://nx.dev/community) you could add.

## Generate an application

Run `nx g @nrwl/react:app my-app` to generate an application.

> You can use any of the plugins above to generate applications as well.

When using Nx, you can create multiple applications and libraries in the same workspace.

## Generate a library

Run `nx g @nrwl/react:lib my-lib` to generate a library.

> You can also use any of the plugins above to generate libraries as well.

Libraries are shareable across libraries and applications. They can be imported from `@webapp-api-docker-demo/mylib`.

## Development server

Run `nx serve my-app` for a dev server. Navigate to <http://localhost:4200/>. The app will automatically reload if you change any of the source files.

## Code scaffolding

Run `nx g @nrwl/react:component my-component --project=my-app` to generate a new component.

## Build

Run `nx build my-app` to build the project. The build artifacts will be stored in the `dist/` directory. Use the `--prod` flag for a production build.

## Running unit tests

Run `nx test my-app` to execute the unit tests via [Jest](https://jestjs.io).

Run `nx affected:test` to execute the unit tests affected by a change.

## Running end-to-end tests

Run `nx e2e my-app` to execute the end-to-end tests via [Cypress](https://www.cypress.io).

Run `nx affected:e2e` to execute the end-to-end tests affected by a change.

## Understand your workspace

Run `nx graph` to see a diagram of the dependencies of your projects.

## Further help

Visit the [Nx Documentation](https://nx.dev) to learn more.

## ☁ Nx Cloud

### Distributed Computation Caching & Distributed Task Execution

<p style="text-align: center;"><img src="https://raw.githubusercontent.com/nrwl/nx/master/images/nx-cloud-card.png"></p>

Nx Cloud pairs with Nx in order to enable you to build and test code more rapidly, by up to 10 times. Even teams that are new to Nx can connect to Nx Cloud and start saving time instantly.

Teams using Nx gain the advantage of building full-stack applications with their preferred framework alongside Nx’s advanced code generation and project dependency graph, plus a unified experience for both frontend and backend developers.

Visit [Nx Cloud](https://nx.app/) to learn more.
