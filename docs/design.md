# Design References

The image follows patterns proven by similar agent-container projects and official documentation:

- [OpenHands agent-server image](https://github.com/OpenHands/software-agent-sdk) — parameterized builds,
  official installers, OCI labels, fail-fast builds;
- [mattolson/agent-sandbox](https://github.com/mattolson/agent-sandbox) — pinned tool versions, a separate
  persistent state volume, and a sandbox that grants only minimal filesystem/network access;
- [Claude Code dev container documentation](https://code.claude.com/docs/en/devcontainer) — auth/state volume
  mounting and `CLAUDE_CONFIG_DIR` on the same volume, an immutable image with the dsh version pinned
  at build time (`DSH_TAG`, no runtime auto-update), and the warning against mounting host keys into
  the container;
- [NousResearch/hermes-agent container](https://github.com/NousResearch/hermes-agent) — the layering
  doctrine this image converges on: the image owns the whole toolchain as read-only real binaries
  (`/usr/local/bin`, `/opt` trees), the volume holds only data, PATH is image-first with user
  directories last, and volume-side extension areas are opt-in so user installs can never shadow
  image-provided tools;
- [Running Claude Code in Docker (Dennis van der Stelt)](https://github.com/dvdstelt/weblog/blob/main/src/content/posts/2026-02-19-claude-code-in-docker.md) — the host-side launch-script wrapper around `docker run` experience.
