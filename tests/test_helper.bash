# Shared setup/teardown for agmsg BATS tests.
# Each test gets an isolated skill directory with its own DB and teams.

setup_test_env() {
  export TEST_SKILL_DIR="$(mktemp -d)"
  mkdir -p "$TEST_SKILL_DIR"/{scripts,templates,db,teams}

  # Copy all scripts to isolated skill dir
  cp "$BATS_TEST_DIRNAME"/../scripts/*.sh "$TEST_SKILL_DIR/scripts/"
  chmod +x "$TEST_SKILL_DIR/scripts/"*.sh

  # Copy templates to match the installed skill layout.
  cp "$BATS_TEST_DIRNAME"/../templates/* "$TEST_SKILL_DIR/templates/"

  # Initialize DB
  bash "$TEST_SKILL_DIR/scripts/init-db.sh"

  # Convenience vars
  export SCRIPTS="$TEST_SKILL_DIR/scripts"
}

teardown_test_env() {
  rm -rf "$TEST_SKILL_DIR"
}
