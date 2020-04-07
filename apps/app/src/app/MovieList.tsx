import React from 'react';
import { List, Datagrid, TextField } from 'react-admin';

export const MovieList = (props) => (
  <List {...props} pagination={null}>
    <Datagrid>
      <TextField source="id" />
      <TextField source="title" />
      <TextField source="description" />
    </Datagrid>
  </List>
);
