import React, { Props } from 'react';
import { List, Datagrid, TextField } from 'react-admin';

export const MovieList: React.FC<Props<unknown>> = (props) => (
  <List {...props} pagination={null}>
    <Datagrid>
      <TextField source="id" />
      <TextField source="title" />
      <TextField source="description" />
    </Datagrid>
  </List>
);
