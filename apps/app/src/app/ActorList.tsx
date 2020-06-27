import React, { Props } from 'react';
import { List, Datagrid, TextField } from 'react-admin';

export const ActorList: React.FC<Props<unknown>> = (props) => (
  <List {...props} pagination={null}>
    <Datagrid>
      <TextField source="id" />
      <TextField source="first_name" />
      <TextField source="last_name" />
    </Datagrid>
  </List>
);
