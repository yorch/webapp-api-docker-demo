import 'reflect-metadata';
import * as express from 'express';
import { config } from './config';
import { setupDatabase } from './database';
import { setupRoutes } from './routes';

const { port } = config;

const app = express();

(async () => {
  const dbConnection = await setupDatabase();

  app.use(express.json());

  app.use(express.text());

  setupRoutes({ app, dbConnection });

  const server = app.listen(port, () => {
    console.log(`Listening at http://localhost:${port}/api`);
  });

  server.on('error', console.error);
})();
