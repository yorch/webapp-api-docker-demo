import 'reflect-metadata';
import { DataSource } from 'typeorm';
import { config } from './config';
import { Actor, Film } from './entity';

const { database } = config;

export const AppDataSource = new DataSource({
  type: 'postgres',
  host: database.host,
  port: database.port,
  username: database.user,
  password: database.pass,
  database: database.db,
  entities: [
    // `${__dirname}/entity/*.ts`
    Actor,
    Film,
  ],
  // synchronize: true, // Not to use in production
  synchronize: false,
  logging: true,
});

export const initAppDataSource = async () =>
  AppDataSource.initialize()
    .then(() => {
      console.log('Data Source has been initialized!');
    })
    .catch((err) => {
      console.error('Error during Data Source initialization', err);
    });
