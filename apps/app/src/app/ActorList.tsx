import { List, Datagrid, TextField, ResourceComponentProps } from 'react-admin';

export const ActorList = (props: ResourceComponentProps) => (
  <List {...props} pagination={null}>
    <Datagrid>
      <TextField source="id" />
      <TextField source="first_name" />
      <TextField source="last_name" />
    </Datagrid>
  </List>
);
