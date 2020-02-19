import 'reflect-metadata';
import { createConnection } from 'typeorm';
import { Actor, Film } from './entity';

import { config } from './config';

const { database } = config;

export const setupDatabase = () =>
  createConnection({
    type: 'postgres',
    host: database.host,
    port: database.port,
    username: database.user,
    password: database.pass,
    database: database.db,
    entities: [
      // `${__dirname}/entity/*.ts`
      Actor,
      Film
    ],
    // synchronize: true,
    synchronize: false,
    logging: true
  })
  .then((connection) => {
    console.log('DB connection setup successfully!');
    return connection;
  })
  .catch((error) => console.log(error));
