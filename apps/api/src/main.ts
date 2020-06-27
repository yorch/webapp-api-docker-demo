import 'reflect-metadata';
import * as express from 'express';
import cors from 'cors';
import { config } from './config';
import { setupDatabase } from './database';
import { setupRoutes } from './routes';

const { port } = config;

const app = express();

(async () => {
  const dbConnection = await setupDatabase();

  app.use(
    cors({
      // origin: domain ? `https://${domain}` : '',
      exposedHeaders: ['Content-Range'],
      optionsSuccessStatus: 200, // some legacy browsers (IE11, various SmartTVs) choke on 204
    })
  );

  app.use(express.json());

  app.use(express.text());

  setupRoutes({ app, dbConnection });

  const server = app.listen(port, () => {
    console.log(`Listening at http://localhost:${port}/api`);
  });

  server.on('error', console.error);
})();
