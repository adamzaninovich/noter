@AGENTS.md

## Tools

### Tidewave

Always use Tidewave's tools for evaluating code, querying the database, etc.

Use `get_docs` to access documentation and the `get_source_location` tool to
find module/function definitions.

## Project-specific gotchas

- **Inline form alignment**: `<.input>` wraps in a `fieldset mb-2` div. For inline input+button forms, wrap both in a `flex items-center` container and add `[&_.fieldset]:mb-0` on the input's parent div.
- **Stream empty states**: The `hidden only:block` CSS trick does not survive LiveView's connected mount. Instead, track emptiness with a separate `@*_empty?` assign and render the empty state outside the stream container using `:if`.

