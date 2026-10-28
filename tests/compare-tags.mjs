#!/usr/bin/env node
// Compare the newest upstream dsh-v* tag with this repository's newest tag.
// Input: UPSTREAM_TAGS / SELF_TAGS (newline-separated full tag names).
// Output: JSON {upstream, self, upNewer} for upstream-tag.yml.
// Kept as a module (not inline in the workflow) so the ordering logic has one
// implementation and can be unit-tested.
import { key, newest } from './semver.mjs'

const up = newest(process.env.UPSTREAM_TAGS)
const self = newest(process.env.SELF_TAGS)
const upNewer = up !== '' && up !== self && key(up) > (key(self) ?? '')

process.stdout.write(JSON.stringify({ upstream: up, self, upNewer }))
