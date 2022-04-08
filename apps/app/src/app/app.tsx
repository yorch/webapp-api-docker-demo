import { Admin, Resource } from 'react-admin';
// import jsonServerProvider from 'ra-data-json-server';
import simpleRestProvider from 'ra-data-simple-rest';
import { environment } from '../environments/environment';
import { ActorList } from './ActorList';
import { MovieList } from './MovieList';

// const dataProvider = jsonServerProvider('http://jsonplaceholder.typicode.com');
const dataProvider = simpleRestProvider(environment.apiBasePath);

export const App = () => (
  <Admin dataProvider={dataProvider}>
    <Resource name="actors" list={ActorList} />
    <Resource name="movies" list={MovieList} />
  </Admin>
);

export default App;
