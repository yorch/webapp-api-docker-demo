import { List, Datagrid, TextField } from 'react-admin';

export const ActorList = () => (
  <List pagination={false}>
    <Datagrid>
      <TextField source="id" />
      <TextField source="first_name" />
      <TextField source="last_name" />
    </Datagrid>
  </List>
);
