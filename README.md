# SchemaDrawer GitHub Action

Uploads the migration files of a directory to [schemadrawer.com](https://schemadrawer.com),
waits for the schema diagram and commits it to the branch of the pull request, so that the diagram
is reviewed together with the migration that changed it.

## How it works

The action is two scripts, run one after the other:

1. [`scripts/draw.sh`](scripts/draw.sh)
   - The action asks GitHub for the run's OIDC token - a JWT GitHub signs, naming the repository,
     the workflow, the commit and who triggered it - for the audience `schemadrawer.com`. This is
     what `id-token: write` is for; without it the upload goes unsigned and the step says so.
   - `POST {api-base-url}/drawing` - every file under `sql-directory` (subdirectories included, named
     relative to it) is sent as `multipart/form-data` (field `files`), along with `userId`,
     `migrationType`, `databaseType` and `version`, a `Request-Id` header derived from the
     workflow run, so that a retried upload is not drawn twice, and the token as
     `Authorization: Bearer <token>`. The server checks the token against GitHub's published keys
     and refuses one that is forged, expired or meant for someone else with `401`. The answer is `202` with
     ```json
     { "jobId": "0b6e2f4c-8d1a-4c3e-9f7a-2a5b6c7d8e9f" }
     ```
   - `GET {api-base-url}/drawing/{jobId}` is polled every 3 seconds, for up to `timeout-seconds`,
     until the job is `SUCCESS` or `ERROR`:
     ```json
     { "jobId": "…", "status": "SUCCESS", "createdAt": "…", "errorMessage": null, "diagramUrl": "https://…" }
     ```
   - On `ERROR` the action fails and prints `errorMessage` - the migration tool's own words.
   - On `SUCCESS` the diagram is downloaded from `diagramUrl` and written to `output-path`.
2. [`scripts/commit.sh`](scripts/commit.sh) - the diagram is committed to the branch the workflow
   runs for and pushed. On a `pull_request` event that is the pull request's branch; on a `push` it
   is the branch pushed to. If the diagram is identical to the one already in the repository,
   nothing is committed.

## Usage

```yaml
name: Schema diagram

on:
  pull_request:

permissions:
  contents: write
  id-token: write

jobs:
  draw:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - uses: schemadrawer-com/action@v1
        with:
          sql-directory: db/migration
          output-path: docs/schema-diagram.svg
          migration-type: FLYWAY
          database-type: POSTGRESQL
          database-version: '18'
```

Every pull request that changes the migrations gets a commit with the new diagram. A pull request
that leaves the diagram as it is gets nothing.

## Inputs

| Name               | Required | Default                            | Description                                                             |
|---------------------|----------|-------------------------------------|---------------------------------------------------------------------------|
| `sql-directory`     | yes      | —                                   | Directory with the migration files; everything in it is uploaded.        |
| `output-path`       | yes      | —                                   | Path of the result file (SVG) to create/update in the repo.               |
| `api-base-url`      | no       | `https://app.schemadrawer.com/api/v1`  | Base URL of the API.                                                        |
| `migration-type`    | yes      | —                                   | The migration tool the files are written for (`FLYWAY`, `LIQUIBASE`, `PRISMA`, `DJANGO`, …). |
| `database-type`     | yes      | —                                   | Database engine (`POSTGRESQL`, `MYSQL`, `MARIADB`, `MSSQL`, `ORACLE`, `SQLITE`). |
| `database-version`  | yes      | —                                   | Version of the database engine.                                             |
| `user-id`           | no       | derived from the repository name    | UUID identifying this repository at schemadrawer.com.                       |
| `timeout-seconds`   | no       | `300`                               | Max time to wait for the diagram (5 minutes).                               |
| `commit-message`    | no       | `chore: update schema diagram`     | Commit message for the diagram.                                               |
| `github-token`      | no       | the workflow's `GITHUB_TOKEN`       | Token used to push the commit; see below for when to pass a personal access token. |

## Outputs

| Name                 | Description                                |
|-----------------------|---------------------------------------------|
| `commit-sha`         | SHA of the commit that added the diagram (empty if there was nothing to commit). |

## Requirements

- Runs on a runner with `curl`, `jq` and `python3` available (all preinstalled on `ubuntu-latest`).
- The workflow must `actions/checkout` the repository before this action runs.
- `permissions: contents: write` lets the action push the commit; `id-token: write` lets it ask
  GitHub for the token that vouches for the run.

## The commit and the pull request's checks

A commit pushed with the workflow's own `GITHUB_TOKEN` does not trigger workflows, by GitHub's
design. That rules out an endless loop, but it also means the pull request's checks do not run
again for the diagram commit. Where branch protection requires those checks, pass a personal
access token with `contents: write` as `github-token`: the commit then triggers the workflows,
this one included, which finds the diagram up to date and commits nothing.

A pull request from a fork gets no commit: GitHub gives its workflow a read-only token.

## Trying it by hand

`draw.sh` takes its inputs from the environment, so it can be run against any server - the one from
`mvn -pl app spring-boot:run`, say - without GitHub:

```bash
SQL_DIRECTORY=core/src/main/resources/migrations/flyway-sql \
OUTPUT_PATH=/tmp/schema.svg \
API_BASE_URL=http://localhost/api/v1 \
scripts/draw.sh
```

It prints the files it uploads, the job's id and where the diagram went; a failed migration ends
with the migration tool's message and exit code 1.
