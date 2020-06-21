#!/bin/bash

set -x
set -euo pipefail

cleanup() {
  cleanup_log=$(
    psql combined -c "ALTER SUBSCRIPTION content DISABLE;"
    psql combined -c "ALTER SUBSCRIPTION users DISABLE;"
    psql combined -c "ALTER SUBSCRIPTION content SET (slot_name = NONE);"
    psql combined -c "ALTER SUBSCRIPTION users SET (slot_name = NONE);"
    psql combined -c "DROP SUBSCRIPTION IF EXISTS content;"
    psql combined -c "DROP SUBSCRIPTION IF EXISTS users;"

    psql content -c "SELECT pg_drop_replication_slot('content');"
    psql users   -c "SELECT pg_drop_replication_slot('users');"

    psql content -c 'DROP PUBLICATION combined;'
    psql users   -c 'DROP PUBLICATION combined;'

    dropdb combined
    dropdb content
    dropdb users
  )
  # echo $cleanup_log
}

trap cleanup EXIT

# Enable uuids
psql -c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";'
psql -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;'

# Create two upstream databases

createdb content
psql content -c "
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
CREATE TABLE contents (
    id UUID DEFAULT uuid_generate_v4() NOT NULL,
    content text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL);
"

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

psql content -c "SELECT pg_create_logical_replication_slot('content', 'pgoutput')";
psql users   -c "SELECT pg_create_logical_replication_slot('users', 'pgoutput')";
psql content -c 'CREATE PUBLICATION combined FOR TABLE contents;'
psql users   -c 'CREATE PUBLICATION combined FOR TABLE users;'

# Define downstream replication subscription

psql combined -c "CREATE SUBSCRIPTION content CONNECTION 'host=localhost dbname=content' PUBLICATION combined WITH (create_slot=false);"
psql combined -c "CREATE SUBSCRIPTION users CONNECTION 'host=localhost dbname=users' PUBLICATION combined WITH (create_slot=false);"

# Check downstream for existing data

psql content -c "SELECT content FROM contents";
psql users -c "SELECT name FROM users";

# Insert new data upstream

psql content -c "INSERT INTO contents (content) VALUES ('New Post');"
psql users -c "INSERT INTO users (name) VALUES ('Rebecca');"

# Check downstream for existing data
psql content -c "SELECT content FROM contents";
psql users -c "SELECT name FROM users";
