#!/bin/bash

set -euo pipefail

cleanup() {
  psql -c 'SELECT * from pg_replication_slots;'

  cleanup_log=$(
    psql combined -c "ALTER SUBSCRIPTION posts DISABLE;"
    psql combined -c "ALTER SUBSCRIPTION users DISABLE;"
    psql combined -c "ALTER SUBSCRIPTION posts SET (slot_name = NONE);"
    psql combined -c "ALTER SUBSCRIPTION users SET (slot_name = NONE);"
    psql combined -c "DROP SUBSCRIPTION IF EXISTS posts;"
    psql combined -c "DROP SUBSCRIPTION IF EXISTS users;"

    psql posts -c "SELECT pg_drop_replication_slot('posts');"
    psql users   -c "SELECT pg_drop_replication_slot('users');"

    psql posts -c 'DROP PUBLICATION combined;'
    psql users   -c 'DROP PUBLICATION combined;'

    dropdb combined
    dropdb posts
    dropdb users
  )
  # echo $cleanup_log
}

trap cleanup EXIT

section() {
  echo "## $@"
}

section "Create two upstream databases"

createdb posts
psql posts -c "
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
CREATE TABLE posts (
    id UUID DEFAULT uuid_generate_v4() NOT NULL,
    content text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL);
"

createdb users
psql users -c "
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
CREATE TABLE users (
    id uuid DEFAULT uuid_generate_v4() NOT NULL,
    name text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL);
"

section "Create existing upstream data"

psql posts -c "
INSERT INTO posts
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

section "Create single downstream database with superset schema"

createdb combined

psql combined -c "
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
CREATE TABLE posts (
    id uuid DEFAULT uuid_generate_v4() NOT NULL,
    content text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL);
CREATE TABLE users (
    id uuid DEFAULT uuid_generate_v4() NOT NULL,
    name text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL);
"

section "Define upstream replication publications"

psql posts -c "SELECT pg_create_logical_replication_slot('posts', 'pgoutput')";
psql users   -c "SELECT pg_create_logical_replication_slot('users', 'pgoutput')";
psql posts -c 'CREATE PUBLICATION combined FOR TABLE posts;'
psql users   -c 'CREATE PUBLICATION combined FOR TABLE users;'

section "Define downstream replication subscription"

psql combined -c "CREATE SUBSCRIPTION posts CONNECTION 'host=localhost dbname=posts' PUBLICATION combined WITH (create_slot=false);"
psql combined -c "CREATE SUBSCRIPTION users CONNECTION 'host=localhost dbname=users' PUBLICATION combined WITH (create_slot=false);"

sleep 1

section "Verify upstream data"

psql posts -c "SELECT * FROM posts";
psql users -c "SELECT * FROM users";

section "Check downstream for existing data"

psql combined -c "SELECT * FROM posts";
psql combined -c "SELECT * FROM users";

section "Insert new data upstream"

psql posts -c "INSERT INTO posts (content, created_at, updated_at) VALUES ('New Post', now(), now());"
psql users -c "INSERT INTO users (name, created_at, updated_at) VALUES ('Rebecca', now(), now());"

section "Check downstream for existing data"
psql combined -c "SELECT * FROM posts";
psql combined -c "SELECT * FROM users";

sleep 1

section "Check again"
psql combined -c "SELECT * FROM posts";
psql combined -c "SELECT * FROM users";

