import { List, Datagrid, TextField, ResourceComponentProps } from 'react-admin';

export const MovieList = (props: ResourceComponentProps) => (
  <List {...props} pagination={false}>
    <Datagrid>
      <TextField source="id" />
      <TextField source="title" />
      <TextField source="description" />
    </Datagrid>
  </List>
);
