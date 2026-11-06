#!/usr/bin/env node
// Print the newest `dsh-v*` tag read from stdin (newline-separated tag names),
// ordered by the shared semver key in ./semver.mjs.
//
// The Containerfile's `latest` default and the upstream watcher must agree on
// what "newest upstream tag" means, so both order tags through this one module
// instead of each carrying its own comparison (the build used to run
// `git tag --sort=-v:refname` and then patch the result back to semver order).
// Empty output means no valid tag: callers fail closed on that.
import { readFileSync } from 'node:fs'
import { newest } from './semver.mjs'

process.stdout.write(newest(readFileSync(0, 'utf8')))
