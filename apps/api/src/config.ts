const {
  DATABASE_HOST,
  DATABASE_PORT,
  DATABASE_DB,
  DATABASE_USER,
  DATABASE_PASS,
  SERVER_PORT
} = process.env;

export const config = {
  database: {
    host: DATABASE_HOST || 'localhost',
    port: Number(DATABASE_PORT) || 5432,
    db: DATABASE_DB || 'movies_db',
    user: DATABASE_USER || 'postgres',
    pass: DATABASE_PASS || 'password'
  },
  port: SERVER_PORT || 3333
};
