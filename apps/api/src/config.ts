const {
  DOMAIN,
  POSTGRES_HOST,
  POSTGRES_PORT,
  POSTGRES_DB,
  POSTGRES_USER,
  POSTGRES_PASSWORD,
  SERVER_PORT,
} = process.env;

export const config = {
  domain: DOMAIN,
  database: {
    host: POSTGRES_HOST || 'localhost',
    port: Number(POSTGRES_PORT) || 5432,
    db: POSTGRES_DB || 'movies_db',
    user: POSTGRES_USER || 'postgres',
    pass: POSTGRES_PASSWORD || 'password',
  },
  port: SERVER_PORT || 3333,
};
