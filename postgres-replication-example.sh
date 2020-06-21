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
    psql users -c "SELECT pg_drop_replication_slot('users');"

    psql posts -c 'DROP PUBLICATION posts_to_combined;'
    psql users -c 'DROP PUBLICATION users_to_combined;'

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

psql posts -t -c "SELECT pg_create_logical_replication_slot('posts', 'pgoutput')";
psql users -t -c "SELECT pg_create_logical_replication_slot('users', 'pgoutput')";
psql posts -c 'CREATE PUBLICATION posts_to_combined FOR TABLE posts;'
psql users -c 'CREATE PUBLICATION users_to_combined FOR TABLE users;'

section "Define downstream replication subscription"

psql combined -c "CREATE SUBSCRIPTION posts CONNECTION 'host=localhost dbname=posts' PUBLICATION posts_to_combined WITH (slot_name=posts, create_slot=false);"
psql combined -c "CREATE SUBSCRIPTION users CONNECTION 'host=localhost dbname=users' PUBLICATION users_to_combined WITH (slot_name=users, create_slot=false);"

section "Wait until both subscriptions are active"
while true; do
  psql -t -c "SELECT COUNT(*) FROM pg_replication_slots WHERE active = 't' AND slot_name IN ('posts', 'users');" | grep -q 2 && break
  sleep 0.25;
  echo -n .
done
echo ''


section "Verify upstream data"

psql posts -t -c "SELECT COUNT(*) FROM posts" | grep -q '2' \
  && echo "Post upstream ✅" || echo "Post upstream ❌"
psql users -t -c "SELECT COUNT(*) FROM users" | grep -q '2' \
  && echo "User upstream ✅"|| echo "User upstream ❌"

section "Check downstream for existing data"

psql combined -t -c "SELECT COUNT(*) FROM posts" | grep -q '2' \
  && echo "Post replication ✅" || echo "Post replication ❌"
psql combined -t -c "SELECT COUNT(*) FROM users" | grep -q '2' \
  && echo "User replication ✅"|| echo "User replication ❌"

section "Insert new data upstream"

psql posts -c "INSERT INTO posts (content, created_at, updated_at) VALUES ('New Post', now(), now());"
psql users -c "INSERT INTO users (name, created_at, updated_at) VALUES ('Rebecca', now(), now());"

section "Check downstream for existing data"
psql combined -t -c "SELECT COUNT(*) FROM posts" | grep -q '3' \
  && echo "Post replication ✅" || echo "Post replication ❌"
psql combined -t -c "SELECT COUNT(*) FROM users" | grep -q '3' \
  && echo "User replication ✅"|| echo "User replication ❌"
