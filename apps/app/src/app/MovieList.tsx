import { List, Datagrid, TextField } from 'react-admin';

export const MovieList = () => (
  <List pagination={false}>
    <Datagrid>
      <TextField source="id" />
      <TextField source="title" />
      <TextField source="description" />
    </Datagrid>
  </List>
);
