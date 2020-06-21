#!/bin/bash

set -x
set -euo pipefail

# Enable uuids
psql -c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";'
psql -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;'

# Create two upstream databases

dropdb content || true
createdb content
psql content -c "
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
CREATE TABLE contents (
    id UUID DEFAULT uuid_generate_v4() NOT NULL,
    content text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL);
"

dropdb users || true
createdb users
psql users -c "
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
CREATE TABLE users (
    id uuid DEFAULT uuid_generate_v1() NOT NULL,
    name text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL);
"

# Create existing upstream data

psql content -c "
INSERT INTO contents
  (content, created_at, updated_at)
  VALUES
    ('Blog Post', now(), now()),
    ('Frist Psot', now(), now());
"

psql users -c "
INSERT INTO users
  (name, created_at, updated_at)
  VALUES
    ('Jamila', now(), now()),
    ('Sarah', now(), now());
"

# Create single downstream database with superset schema

dropdb combined || true
createdb combined

psql combined -c "
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
CREATE TABLE contents (
    id uuid DEFAULT uuid_generate_v1() NOT NULL,
    content text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL);
CREATE TABLE users (
    id uuid DEFAULT uuid_generate_v1() NOT NULL,
    name text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL);
"

# Define upstream replication publications

psql content -c 'CREATE PUBLICATION combined FOR TABLE contents;'
psql users -c 'CREATE PUBLICATION combined FOR TABLE users;'

# Define downstream replication subscription

psql combined -c "CREATE SUBSCRIPTION content CONNECTION 'host=localhost dbname=content' PUBLICATION combined;"
psql combined -c "CREATE SUBSCRIPTION users CONNECTION 'host=localhost dbname=users' PUBLICATION combined;"

# Check downstream for existing data

psql contents -c "SELECT content FROM contents";
psql users -c "SELECT name FROM users";

# Insert new data upstream

psql contents -c "INSERT INTO contents (content) VALUES ('New Post');"
psql users -c "INSERT INTO users (name) VALUES ('Rebecca');"

# Check downstream for existing data
psql contents -c "SELECT content FROM contents";
psql users -c "SELECT name FROM users";
