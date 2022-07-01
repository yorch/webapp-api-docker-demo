import 'reflect-metadata';
import * as express from 'express';
import * as cors from 'cors';
import { initAppDataSource } from './app-datasource';
import { config } from './config';
import { setupRoutes } from './routes';

const { port } = config;

const app = express();

(async () => {
  await initAppDataSource();

  app.use(
    cors({
      // origin: domain ? `https://${domain}` : '',
      exposedHeaders: ['Content-Range'],
      optionsSuccessStatus: 200, // some legacy browsers (IE11, various SmartTVs) choke on 204
    })
  );

  app.use(express.json());

  app.use(express.text());

  setupRoutes({ app });

  const server = app.listen(port, () => {
    console.log(`Listening at http://localhost:${port}/api`);
  });

  server.on('error', console.error);
})();
