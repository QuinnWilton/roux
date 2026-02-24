# roux

A framework for building incremental mix compilers.

## What it does

TODO — describe the core functionality.

## Architecture

TODO — describe the key modules and data flow.

## Development commands

```bash
mix test                      # run all tests
mix format                    # format code
mix format --check-formatted  # check formatting
mix credo --strict            # lint
mix dialyzer                  # static analysis
```

## Commit message style

```
[component] brief description

Optional longer explanation.
```

## Testing conventions

- Unit tests mirror `lib/` structure in `test/`.
- Test support modules go in `test/support/`.
- Use `stream_data` for property-based testing.

## Changelog

Every user-visible change must have an entry in `CHANGELOG.md` under an `## Unreleased` section at the top.
