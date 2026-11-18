# commondev

**Commonwealth of Developers** — open-source coding agent.

> Status: concept undefined · research in progress

## What this is

`commondev` is an open-source AI coding agent. It's being built as a
community effort — a "commonwealth" of developers rather than a single
vendor's product. The goal: a coding agent that is transparent, extensible,
and genuinely owned by the people who use it.

## Where we are right now

The project is in **research / pre-architect** phase. The core question on
the table:

> Build from scratch, or build on top of the [Pi SDK](https://github.com/pi-coding-agent/pi)?

Both paths are being investigated. No decision has been made yet.

- **From scratch** — full control over the agent loop, tool model, and
  protocol. More work, but no inherited abstractions or vendor lock-in.
- **On Pi SDK** — faster to a working agent, but inherits Pi's architecture
  decisions and its surface area.

This README (and the `docs/` folder) will track the outcome of that
research and the reasoning behind whatever path we choose.

## Repository layout

| Path           | Visibility | Purpose                                  |
| -------------- | ---------- | ---------------------------------------- |
| `docs/`        | public     | Public documentation for the project    |
| `docs_internal/`| private   | Internal notes, research scratchpad     |

`docs_internal/` is git-ignored — it's for working drafts, meeting notes,
and things we don't want published yet.

## Contributing

This is an open-source project. Contributions are welcome.

1. Open an issue describing what you want to change.
2. Fork, branch, make your change.
3. Push a PR referencing the issue.

Please keep commits atomic and add a short explanation of the *why*, not just
the *what*.

## License

TBD — see `docs/license.md` once decided.