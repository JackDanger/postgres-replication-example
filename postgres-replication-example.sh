#!/bin/bash

set -euo pipefail

cleanup() {
  psql -c 'SELECT * from pg_replication_slots;'

  cleanup_log=$(
    psql combined -c "ALTER SUBSCRIPTION posts DISABLE;"
    psql combined -c "ALTER SUBSCRIPTION users DISABLE;"
    psql posts -c "ALTER SUBSCRIPTION posts_backward DISABLE;"
    psql users -c "ALTER SUBSCRIPTION users_backward DISABLE;"
    psql combined -c "ALTER SUBSCRIPTION posts SET (slot_name = NONE);"
    psql combined -c "ALTER SUBSCRIPTION users SET (slot_name = NONE);"
    psql posts -c "ALTER SUBSCRIPTION posts_backward SET (slot_name = NONE);"
    psql users -c "ALTER SUBSCRIPTION users_backward SET (slot_name = NONE);"
    psql combined -c "DROP SUBSCRIPTION IF EXISTS posts;"
    psql posts -c "DROP SUBSCRIPTION IF EXISTS posts_backward;"
    psql combined -c "DROP SUBSCRIPTION IF EXISTS users;"
    psql users -c "DROP SUBSCRIPTION IF EXISTS users_backward;"

    psql -c "SELECT pg_drop_replication_slot('posts');"
    psql -c "SELECT pg_drop_replication_slot('posts_backward');"
    psql -c "SELECT pg_drop_replication_slot('users');"
    psql -c "SELECT pg_drop_replication_slot('users_backward');"

    psql posts    -c 'DROP PUBLICATION posts;'
    psql combined -c 'DROP PUBLICATION posts_backward;'
    psql users    -c 'DROP PUBLICATION users;'
    psql combined -c 'DROP PUBLICATION users_backward;'

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
psql posts -c 'CREATE PUBLICATION posts FOR TABLE posts;'
psql users -c 'CREATE PUBLICATION users FOR TABLE users;'

section "Define downstream replication subscription"

psql combined -c "CREATE SUBSCRIPTION posts CONNECTION 'host=localhost dbname=posts' PUBLICATION posts WITH (slot_name=posts, create_slot=false);"
psql combined -c "CREATE SUBSCRIPTION users CONNECTION 'host=localhost dbname=users' PUBLICATION users WITH (slot_name=users, create_slot=false);"

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

sleep 1
section "Check downstream for existing data"
psql combined -t -c "SELECT COUNT(*) FROM posts" | grep -q '3' \
  && echo "Post replication ✅" || echo "Post replication ❌"
psql combined -t -c "SELECT COUNT(*) FROM users" | grep -q '3' \
  && echo "User replication ✅"|| echo "User replication ❌"

section "Drop the original subscriptions"
psql combined -c "DROP SUBSCRIPTION posts;"
psql combined -c "DROP SUBSCRIPTION users;"

section "Define subscriptions for the same tables *from* the replica"

psql combined -t -c "SELECT pg_create_logical_replication_slot('posts_backward', 'pgoutput')";
psql combined -t -c "SELECT pg_create_logical_replication_slot('users_backward', 'pgoutput')";
psql combined -c 'CREATE PUBLICATION posts_backward FOR TABLE posts;'
psql combined -c 'CREATE PUBLICATION users_backward FOR TABLE users;'

section "Define subscriptions upstream"

psql posts -c "CREATE SUBSCRIPTION posts_backward CONNECTION 'host=localhost dbname=combined' PUBLICATION posts_backward WITH (slot_name=posts_backward, create_slot=false);"
psql users -c "CREATE SUBSCRIPTION users_backward CONNECTION 'host=localhost dbname=combined' PUBLICATION users_backward WITH (slot_name=users_backward, create_slot=false);"

section "Wait until both subscriptions are active"
while true; do
  psql -t -c "SELECT COUNT(*) FROM pg_replication_slots WHERE active = 't' AND slot_name IN ('posts_backward', 'users_backward');" | grep -q 2 && break
  sleep 0.25;
  echo -n .
done
echo ''

section "Insert new data downstream"

psql combined -c "INSERT INTO posts (content, created_at, updated_at) VALUES ('On combined', now(), now());"
psql combined -c "INSERT INTO users (name, created_at, updated_at) VALUES ('Combined', now(), now());"

sleep 1

section "Check upstream for new data replicated backwards"
psql posts -t -c "SELECT COUNT(*) FROM posts" | grep -q '4' \
  && echo "Post replication ✅" || echo "Post replication ❌"
psql users -t -c "SELECT COUNT(*) FROM users" | grep -q '4' \
  && echo "User replication ✅"|| echo "User replication ❌"
