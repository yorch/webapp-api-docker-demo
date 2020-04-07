import React from 'react';
import { List, Datagrid, TextField } from 'react-admin';

export const ActorList = (props) => (
  <List {...props} pagination={null}>
    <Datagrid>
      <TextField source="id" />
      <TextField source="first_name" />
      <TextField source="last_name" />
    </Datagrid>
  </List>
);
