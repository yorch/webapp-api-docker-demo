import { Express } from 'express';
import { Connection } from 'typeorm';
import { Message } from '@webapp-api-docker-demo/api-interfaces';
import { environment } from './environments/environment';
import { Actor, Film } from './entity';

const { apiBasePath } = environment;

export const setupRoutes = ({
  app,
  dbConnection,
}: {
  app: Express;
  dbConnection: Connection;
}): void => {
  const greeting: Message = { message: 'Welcome to api!' };

  app.get(apiBasePath.length === 0 ? '/' : apiBasePath, (req, res) => {
    res.send(greeting);
  });

  app.get(`${apiBasePath}/actors`, async (req, res) => {
    const repository = dbConnection.getRepository(Actor);
    const entities = await repository.find();
    const { length } = entities;
    res.set('Content-Range', `actors 0-${length - 1}/${length}`);
    res.json(
      entities.map(({ actor_id, ...rest }) => ({ id: actor_id, ...rest }))
    );
  });

  app.get(`${apiBasePath}/actors/:id`, async ({ params }, res) => {
    const repository = dbConnection.getRepository(Actor);
    res.json(await repository.findOne(params.id));
  });

  app.get(`${apiBasePath}/movies`, async (req, res) => {
    const repository = dbConnection.getRepository(Film);
    const entities = await repository.find();
    const { length } = entities;
    res.set('Content-Range', `actors 0-${length - 1}/${length}`);
    res.json(
      entities.map(({ film_id, ...rest }) => ({ id: film_id, ...rest }))
    );
  });

  app.get(`${apiBasePath}/movies/:id`, async ({ params }, res) => {
    const repository = dbConnection.getRepository(Film);
    res.json(await repository.findOne(params.id));
  });
};
