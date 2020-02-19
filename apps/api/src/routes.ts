import { Message } from '@demo-docker/api-interfaces';
import { Actor, Film } from './entity';

export const setupRoutes = ({ app, dbConnection }) => {
  const greeting: Message = { message: 'Welcome to api!' };

  app.get('/api', (req, res) => {
    res.send(greeting);
  });

  app.get('/api/actors', async (req, res) => {
    const repository = dbConnection.getRepository(Actor);
    const entities = await repository.find();
    const { length } = entities;
    res.set('Content-Range', `actors 0-${length - 1}/${length}`);
    // eslint-disable-next-line @typescript-eslint/camelcase
    res.json(entities.map(({ actor_id, ...rest }) => ({ id: actor_id, ...rest })));
  });

  app.get('/api/actors/:id', async ({ params }, res) => {
    const repository = dbConnection.getRepository(Actor);
    res.json(await repository.findOne(params.id));
  });

  app.get('/api/movies', async (req, res) => {
    const repository = dbConnection.getRepository(Film);
    const entities = await repository.find();
    const { length } = entities;
    res.set('Content-Range', `actors 0-${length - 1}/${length}`);
    // eslint-disable-next-line @typescript-eslint/camelcase
    res.json(entities.map(({ film_id, ...rest }) => ({ id: film_id, ...rest })));
  });

  app.get('/api/movies/:id', async ({ params }, res) => {
    const repository = dbConnection.getRepository(Film);
    res.json(await repository.findOne(params.id));
  });
};
